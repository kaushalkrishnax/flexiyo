import 'package:flexiyo/models/message.dart';
import 'package:flexiyo/providers/chat/conversation_pagination.dart';
import 'package:flutter_test/flutter_test.dart';

Message _message(
  String id, {
  required int second,
  String? text,
  MessageStatus status = MessageStatus.sent,
}) {
  return Message(
    id: id,
    conversationId: 'conversation-1',
    senderId: 'user-a',
    messageType: MessageType.signal,
    version: 1,
    createdAt: DateTime.fromMillisecondsSinceEpoch(second * 1000),
    status: status,
    decryptedText: text,
  );
}

void main() {
  group('mergeOlderPage', () {
    test('adds an older batch in chronological order', () {
      final older = [
        _message('m1', second: 1),
        _message('m2', second: 2),
      ];
      final current = [
        _message('m3', second: 3),
        _message('m4', second: 4),
      ];

      final merged = mergeOlderPage(older: older, current: current);

      expect(merged.map((m) => m.id), ['m1', 'm2', 'm3', 'm4']);
    });

    test('de-duplicates overlapping pages by id', () {
      final older = [
        _message('m1', second: 1),
        _message('m2', second: 2, text: 'older copy'),
      ];
      final current = [
        _message('m2', second: 2, text: 'hydrated copy'),
        _message('m3', second: 3),
      ];

      final merged = mergeOlderPage(older: older, current: current);

      expect(merged.map((m) => m.id), ['m1', 'm2', 'm3']);
      expect(merged[1].decryptedText, 'hydrated copy');
    });

    test('breaks timestamp ties by id so order stays stable', () {
      final older = [_message('b', second: 5)];
      final current = [_message('a', second: 5)];

      final merged = mergeOlderPage(older: older, current: current);

      expect(merged.map((m) => m.id), ['a', 'b']);
    });

    test('keeps current messages when a page is empty', () {
      final current = [_message('m1', second: 1)];

      final merged = mergeOlderPage(older: const [], current: current);

      expect(merged.map((m) => m.id), ['m1']);
    });
  });

  group('hasOlderPage', () {
    test('continues while a full page is returned', () {
      expect(hasOlderPage(fetched: 10), isTrue);
      expect(hasOlderPage(fetched: 11), isTrue);
    });

    test('stops below the page size', () {
      expect(hasOlderPage(fetched: 9), isFalse);
      expect(hasOlderPage(fetched: 0), isFalse);
    });
  });
}
