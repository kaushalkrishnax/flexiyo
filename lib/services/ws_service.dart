import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Minimal subset of [WebSocketChannel] used by [WsService].
///
/// Kept separate so the request/ack protocol can be tested with an in-memory
/// fake instead of a real socket.
abstract class ChannelLike {
  Stream<dynamic> get stream;
  Sink<dynamic> get sink;
  Future<void> get ready;
}

/// Wraps a real [WebSocketChannel] as a [ChannelLike].
class RealChannel implements ChannelLike {
  RealChannel(this._channel);
  final WebSocketChannel _channel;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  Sink<dynamic> get sink => _channel.sink;

  @override
  Future<void> get ready => _channel.ready;
}

/// WebSocket connection for a single conversation with automatic reconnection.
class WsService {
  WsService({
    this.conversationId,
    required this.wsUrl,
    ChannelLike? channel,
  }) : _channel = channel;

  final String? conversationId;
  final String wsUrl;

  ChannelLike? _channel;
  StreamSubscription<dynamic>? _sub;
  bool _disposed = false;
  bool _connecting = false;
  Timer? _retryTimer;

  int _retryCount = 0;
  static const int _maxRetries = 25;

  /// Client-side heartbeat: detects half-dead sockets where the TCP
  /// connection is silently gone (e.g. DNS/network flaps) so the retry
  /// loop starts instead of sends hanging for the full request timeout.
  Timer? _pingTimer;
  DateTime _lastPong = DateTime.now();
  static const _pingInterval = Duration(seconds: 30);
  static const _pongDeadline = Duration(seconds: 75);

  final _eventController = StreamController<Map<String, dynamic>>.broadcast();

  /// Stream of decoded JSON events from the server.
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  final Map<String, Completer<Map<String, dynamic>>> _pending = {};

  bool _connected = false;
  bool get isConnected => _connected;
  void Function(bool isConnected)? onConnectionChanged;
  Completer<void>? _connectionWaiter;

  Future<void> connect() async {
    if (_disposed || _connecting) return;
    _retryCount = 0;
    await _openConnection();
  }

  Future<void> _openConnection() async {
    if (_disposed || _connecting) return;
    _connecting = true;

    try {
      if (_channel == null) {
        final uri = Uri.parse(wsUrl);
        final real = WebSocketChannel.connect(uri);
        await real.ready;
        _channel = RealChannel(real);
      }
      if (_disposed) {
        _channel?.sink.close();
        _connecting = false;
        return;
      }
      _connected = true;
      _retryCount = 0;
      final waiter = _connectionWaiter;
      _connectionWaiter = null;
      if (waiter != null && !waiter.isCompleted) waiter.complete();
      _lastPong = DateTime.now();
      _startHeartbeat();
      onConnectionChanged?.call(true);

      _sub = _channel!.stream.listen(
        (data) {
          if (data is String) {
            try {
              final decoded = jsonDecode(data) as Map<String, dynamic>;
              if (decoded['type'] == 'pong') {
                _lastPong = DateTime.now();
                return;
              }
              final requestId = decoded['requestId'] as String?;
              if (requestId != null && _pending.containsKey(requestId)) {
                final completer = _pending.remove(requestId)!;
                if (!completer.isCompleted) completer.complete(decoded);
                return;
              }
              _eventController.add(decoded);
            } catch (_) {}
          }
        },
        onDone: _onDisconnected,
        onError: (_) => _onDisconnected(),
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('[WS] connect error: $e');
      if (_disposed) {
        _connecting = false;
        return;
      }
      _connected = false;
      onConnectionChanged?.call(false);
      _scheduleRetry();
    } finally {
      _connecting = false;
    }
  }

  void _startHeartbeat() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      if (_disposed || !_connected) return;
      if (DateTime.now().difference(_lastPong) > _pongDeadline) {
        debugPrint('[WS] heartbeat timeout — treating as dead socket');
        _onDisconnected();
        return;
      }
      send({'type': 'ping'});
    });
  }

  void _onDisconnected() {
    debugPrint('[WS] disconnected (retry=$_retryCount)');
    _pingTimer?.cancel();
    _pingTimer = null;
    if (_disposed) return;
    _connected = false;
    onConnectionChanged?.call(false);
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('WebSocket disconnected'));
      }
    }
    _pending.clear();
    _sub?.cancel();
    _sub = null;
    _channel = null;
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_disposed || _retryCount >= _maxRetries || _retryTimer != null) return;
    // Exponential backoff with jitter to avoid thundering herd.
    final baseSeconds = (2 << _retryCount).clamp(2, 60);
    final jitter =
        (baseSeconds * 0.3 * (DateTime.now().microsecond / 1e6)).round();
    final delay = Duration(seconds: baseSeconds + jitter);
    _retryCount++;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (!_disposed) _openConnection();
    });
  }

  void send(Map<String, dynamic> event) {
    if (_disposed || _channel == null || !_connected) return;
    try {
      _channel!.sink.add(jsonEncode(event));
    } catch (_) {}
  }

  Future<Map<String, dynamic>> request(
    Map<String, dynamic> event, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    if (_disposed || _channel == null || !_connected) {
      return Future.error(StateError('WebSocket not connected'));
    }
    final requestId = (event['requestId'] as String?) ?? const Uuid().v4();
    final payload = Map<String, dynamic>.from(event)..['requestId'] = requestId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;
    try {
      _channel!.sink.add(jsonEncode(payload));
    } catch (e) {
      _pending.remove(requestId);
      return Future.error(e);
    }
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(requestId);
      debugPrint('[WS] request timeout: ${event['type']}');
      throw TimeoutException('WebSocket request timed out', timeout);
    });
  }

  Future<void> ensureConnected({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (_connected) return;
    final waiter = _connectionWaiter ??= Completer<void>();
    unawaited(connect());
    try {
      await waiter.future.timeout(timeout);
    } on TimeoutException {
      if (identical(_connectionWaiter, waiter)) _connectionWaiter = null;
      throw StateError('WebSocket connection timed out');
    }
  }

  void sendTypingStart() => send({'type': 'typing_start'});
  void sendTypingStop() => send({'type': 'typing_stop'});

  void sendDeliveryAck(String messageId) =>
      send({'type': 'delivery_ack', 'messageId': messageId});

  Future<void> dispose() async {
    _disposed = true;
    _connected = false;
    final waiter = _connectionWaiter;
    _connectionWaiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.completeError(StateError('WebSocket disposed'));
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    onConnectionChanged = null;
    await _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    await _eventController.close();
  }
}
