import 'package:flutter/foundation.dart';

/// Status of a message in the send pipeline.
enum MessageStatus { sending, sent, delivered, read, failed }

/// Type of Signal Protocol message envelope.
enum MessageType { signal, prekey, system }

/// An end-to-end encrypted message in a conversation.
@immutable
class Message {
  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.messageType,
    required this.version,
    required this.createdAt,
    required this.status,
    this.decryptedText,
    this.encryptedPayload,
    this.isUnsent = false,
    this.isLocallyDeleted = false,
    this.isEdited = false,
    this.expiresAt,
    this.editedAt,
    this.replyToId,
    this.reaction,
  });

  final String id;
  final String conversationId;
  final String senderId;

  final String? decryptedText;
  final String? encryptedPayload;

  final MessageType messageType;
  final int version;
  final bool isUnsent;
  final bool isLocallyDeleted;

  final bool isEdited;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final DateTime? editedAt;
  final MessageStatus status;
  final String? replyToId;
  final String? reaction;

  /// Returns true if the message is past its expiry time.
  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);

  /// Returns true if the message can still be edited (within 15-minute window).
  /// Uses the original [createdAt] timestamp, not [editedAt].
  bool get isEditEligible {
    final deadline = createdAt.add(const Duration(minutes: 15));
    return DateTime.now().isBefore(deadline);
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    DateTime parseTimestamp(dynamic value) {
      if (value is int) {
        final ts = value > 1e12 ? value : value * 1000;
        return DateTime.fromMillisecondsSinceEpoch(ts.toInt());
      }
      if (value is String) {
        return DateTime.tryParse(value) ??
            DateTime.fromMillisecondsSinceEpoch(0);
      }
      return DateTime.fromMillisecondsSinceEpoch(0);
    }

    // Handle both snake_case (server/sqflite) and camelCase (older JSON)
    final isUnsent = json['is_unsent'] ?? json['isUnsent'];
    final isLocallyDeleted =
        json['is_locally_deleted'] ?? json['isLocallyDeleted'];
    final isEdited = json['is_edited'] ?? json['isEdited'];
    final messageType = json['message_type'] ?? json['messageType'];
    final createdAt = json['created_at'] ?? json['createdAt'];
    final expiresAt = json['expires_at'] ?? json['expiresAt'];
    final editedAt = json['edited_at'] ?? json['editedAt'];
    final replyToId = json['reply_to_id'] ?? json['replyToId'];
    final deliveredAt = json['delivered_at'] ?? json['deliveredAt'];
    final readAt = json['read_at'] ?? json['readAt'];
    final status = json['status'] ??
        (readAt != null
            ? 'read'
            : deliveredAt != null
                ? 'delivered'
                : 'sent');

    return Message(
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String? ??
          json['conversationId'] as String? ??
          '',
      senderId:
          json['sender_id'] as String? ?? json['senderId'] as String? ?? '',
      decryptedText: json['decrypted_text'] as String?,
      encryptedPayload: json['encrypted_payload'] as String? ??
          json['encryptedPayload'] as String?,
      messageType: MessageType.values.firstWhere(
        (e) => e.name == (messageType as String? ?? 'signal'),
        orElse: () => MessageType.signal,
      ),
      version: (json['version'] as int?) ?? 1,
      isUnsent: isUnsent is bool ? isUnsent : ((isUnsent as int?) ?? 0) == 1,
      isLocallyDeleted: isLocallyDeleted is bool
          ? isLocallyDeleted
          : ((isLocallyDeleted as int?) ?? 0) == 1,
      isEdited: isEdited is bool ? isEdited : ((isEdited as int?) ?? 0) == 1,
      createdAt: parseTimestamp(createdAt),
      expiresAt: expiresAt != null ? parseTimestamp(expiresAt) : null,
      editedAt: editedAt != null ? parseTimestamp(editedAt) : null,
      status: MessageStatus.values.firstWhere(
        (e) => e.name == (status as String? ?? 'sent'),
        orElse: () => MessageStatus.sent,
      ),
      replyToId: replyToId as String?,
      reaction: json['reaction'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'conversation_id': conversationId,
        'sender_id': senderId,
        if (decryptedText != null) 'decrypted_text': decryptedText,
        if (encryptedPayload != null) 'encrypted_payload': encryptedPayload,
        'message_type': messageType.name,
        'version': version,
        'is_unsent': isUnsent ? 1 : 0,
        'is_locally_deleted': isLocallyDeleted ? 1 : 0,
        'is_edited': isEdited ? 1 : 0,
        'created_at': createdAt.millisecondsSinceEpoch,
        if (expiresAt != null) 'expires_at': expiresAt!.millisecondsSinceEpoch,
        if (editedAt != null) 'edited_at': editedAt!.millisecondsSinceEpoch,
        'status': status.name,
        if (replyToId != null) 'reply_to_id': replyToId,
        if (reaction != null) 'reaction': reaction,
      };

  Message copyWith({
    String? id,
    String? conversationId,
    String? senderId,
    String? decryptedText,
    String? encryptedPayload,
    MessageType? messageType,
    int? version,
    bool? isUnsent,
    bool? isLocallyDeleted,
    bool? isEdited,
    DateTime? createdAt,
    DateTime? expiresAt,
    DateTime? editedAt,
    MessageStatus? status,
    bool clearDecryptedText = false,
    String? replyToId,
    bool clearReplyToId = false,
    String? reaction,
    bool clearReaction = false,
  }) {
    return Message(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      senderId: senderId ?? this.senderId,
      decryptedText:
          clearDecryptedText ? null : (decryptedText ?? this.decryptedText),
      encryptedPayload: encryptedPayload ?? this.encryptedPayload,
      messageType: messageType ?? this.messageType,
      version: version ?? this.version,
      isUnsent: isUnsent ?? this.isUnsent,
      isLocallyDeleted: isLocallyDeleted ?? this.isLocallyDeleted,
      isEdited: isEdited ?? this.isEdited,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      editedAt: editedAt ?? this.editedAt,
      status: status ?? this.status,
      replyToId: clearReplyToId ? null : (replyToId ?? this.replyToId),
      reaction: clearReaction ? null : (reaction ?? this.reaction),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Message && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'Message(id: $id, senderId: $senderId, status: ${status.name})';
}
