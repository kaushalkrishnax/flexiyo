import 'package:flexiyo/models/message.dart';
import 'package:flexiyo/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Message _message({
  required String id,
  required String senderId,
  String? text,
  String? replyToId,
  MessageStatus status = MessageStatus.sent,
}) {
  return Message(
    id: id,
    conversationId: 'conversation-1',
    senderId: senderId,
    messageType: MessageType.signal,
    version: 1,
    createdAt: DateTime(2026, 1, 1, 12),
    status: status,
    decryptedText: text,
    replyToId: replyToId,
  );
}

Future<void> _pumpBubble(
  WidgetTester tester, {
  required Message message,
  required bool isMine,
  Message? replyTo,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            MessageBubble(
              message: message,
              isMine: isMine,
              isFirst: true,
              isLast: true,
              showAvatar: !isMine,
              isSelected: false,
              otherUsername: 'aadha',
              replyToMessage: replyTo,
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a reply renders the quoted bubble above the answer',
      (tester) async {
    final parent = _message(id: 'p1', senderId: 'them', text: 'What is it?');
    final reply = _message(
      id: 'm1',
      senderId: 'me',
      text: 'Just testing',
      replyToId: 'p1',
    );

    await _pumpBubble(tester, message: reply, isMine: true, replyTo: parent);

    expect(find.text('What is it?'), findsOneWidget);
    expect(find.text('Just testing'), findsOneWidget);
    expect(find.text('You replied to aadha'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an incoming reply quotes the message it answers',
      (tester) async {
    final parent = _message(id: 'p1', senderId: 'me', text: 'Sent earlier');
    final reply = _message(
      id: 'm2',
      senderId: 'them',
      text: 'Got it',
      replyToId: 'p1',
    );

    await _pumpBubble(tester, message: reply, isMine: false, replyTo: parent);

    expect(find.text('Sent earlier'), findsOneWidget);
    expect(find.text('Got it'), findsOneWidget);
    expect(find.text('aadha replied to you'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the quote pipe sits on the right for my replies',
      (tester) async {
    final parent = _message(id: 'p1', senderId: 'them', text: 'What is it?');
    final reply = _message(
      id: 'm1',
      senderId: 'me',
      text: 'Just testing',
      replyToId: 'p1',
    );

    await _pumpBubble(tester, message: reply, isMine: true, replyTo: parent);

    final pipe = find.byKey(const ValueKey('replyPipe'));
    final quote = find.text('What is it?');
    expect(
      tester.getCenter(pipe).dx,
      greaterThan(tester.getCenter(quote).dx),
    );
  });

  testWidgets('the quote pipe sits on the left for incoming replies',
      (tester) async {
    final parent = _message(id: 'p1', senderId: 'me', text: 'Sent earlier');
    final reply = _message(
      id: 'm2',
      senderId: 'them',
      text: 'Got it',
      replyToId: 'p1',
    );

    await _pumpBubble(tester, message: reply, isMine: false, replyTo: parent);

    final pipe = find.byKey(const ValueKey('replyPipe'));
    final quote = find.text('Sent earlier');
    expect(
      tester.getCenter(pipe).dx,
      lessThan(tester.getCenter(quote).dx),
    );
  });

  testWidgets('the reply caption is grey and outside the quoted bubble',
      (tester) async {
    final parent = _message(id: 'p1', senderId: 'them', text: 'What is it?');
    final reply = _message(
      id: 'm1',
      senderId: 'me',
      text: 'Just testing',
      replyToId: 'p1',
    );

    await _pumpBubble(tester, message: reply, isMine: true, replyTo: parent);

    final caption = tester.widget<Text>(find.text('You replied to aadha'));
    expect(caption.style?.color, Colors.grey[500]);
    expect(
      tester.getBottomLeft(find.text('You replied to aadha')).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.text('What is it?')).dy),
    );
  });

  testWidgets('the quoted bubble keeps the size of a regular bubble',
      (tester) async {
    final parent = _message(id: 'p1', senderId: 'them', text: 'What is it?');
    final reply = _message(
      id: 'm1',
      senderId: 'me',
      text: 'Just testing',
      replyToId: 'p1',
    );

    await _pumpBubble(tester, message: reply, isMine: true, replyTo: parent);

    final quote = tester.widget<Text>(find.text('What is it?'));
    final answer = tester.widget<Text>(find.text('Just testing'));
    expect(quote.style?.fontSize, answer.style?.fontSize);

    final caption = tester.widget<Text>(find.text('You replied to aadha'));
    expect(caption.style?.fontSize, 13);
  });

  testWidgets('the read receipt uses the relative seen label', (tester) async {
    final message = _message(
      id: 'm3',
      senderId: 'me',
      text: 'Seen this',
      status: MessageStatus.read,
    ).copyWith(readAt: DateTime.now().subtract(const Duration(minutes: 5)));

    await _pumpBubble(tester, message: message, isMine: true);

    expect(find.text('Seen 5m ago'), findsOneWidget);
  });
}
