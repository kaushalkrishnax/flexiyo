import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flexiyo/services/ws_service.dart';

/// A test double for [_ChannelLike] backed by in-memory controllers.
///
/// * `simulateMessage(data)` delivers `data` as if the server sent it.
/// * Frames written to `sink` are readable on `sentFrames`.
class FakeChannel implements ChannelLike {
  final _streamCtrl = StreamController<dynamic>.broadcast();
  final _sentCtrl = StreamController<dynamic>.broadcast();

  @override
  Stream<dynamic> get stream => _streamCtrl.stream;

  @override
  Sink<dynamic> get sink => _sentCtrl.sink;

  @override
  Future<void> get ready => _ready.future;
  final _ready = Completer<void>()..complete();

  /// Delivers [data] to the service as a server-sent message.
  void simulateMessage(dynamic data) => _streamCtrl.add(data);

  /// Signals that the server closed the socket.
  void simulateDisconnect() {
    _streamCtrl.close();
    _sentCtrl.close();
  }

  /// Stream of frames the client sent to the "server".
  Stream<dynamic> get sentFrames => _sentCtrl.stream;

  void close() {
    _streamCtrl.close();
    _sentCtrl.close();
  }
}

Future<WsService> connectedWs({
  required FakeChannel channel,
}) async {
  final ws = WsService(wsUrl: 'ws://test/fake', channel: channel);
  final connected = Completer<void>();
  ws.onConnectionChanged = (ok) {
    if (ok) connected.complete();
  };
  await ws.connect();
  await connected.future;
  return ws;
}

void main() {
  group('WsService request/ack protocol', () {
    late FakeChannel channel;

    setUp(() {
      channel = FakeChannel();
    });

    tearDown(() {
      channel.close();
    });

    test('resolves a pending request when the matching ack arrives', () async {
      final ws = await connectedWs(channel: channel);

      final sentFuture = channel.sentFrames.first;
      final request = ws.request({
        'type': 'send_message',
        'requestId': 'req-1',
        'messageId': 'msg-1',
      });
      final frame = jsonDecode(await sentFuture) as Map;
      expect(frame['requestId'], 'req-1');
      expect(frame['type'], 'send_message');

      channel.simulateMessage(
        jsonEncode({'type': 'ack', 'requestId': 'req-1', 'ok': true}),
      );

      final response = await request;
      expect(response['type'], 'ack');
      expect(response['ok'], true);
    });

    test('does not route an ack to the public events stream', () async {
      final ws = await connectedWs(channel: channel);

      final events = <Map<dynamic, dynamic>>[];
      final sub = ws.events.listen((e) => events.add(e));

      ws.request({'type': 'send_message', 'requestId': 'req-2'});
      channel.simulateMessage(
        jsonEncode({'type': 'ack', 'requestId': 'req-2', 'ok': true}),
      );

      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(events, isEmpty);
      await sub.cancel();
    });

    test('routes non-request events to the public events stream', () async {
      final ws = await connectedWs(channel: channel);

      final events = <Map<dynamic, dynamic>>[];
      final sub = ws.events.listen((e) => events.add(e));

      channel.simulateMessage(
        jsonEncode({
          'type': 'new_message',
          'messageId': 'msg-9',
          'senderId': 'peer',
        }),
      );

      await Future.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(events.first['type'], 'new_message');
      await sub.cancel();
    });

    test('fails a pending request on timeout', () async {
      final ws = await connectedWs(channel: channel);

      await expectLater(
        ws.request({'type': 'send_message', 'requestId': 'req-3'},
            timeout: Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('fails all pending requests when the socket disconnects', () async {
      final ws = await connectedWs(channel: channel);

      final request = ws.request({'type': 'send_message', 'requestId': 'req-4'});

      channel.simulateDisconnect();

      await expectLater(request, throwsA(isA<StateError>()));
    });
  });
}
