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
  });

  final String id;
  final String otherUserId;
  final String otherUsername;

  /// Disappearing message timer in seconds (0 = disabled).
  final int disappearingTimer;
  final DateTime? lastMessageAt;
  final String? lastMessagePreview;
  final int unreadCount;
  final String requestStatus;
  final String? initiatedById;

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final otherUser =
        json['conversant'] is Map ? json['conversant'] as Map : const {};
    final otherUserId = (json['other_user_id'] ??
        json['otherUserId'] ??
        otherUser['id'] ??
        '') as String;
    final otherUsername = (json['other_username'] ??
        json['otherUsername'] ??
        otherUser['username'] ??
        'Unknown') as String;

    final lastMessageAtValue = json['last_message_at'] ?? json['lastMessageAt'];
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
      disappearingTimer: (json['disappearing_timer'] as int?) ??
          (json['disappearingTimer'] as int?) ??
          0,
      lastMessageAt: parsedLastMessageAt,
      lastMessagePreview: json['last_message_preview'] as String? ??
          json['lastMessagePreview'] as String?,
      unreadCount:
          (json['unread_count'] as int?) ?? (json['unreadCount'] as int?) ?? 0,
      requestStatus: json['request_status'] as String? ??
          json['requestStatus'] as String? ??
          'accepted',
      initiatedById: json['initiated_by_id'] as String? ??
          json['initiatedById'] as String?,
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
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Conversation && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Conversation(id: $id, otherUsername: $otherUsername)';
}
