import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// WebSocket connection for a single conversation with automatic reconnection.
class WsService {
  WsService({this.conversationId, required this.wsUrl});

  final String? conversationId;
  final String wsUrl;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  bool _disposed = false;
  bool _connecting = false;
  Timer? _retryTimer;

  int _retryCount = 0;
  static const int _maxRetries = 5;

  final _eventController = StreamController<Map<String, dynamic>>.broadcast();

  /// Stream of decoded JSON events from the server.
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  bool _connected = false;
  bool get isConnected => _connected;
  void Function(bool isConnected)? onConnectionChanged;

  Future<void> connect() async {
    if (_disposed || _connecting) return;
    _retryCount = 0;
    await _openConnection();
  }

  Future<void> _openConnection() async {
    if (_disposed || _connecting) return;
    _connecting = true;

    try {
      final uri = Uri.parse(wsUrl);
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;
      if (_disposed) {
        await _channel?.sink.close();
        _connecting = false;
        return;
      }
      _connected = true;
      _retryCount = 0;
      onConnectionChanged?.call(true);

      _sub = _channel!.stream.listen(
        (data) {
          if (data is String) {
            try {
              final decoded = jsonDecode(data) as Map<String, dynamic>;
              _eventController.add(decoded);
            } catch (_) {}
          }
        },
        onDone: _onDisconnected,
        onError: (_) => _onDisconnected(),
        cancelOnError: false,
      );
    } catch (_) {
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

  void _onDisconnected() {
    if (_disposed) return;
    _connected = false;
    onConnectionChanged?.call(false);
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

  void sendTypingStart() => send({'type': 'typing_start'});
  void sendTypingStop() => send({'type': 'typing_stop'});

  void sendDeliveryAck(String messageId) =>
      send({'type': 'delivery_ack', 'messageId': messageId});

  Future<void> dispose() async {
    _disposed = true;
    _connected = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    onConnectionChanged = null;
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
    await _eventController.close();
  }
}
