import 'package:flexiyo/services/media_service.dart';
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
    this.senderDeviceId,
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
    this.readAt,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final int? senderDeviceId;

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

  /// When the recipient read one of my messages; null until read.
  final DateTime? readAt;

  /// Parses the inline media envelope (`FYMEDIA:...`) from the decrypted text.
  MediaRef? get mediaRef {
    if (decryptedText == null ||
        !decryptedText!.startsWith(MediaRef.mediaPrefix)) {
      return null;
    }
    return MediaRef.parse(decryptedText!);
  }

  /// True when this message carries a camera/gallery image or voice note.
  bool get isMedia => mediaRef != null;
  bool get isVoiceMedia => mediaRef?.kind == MediaKind.voice;

  /// Returns true if the message is past its expiry time.
  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);

  /// Returns true if the message can still be edited (within 15-minute window).
  /// Uses the original [createdAt] timestamp, not [editedAt].
  bool get isEditEligible {
    final deadline = createdAt.add(const Duration(minutes: 15));
    return DateTime.now().isBefore(deadline);
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    final deliveredAt = json['deliveredAt'];
    final readAt = json['readAt'];
    final status = json['status'] ??
        (readAt != null
            ? 'read'
            : deliveredAt != null
                ? 'delivered'
                : 'sent');

    return Message(
      id: json['id'] as String,
      conversationId: json['conversationId'] as String? ?? '',
      senderId: json['senderId'] as String? ?? '',
      senderDeviceId: json['senderDeviceId'] as int?,
      encryptedPayload: json['encryptedPayload'] as String?,
      messageType: MessageType.values.firstWhere(
        (e) => e.name == ((json['messageType'] as String?) ?? 'signal'),
        orElse: () => MessageType.signal,
      ),
      version: (json['version'] as int?) ?? 1,
      isUnsent: json['isUnsent'] == true,
      isEdited: json['isEdited'] == true,
      createdAt: _parseTimestamp(json['createdAt']),
      expiresAt:
          json['expiresAt'] != null ? _parseTimestamp(json['expiresAt']) : null,
      editedAt:
          json['editedAt'] != null ? _parseTimestamp(json['editedAt']) : null,
      status: MessageStatus.values.firstWhere(
        (e) => e.name == (status as String? ?? 'sent'),
        orElse: () => MessageStatus.sent,
      ),
      replyToId: json['replyToId'] as String?,
      reaction: json['reaction'] as String?,
      readAt: json['readAt'] != null ? _parseTimestamp(json['readAt']) : null,
    );
  }

  factory Message.fromDbJson(Map<String, dynamic> json) {
    final status = json['status'] as String? ?? 'sent';
    return Message(
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String,
      senderId: json['sender_id'] as String,
      senderDeviceId: json['sender_device_id'] as int?,
      decryptedText: json['decrypted_text'] as String?,
      encryptedPayload: json['encrypted_payload'] as String?,
      messageType: MessageType.values.firstWhere(
        (e) => e.name == (json['message_type'] as String? ?? 'signal'),
        orElse: () => MessageType.signal,
      ),
      version: (json['version'] as int?) ?? 1,
      isUnsent: (json['is_unsent'] as int? ?? 0) == 1,
      isLocallyDeleted: (json['is_locally_deleted'] as int? ?? 0) == 1,
      isEdited: (json['is_edited'] as int? ?? 0) == 1,
      createdAt: _parseTimestamp(json['created_at']),
      expiresAt: json['expires_at'] != null
          ? _parseTimestamp(json['expires_at'])
          : null,
      editedAt:
          json['edited_at'] != null ? _parseTimestamp(json['edited_at']) : null,
      status: MessageStatus.values.firstWhere(
        (e) => e.name == status,
        orElse: () => MessageStatus.sent,
      ),
      replyToId: json['reply_to_id'] as String?,
      reaction: json['reaction'] as String?,
      readAt: json['read_at'] != null ? _parseTimestamp(json['read_at']) : null,
    );
  }

  static DateTime _parseTimestamp(dynamic value) {
    if (value is int) {
      final timestamp = value > 1e12 ? value : value * 1000;
      return DateTime.fromMillisecondsSinceEpoch(timestamp.toInt());
    }
    if (value is String) {
      return DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'conversation_id': conversationId,
        'sender_id': senderId,
        if (senderDeviceId != null) 'sender_device_id': senderDeviceId,
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
        if (readAt != null) 'read_at': readAt!.millisecondsSinceEpoch,
      };

  Message copyWith({
    String? id,
    String? conversationId,
    String? senderId,
    int? senderDeviceId,
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
    DateTime? readAt,
  }) {
    return Message(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      senderId: senderId ?? this.senderId,
      senderDeviceId: senderDeviceId ?? this.senderDeviceId,
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
      readAt: readAt ?? this.readAt,
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
