import 'package:flutter/foundation.dart';

/// A one-to-one conversation between the current user and another user.
@immutable
class Conversation {
  const Conversation({
    required this.id,
    required this.otherUserId,
    required this.otherUsername,
    required this.disappearingTimer,
    this.lastMessageAt,
    this.lastMessagePreview,
    this.unreadCount = 0,
    this.requestStatus = 'accepted',
    this.initiatedById,
    this.isPinned = false,
    this.isMuted = false,
    this.isRestricted = false,
    this.peerSeenAt,
    this.lastMessageIsMine = false,
  });

  final String id;
  final String otherUserId;
  final String otherUsername;

  /// Timer after a recipient reads a message; -1 means immediately, 0 disabled.
  final int disappearingTimer;
  final DateTime? lastMessageAt;
  final String? lastMessagePreview;
  final int unreadCount;
  final String requestStatus;
  final String? initiatedById;
  final bool isPinned;
  final bool isMuted;
  final bool isRestricted;

  /// When the other user last read a message of mine; drives "Seen …".
  final DateTime? peerSeenAt;

  /// Whether the newest message in the conversation is mine.
  final bool lastMessageIsMine;

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final otherUser =
        json['conversant'] is Map ? json['conversant'] as Map : const {};
    final otherUserId =
        (json['otherUserId'] ?? otherUser['id'] ?? '') as String;
    final otherUsername =
        (json['otherUsername'] ?? otherUser['username'] ?? 'Unknown') as String;

    final lastMessageAtValue = json['lastMessageAt'];
    DateTime? parsedLastMessageAt;
    if (lastMessageAtValue is int) {
      final ts = lastMessageAtValue > 1e12
          ? lastMessageAtValue
          : lastMessageAtValue * 1000;
      parsedLastMessageAt = DateTime.fromMillisecondsSinceEpoch(ts.toInt());
    }

    return Conversation(
      id: json['id'] as String,
      otherUserId: otherUserId,
      otherUsername: otherUsername,
      disappearingTimer: (json['disappearingTimer'] as int?) ?? 0,
      lastMessageAt: parsedLastMessageAt,
      lastMessagePreview: json['lastMessagePreview'] as String?,
      unreadCount: (json['unreadCount'] as int?) ?? 0,
      requestStatus: json['requestStatus'] as String? ?? 'accepted',
      initiatedById: json['initiatedById'] as String?,
      isPinned: json['isPinned'] == true,
      isMuted: json['isMuted'] == true,
      isRestricted: json['isRestricted'] == true,
      peerSeenAt: json['peerSeenAt'] != null
          ? _parseTimestamp(json['peerSeenAt'])
          : null,
      lastMessageIsMine: json['lastMessageIsMine'] == true,
    );
  }

  static DateTime? _parseTimestamp(dynamic value) {
    if (value is int) {
      final ts = value > 1e12 ? value : value * 1000;
      return DateTime.fromMillisecondsSinceEpoch(ts.toInt());
    }
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  factory Conversation.fromDbJson(Map<String, dynamic> row) {
    final lastMessageAt = row['last_message_at'] as int?;
    return Conversation(
      id: row['id'] as String,
      otherUserId: row['other_user_id'] as String,
      otherUsername: row['other_username'] as String,
      disappearingTimer: (row['disappearing_timer'] as int?) ?? 0,
      lastMessageAt: lastMessageAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastMessageAt),
      lastMessagePreview: row['last_message_preview'] as String?,
      unreadCount: (row['unread_count'] as int?) ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'other_user_id': otherUserId,
        'other_username': otherUsername,
        'disappearing_timer': disappearingTimer,
        if (lastMessageAt != null)
          'last_message_at': lastMessageAt!.millisecondsSinceEpoch,
        if (lastMessagePreview != null)
          'last_message_preview': lastMessagePreview,
        'unread_count': unreadCount,
        'request_status': requestStatus,
        if (initiatedById != null) 'initiated_by_id': initiatedById,
        'is_pinned': isPinned ? 1 : 0,
        'is_muted': isMuted ? 1 : 0,
        'is_restricted': isRestricted ? 1 : 0,
      };

  Conversation copyWith({
    String? id,
    String? otherUserId,
    String? otherUsername,
    int? disappearingTimer,
    DateTime? lastMessageAt,
    String? lastMessagePreview,
    int? unreadCount,
    String? requestStatus,
    String? initiatedById,
    bool? isPinned,
    bool? isMuted,
    bool? isRestricted,
    bool? isBlocked,
    DateTime? peerSeenAt,
    bool? lastMessageIsMine,
  }) {
    return Conversation(
      id: id ?? this.id,
      otherUserId: otherUserId ?? this.otherUserId,
      otherUsername: otherUsername ?? this.otherUsername,
      disappearingTimer: disappearingTimer ?? this.disappearingTimer,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
      unreadCount: unreadCount ?? this.unreadCount,
      requestStatus: requestStatus ?? this.requestStatus,
      initiatedById: initiatedById ?? this.initiatedById,
      isPinned: isPinned ?? this.isPinned,
      isMuted: isMuted ?? this.isMuted,
      isRestricted: isRestricted ?? this.isRestricted,
      peerSeenAt: peerSeenAt ?? this.peerSeenAt,
      lastMessageIsMine: lastMessageIsMine ?? this.lastMessageIsMine,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Conversation && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'Conversation(id: $id, otherUsername: $otherUsername, isPinned: $isPinned, isMuted: $isMuted, isRestricted: $isRestricted)';
}
