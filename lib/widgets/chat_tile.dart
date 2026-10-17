import 'package:flexiyo/models/conversation.dart';
import 'package:flexiyo/widgets/avatar.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Flat conversation list row with avatar, preview, timestamp, and unread badge.
class ChatTile extends StatelessWidget {
  const ChatTile({
    super.key,
    required this.conversation,
    required this.onTap,
  });

  final Conversation conversation;
  final VoidCallback onTap;

  /// Formats [dt] as a compact relative timestamp.
  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inMinutes < 1) return 'Just now';

    final today = DateTime(now.year, now.month, now.day);
    final dtDay = DateTime(dt.year, dt.month, dt.day);

    if (dtDay == today) return DateFormat('HH:mm').format(dt);
    if (diff.inDays < 7) return DateFormat('EEE').format(dt);
    return DateFormat('dd/MM/yy').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final hasUnread = conversation.unreadCount > 0;
    final preview = conversation.lastMessagePreview;
    final timestamp = conversation.lastMessageAt;

    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 72,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              // Avatar
              UserAvatar(username: conversation.otherUsername, radius: 26),
              const SizedBox(width: 12),

              // Title and preview
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Username
                    Text(
                      conversation.otherUsername,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.bodyLarge?.copyWith(
                        fontWeight:
                            hasUnread ? FontWeight.w700 : FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    // Last message preview / message count
                    Text(
                      hasUnread
                              ? (conversation.unreadCount >= 4
                                  ? '4+ new messages'
                                  : conversation.unreadCount == 3
                                      ? '3 new messages'
                                      : conversation.unreadCount == 2
                                          ? '2 new messages'
                                          : (preview != null &&
                                                  preview != 'Encrypted message'
                                              ? preview
                                              : 'Sent a message'))
                              : (preview != null &&
                                      preview != 'Encrypted message'
                                  ? preview
                                  : conversation.lastMessageAt != null
                                      ? 'Sent a message'
                                      : 'New conversation'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              // Timestamp and unread badge
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Timestamp
                  if (timestamp != null)
                    Text(
                      _formatTimestamp(timestamp),
                      style: tt.labelSmall?.copyWith(
                        color: hasUnread ? cs.primary : cs.onSurfaceVariant,
                        fontWeight:
                            hasUnread ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  const SizedBox(height: 4),
                  // Unread badge
                  if (hasUnread)
                    Container(
                      constraints: const BoxConstraints(
                        minWidth: 20,
                        minHeight: 20,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        color: cs.primary,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        conversation.unreadCount > 99
                            ? '99+'
                            : '${conversation.unreadCount}',
                        textAlign: TextAlign.center,
                        style: tt.labelSmall?.copyWith(
                          color: cs.onPrimary,
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                        ),
                      ),
                    )
                  else
                    const SizedBox(height: 20),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
