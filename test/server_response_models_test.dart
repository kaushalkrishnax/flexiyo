import 'package:flexiyo/models/conversation.dart';
import 'package:flexiyo/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {

  test('parses the Worker conversation response', () {
    final conversation = Conversation.fromJson(const {
      'id': 'conversation-id',
      'conversant': {'id': 'bob-id', 'username': 'bob'},
      'disappearingTimer': 60,
      'lastMessageAt': 1700000000,
      'lastMessagePreview': null,
      'unreadCount': 2,
    });

    expect(conversation.otherUserId, 'bob-id');
    expect(conversation.otherUsername, 'bob');
    expect(conversation.disappearingTimer, 60);
    expect(conversation.unreadCount, 2);
    expect(conversation.lastMessageAt?.millisecondsSinceEpoch, 1700000000000);
  });

  test('parses the Worker message response', () {
    final message = Message.fromJson(const {
      'id': 'message-id',
      'conversationId': 'conversation-id',
      'senderId': 'alice-id',
      'encryptionVersion': 2,
      'ciphertext': 'ciphertext',
      'nonce': 'nonce-value',
      'authTag': 'auth-tag-value',
      'keyEpoch': 3,
      'messageType': 'signal',
      'replyToId': 'parent-message-id',
      'version': 2,
      'isUnsent': false,
      'createdAt': 1700000000,
      'expiresAt': null,
      'editedAt': 1700000100,
      'systemData': null,
    });

    expect(message.conversationId, 'conversation-id');
    expect(message.senderId, 'alice-id');
    expect(message.encryptionVersion, 2);
    expect(message.encryptedPayload, 'ciphertext');
    expect(message.nonce, 'nonce-value');
    expect(message.authTag, 'auth-tag-value');
    expect(message.keyEpoch, 3);
    expect(message.messageType, MessageType.signal);
    expect(message.replyToId, 'parent-message-id');
    expect(message.createdAt.millisecondsSinceEpoch, 1700000000000);
    expect(message.editedAt?.millisecondsSinceEpoch, 1700000100000);
  });

  test('parses and manipulates message emoji reactions', () {
    final message = Message.fromJson(const {
      'id': 'msg-1',
      'conversationId': 'conv-1',
      'senderId': 'user-1',
      'messageType': 'signal',
      'version': 1,
      'createdAt': 1700000000,
      'reaction': '❤️',
    });

    expect(message.reaction, '❤️');
    expect(message.toJson()['reaction'], '❤️');

    final updated = message.copyWith(reaction: '🔥');
    expect(updated.reaction, '🔥');

    final cleared = updated.copyWith(clearReaction: true);
    expect(cleared.reaction, isNull);
    expect(cleared.toJson().containsKey('reaction'), isFalse);
  });

  test('parses conversation pinned, muted, restricted flags', () {
    final conv = Conversation.fromJson(const {
      'id': 'conv-1',
      'conversant': {'id': 'user-2', 'username': 'charlie'},
      'createdAt': 1700000000,
      'isPinned': true,
      'isMuted': true,
      'isRestricted': true,
    });

    expect(conv.isPinned, isTrue);
    expect(conv.isMuted, isTrue);
    expect(conv.isRestricted, isTrue);

    final unpinned = conv.copyWith(isPinned: false);
    expect(unpinned.isPinned, isFalse);
    expect(unpinned.isMuted, isTrue);
  });
}
