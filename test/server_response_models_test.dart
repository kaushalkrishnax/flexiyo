import 'package:flexiyo/models/conversation.dart';
import 'package:flexiyo/models/key_bundle.dart';
import 'package:flexiyo/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses the Worker device key bundle response', () {
    final bundle = KeyBundle.fromJson(const {
      'userId': 'bob-id',
      'deviceId': '1',
      'registrationId': 42,
      'identityKey': 'identity',
      'signedPreKey': {
        'keyId': 7,
        'publicKey': 'signed-key',
        'signature': 'signature',
      },
      'preKey': {'keyId': 8, 'publicKey': 'pre-key'},
    });

    expect(bundle.userId, 'bob-id');
    expect(bundle.deviceId, 1);
    expect(bundle.signedPreKeyId, 7);
    expect(bundle.preKeyId, 8);
  });

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
      'encryptedPayload': 'ciphertext',
      'messageType': 'prekey',
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
    expect(message.messageType, MessageType.prekey);
    expect(message.replyToId, 'parent-message-id');
    expect(message.createdAt.millisecondsSinceEpoch, 1700000000000);
    expect(message.editedAt?.millisecondsSinceEpoch, 1700000100000);
  });
}
