import 'package:flexiyo/models/conversation.dart';
import 'package:flexiyo/models/message.dart';
import 'package:flexiyo/widgets/avatar.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class AppPopupMenu {
  AppPopupMenu._();

  static Future<void> showMessageMenu(
    BuildContext context, {
    required bool isMine,
    required Message message,
    required Offset tapPosition,
    required VoidCallback onReply,
    required VoidCallback onCopy,
    VoidCallback? onUnsend,
    required VoidCallback onDeleteForMe,
    ValueChanged<String>? onReact,
  }) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'MessageContextMenu',
      barrierColor: Colors.black.withValues(alpha: 0.55),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, animation, secondaryAnimation) {
        return _MessageMenuOverlay(
          isMine: isMine,
          message: message,
          tapPosition: tapPosition,
          onReply: onReply,
          onCopy: onCopy,
          onUnsend: onUnsend,
          onDeleteForMe: onDeleteForMe,
          onReact: onReact,
        );
      },
      transitionBuilder: (ctx, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.88, end: 1.0).animate(curved),
            alignment: isMine ? Alignment.topRight : Alignment.topLeft,
            child: child,
          ),
        );
      },
    );
  }

  static Future<void> showInboxModal(
    BuildContext context, {
    required Conversation conversation,
    required VoidCallback onTogglePin,
    required VoidCallback onToggleMute,
    required VoidCallback onDelete,
  }) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'InboxModal',
      barrierColor: Colors.black.withValues(alpha: 0.55),
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (ctx, animation, secondaryAnimation) {
        return _InboxModalContent(
          conversation: conversation,
          onTogglePin: onTogglePin,
          onToggleMute: onToggleMute,
          onDelete: onDelete,
        );
      },
      transitionBuilder: (ctx, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutBack,
        );
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.85, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );
  }
}

// Message Long-Press Menu Overlay

class _MessageMenuOverlay extends StatelessWidget {
  const _MessageMenuOverlay({
    required this.isMine,
    required this.message,
    required this.tapPosition,
    required this.onReply,
    required this.onCopy,
    this.onUnsend,
    required this.onDeleteForMe,
    this.onReact,
  });

  final bool isMine;
  final Message message;
  final Offset tapPosition;
  final VoidCallback onReply;
  final VoidCallback onCopy;
  final VoidCallback? onUnsend;
  final VoidCallback onDeleteForMe;
  final ValueChanged<String>? onReact;

  static const _emojis = ['❤️', '😂', '😮', '😢', '😡', '👍'];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor =
        isDark ? const Color(0xFF26272B) : const Color(0xFFFFFFFF);
    final reactionPillColor =
        isDark ? const Color(0xFF26272B) : const Color(0xFFF6F6F9);
    final screen = MediaQuery.sizeOf(context);

    final showUnsend = isMine && onUnsend != null;
    const reactionBarWidth = 310.0;
    const menuWidth = 240.0;
    const reactionBarHeight = 76.0;
    final actionCount = showUnsend ? 4 : 3;
    final menuHeight = actionCount * 48.0 + 52.0;
    final totalHeight = reactionBarHeight + 12.0 + menuHeight;

    // Positioning:
    // Incoming: anchored with avatar spacing on left (56.0)
    // Outgoing: anchored on right (16.0)
    final double? left = !isMine ? 56.0 : null;
    final double? right = isMine ? 16.0 : null;

    double top = tapPosition.dy - (reactionBarHeight + 24);
    if (top + totalHeight > screen.height - 24) {
      top = screen.height - totalHeight - 24;
    }
    top = top.clamp(44.0, screen.height - totalHeight - 16);

    final formattedTime =
        DateFormat('d MMM, h:mm a').format(message.createdAt.toLocal()).toUpperCase();

    return Stack(
      children: [
        Positioned(
          left: left,
          right: right,
          top: top,
          child: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: reactionBarWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment:
                    isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  Container(
                    width: reactionBarWidth,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: reactionPillColor,
                      borderRadius: BorderRadius.circular(34),
                      border: Border.all(
                        color: isDark
                            ? const Color(0xFF383838)
                            : const Color(0xFFE2E2E8),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: isDark ? 0.38 : 0.14,
                          ),
                          blurRadius: 20,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Tap and hold to super react',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.15,
                            color: isDark ? Colors.white60 : Colors.black45,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            ..._emojis.map((emoji) {
                              final isSelected = message.reaction == emoji;
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  Navigator.of(context).pop();
                                  onReact?.call(emoji);
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? (isDark
                                            ? Colors.white24
                                            : Colors.black12)
                                        : Colors.transparent,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Text(
                                    emoji,
                                    style: const TextStyle(fontSize: 24),
                                  ),
                                ),
                              );
                            }),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                Navigator.of(context).pop();
                                onReact?.call('❤️');
                              },
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.add_rounded,
                                  size: 24,
                                  color: isDark
                                      ? Colors.white70
                                      : Colors.black54,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 10),

                  // 2. Action Context Menu Box
                  Container(
                    width: menuWidth,
                    decoration: BoxDecoration(
                      color: surfaceColor,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: isDark
                            ? const Color(0xFF383838)
                            : const Color(0xFFE5E5EA),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: isDark ? 0.40 : 0.16,
                          ),
                          blurRadius: 26,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Timestamp header
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
                          child: Text(
                            formattedTime,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.35,
                              color: isDark
                                  ? Colors.white54
                                  : Colors.black45,
                            ),
                          ),
                        ),

                        // Action 1: Reply
                        _ActionRow(
                          label: 'Reply',
                          icon: Icons.reply_rounded,
                          onTap: () {
                            Navigator.of(context).pop();
                            onReply();
                          },
                          isDark: isDark,
                        ),

                        // Action 2: Copy
                        _ActionRow(
                          label: 'Copy',
                          icon: Icons.copy_rounded,
                          onTap: () {
                            Navigator.of(context).pop();
                            onCopy();
                          },
                          isDark: isDark,
                        ),

                        // Action 3: Unsend (only if isMine)
                        if (showUnsend)
                          _ActionRow(
                            label: 'Unsend',
                            icon: Icons.undo_rounded,
                            isDestructive: true,
                            onTap: () {
                              Navigator.of(context).pop();
                              onUnsend!();
                            },
                            isDark: isDark,
                          ),

                        // Action 4: Delete for me
                        _ActionRow(
                          label: 'Delete for me',
                          icon: Icons.delete_outline_rounded,
                          isDestructive: true,
                          onTap: () {
                            Navigator.of(context).pop();
                            onDeleteForMe();
                          },
                          isDark: isDark,
                        ),

                        const SizedBox(height: 6),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.isDark,
    this.isDestructive = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool isDark;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final color = isDestructive
        ? const Color(0xFFED4956)
        : (isDark ? Colors.white : Colors.black87);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          child: Row(
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight:
                        isDestructive ? FontWeight.w600 : FontWeight.w500,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 2. Inbox Item Long-Press Centered Modal
// ==========================================

class _InboxModalContent extends StatelessWidget {
  const _InboxModalContent({
    required this.conversation,
    required this.onTogglePin,
    required this.onToggleMute,
    required this.onDelete,
  });

  final Conversation conversation;
  final VoidCallback onTogglePin;
  final VoidCallback onToggleMute;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor =
        isDark ? const Color(0xFF26272B) : Colors.white;
    final dividerColor =
        isDark ? const Color(0xFF383838) : const Color(0xFFEFEFEF);
    final textColor = isDark ? Colors.white : Colors.black87;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 300,
          margin: const EdgeInsets.symmetric(horizontal: 32),
          decoration: BoxDecoration(
            color: surfaceColor,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: isDark
                  ? const Color(0xFF383838)
                  : const Color(0xFFE5E5EA),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.38),
                blurRadius: 28,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header with user avatar and username
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                child: Row(
                  children: [
                    UserAvatar(
                      username: conversation.otherUsername,
                      radius: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        conversation.otherUsername,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: dividerColor),

              // Option 1: Pin
              _ModalActionRow(
                label: conversation.isPinned ? 'Unpin' : 'Pin',
                icon: conversation.isPinned
                    ? Icons.push_pin_rounded
                    : Icons.push_pin_outlined,
                onTap: () {
                  Navigator.of(context).pop();
                  onTogglePin();
                },
                textColor: textColor,
              ),

              // Option 2: Mute messages
              _ModalActionRow(
                label: conversation.isMuted
                    ? 'Unmute messages'
                    : 'Mute messages',
                icon: conversation.isMuted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
                onTap: () {
                  Navigator.of(context).pop();
                  onToggleMute();
                },
                textColor: textColor,
              ),

              // Option 3: Delete
              _ModalActionRow(
                label: 'Delete',
                icon: Icons.delete_outline_rounded,
                isDestructive: true,
                onTap: () {
                  Navigator.of(context).pop();
                  onDelete();
                },
                textColor: const Color(0xFFED4956),
              ),

              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModalActionRow extends StatelessWidget {
  const _ModalActionRow({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.textColor,
    this.isDestructive = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final Color textColor;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 22, color: textColor),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight:
                        isDestructive ? FontWeight.w600 : FontWeight.w500,
                    color: textColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
