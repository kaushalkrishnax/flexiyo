import 'package:flexiyo/core/constants.dart';
import 'package:flexiyo/models/conversation.dart';
import 'package:flexiyo/models/message.dart';
import 'package:flexiyo/widgets/conversation/avatar.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
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
    required VoidCallback onToggleRestrict,
    required VoidCallback onToggleBlock,
    required VoidCallback onSetDisappearingTimer,
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
          onToggleRestrict: onToggleRestrict,
          onToggleBlock: onToggleBlock,
          onSetDisappearingTimer: onSetDisappearingTimer,
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

  static Future<int?> showDisappearingTimerPicker(
    BuildContext context, {
    required int currentSeconds,
  }) {
    return showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Disappearing messages'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Messages disappear for both people after they are read.',
              style: Theme.of(dialogContext).textTheme.bodyMedium,
            ),
            const SizedBox(height: 10),
            RadioGroup<int>(
              groupValue: currentSeconds,
              onChanged: (value) => Navigator.of(dialogContext).pop(value),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: AppConstants.disappearingTimerOptions
                    .map(
                      (seconds) => RadioListTile<int>(
                        value: seconds,
                        title: Text(_timerLabel(seconds)),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  static String _timerLabel(int seconds) {
    return switch (seconds) {
      0 => 'None',
      3600 => 'After 1 hour',
      21600 => 'After 6 hours',
      86400 => 'After 24 hours',
      604800 => 'After 7 days',
      _ => 'After reading',
    };
  }
}

Future<void> showRequestsListsMenu(
  BuildContext context, {
  required VoidCallback onRestricted,
  required VoidCallback onBlocked,
  Rect? position,
}) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  final anchor = position ??
      Rect.fromLTWH(
        MediaQuery.of(context).size.width - 200,
        80,
        0,
        0,
      );
  final relative = RelativeRect.fromRect(anchor, Offset.zero & overlay!.size);
  return showMenu<void>(
    context: context,
    position: relative,
    items: [
      PopupMenuItem<void>(
        onTap: onRestricted,
        child: const Row(
          children: [
            HugeIcon(icon: HugeIcons.strokeRoundedBlocked, size: 22),
            SizedBox(width: 14),
            Text('Restricted'),
          ],
        ),
      ),
      PopupMenuItem<void>(
        onTap: onBlocked,
        child: const Row(
          children: [
            HugeIcon(icon: HugeIcons.strokeRoundedUserRemove01, size: 22),
            SizedBox(width: 14),
            Text('Blocked'),
          ],
        ),
      ),
    ],
  );
}

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
    const reactionBarWidth = 290.0;
    const menuWidth = 216.0;
    const reactionBarHeight = 56.0;
    final actionCount = showUnsend ? 4 : 3;
    final menuHeight = actionCount * 48.0 + 52.0;
    final totalHeight = reactionBarHeight + 12.0 + menuHeight;

    final double? left = !isMine ? 56.0 : null;
    final double? right = isMine ? 16.0 : null;

    double top = tapPosition.dy - (reactionBarHeight + 24);
    if (top + totalHeight > screen.height - 24) {
      top = screen.height - totalHeight - 24;
    }
    top = top.clamp(44.0, screen.height - totalHeight - 16);

    final formattedTime = DateFormat('d MMM, h:mm a')
        .format(message.createdAt.toLocal())
        .toUpperCase();

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
                      horizontal: 14,
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
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
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
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
                          child: Text(
                            formattedTime,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.35,
                              color: isDark ? Colors.white54 : Colors.black45,
                            ),
                          ),
                        ),
                        _ActionRow(
                          label: 'Reply',
                          icon: HugeIcons.strokeRoundedReply,
                          onTap: () {
                            Navigator.of(context).pop();
                            onReply();
                          },
                          isDark: isDark,
                        ),
                        _ActionRow(
                          label: 'Copy',
                          icon: HugeIcons.strokeRoundedCopy01,
                          onTap: () {
                            Navigator.of(context).pop();
                            onCopy();
                          },
                          isDark: isDark,
                        ),
                        if (showUnsend)
                          _ActionRow(
                            label: 'Unsend',
                            icon: HugeIcons.strokeRoundedUndo,
                            isDestructive: true,
                            onTap: () {
                              Navigator.of(context).pop();
                              onUnsend!();
                            },
                            isDark: isDark,
                          ),
                        _ActionRow(
                          label: 'Delete for me',
                          icon: HugeIcons.strokeRoundedDelete02,
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
  final List<List<dynamic>> icon;
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
              HugeIcon(icon: icon, size: 22, color: color),
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

class _InboxModalContent extends StatelessWidget {
  const _InboxModalContent({
    required this.conversation,
    required this.onTogglePin,
    required this.onToggleMute,
    required this.onToggleRestrict,
    required this.onToggleBlock,
    required this.onSetDisappearingTimer,
    required this.onDelete,
  });

  final Conversation conversation;
  final VoidCallback onTogglePin;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleRestrict;
  final VoidCallback onToggleBlock;
  final VoidCallback onSetDisappearingTimer;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = isDark ? const Color(0xFF26272B) : Colors.white;
    final dividerColor =
        isDark ? const Color(0xFF383838) : const Color(0xFFEFEFEF);
    final textColor = isDark ? Colors.white : Colors.black87;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 280,
          margin: const EdgeInsets.symmetric(horizontal: 24),
          decoration: BoxDecoration(
            color: surfaceColor,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: isDark ? const Color(0xFF383838) : const Color(0xFFE5E5EA),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
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
              _ModalActionRow(
                label: conversation.isPinned ? 'Unpin' : 'Pin',
                icon: HugeIcons.strokeRoundedPin,
                onTap: () {
                  Navigator.of(context).pop();
                  onTogglePin();
                },
                textColor: textColor,
              ),
              _ModalActionRow(
                label:
                    conversation.isMuted ? 'Unmute messages' : 'Mute messages',
                icon: conversation.isMuted
                    ? HugeIcons.strokeRoundedBell
                    : HugeIcons.strokeRoundedBellOff,
                onTap: () {
                  Navigator.of(context).pop();
                  onToggleMute();
                },
                textColor: textColor,
              ),
              _ModalActionRow(
                label: 'Disappearing messages',
                icon: HugeIcons.strokeRoundedTimer01,
                onTap: () {
                  Navigator.of(context).pop();
                  onSetDisappearingTimer();
                },
                textColor: textColor,
              ),
              _ModalActionRow(
                label: 'Restrict',
                icon: HugeIcons.strokeRoundedBlocked,
                onTap: () {
                  Navigator.of(context).pop();
                  onToggleRestrict();
                },
                textColor: textColor,
              ),
              _ModalActionRow(
                label: 'Block',
                icon: HugeIcons.strokeRoundedUserRemove01,
                onTap: () {
                  Navigator.of(context).pop();
                  onToggleBlock();
                },
                textColor: textColor,
              ),
              _ModalActionRow(
                label: 'Delete',
                icon: HugeIcons.strokeRoundedDelete02,
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
  final List<List<dynamic>> icon;
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
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(
            children: [
              HugeIcon(icon: icon, size: 21, color: textColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 16,
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
