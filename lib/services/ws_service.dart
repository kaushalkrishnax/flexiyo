import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// WebSocket connection for a single conversation with automatic reconnection.
class WsService {
  WsService({required this.conversationId, required this.wsUrl});

  final String conversationId;
  final String wsUrl;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  bool _disposed = false;

  int _retryCount = 0;
  static const int _maxRetries = 5;

  final _eventController = StreamController<Map<String, dynamic>>.broadcast();

  /// Stream of decoded JSON events from the server.
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  bool _connected = false;
  bool get isConnected => _connected;
  void Function(bool isConnected)? onConnectionChanged;

  // Connection management

  Future<void> connect() async {
    if (_disposed) return;
    _retryCount = 0;
    await _openConnection();
  }

  Future<void> _openConnection() async {
    if (_disposed) return;

    try {
      final uri = Uri.parse(wsUrl);
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;
      if (_disposed) {
        await _channel?.sink.close();
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
            } catch (_) {
              // ignore malformed frames
            }
          }
        },
        onDone: _onDisconnected,
        onError: (_) => _onDisconnected(),
        cancelOnError: false,
      );
    } catch (_) {
      if (_disposed) return;
      _connected = false;
      onConnectionChanged?.call(false);
      _scheduleRetry();
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
    if (_disposed || _retryCount >= _maxRetries) return;
    final delay = Duration(seconds: (2 << _retryCount).clamp(2, 60));
    _retryCount++;
    Future.delayed(delay, () {
      if (!_disposed) _openConnection();
    });
  }

  // Sending client events

  void send(Map<String, dynamic> event) {
    if (_disposed || _channel == null || !_connected) return;
    try {
      _channel!.sink.add(jsonEncode(event));
    } catch (_) {
      // Connection may have closed; ignore
    }
  }

  void sendTypingStart() => send({'type': 'typing_start'});
  void sendTypingStop() => send({'type': 'typing_stop'});

  void sendDeliveryAck(String messageId) =>
      send({'type': 'delivery_ack', 'messageId': messageId});

  // Dispose

  Future<void> dispose() async {
    _disposed = true;
    _connected = false;
    onConnectionChanged = null;
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
    await _eventController.close();
  }
}
