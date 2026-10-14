import 'package:flexiyo/models/message.dart';
import 'package:flutter/material.dart';

/// Long-press context menu shown as a floating overlay near the tapped
/// message with a reaction bar on top and an action menu below.
class MessageContextMenu extends StatefulWidget {
  const MessageContextMenu({
    super.key,
    required this.isMine,
    required this.message,
    required this.myUserId,
    required this.isEditEligible,
    required this.onReply,
    required this.onCopy,
    this.onEdit,
    this.onUnsend,
    required this.onDeleteForMe,
    required this.onSelectMode,
    required this.tapPosition,
  });

  final bool isMine;
  final Message message;
  final String myUserId;
  final bool isEditEligible;
  final VoidCallback onReply;
  final VoidCallback onCopy;
  final VoidCallback? onEdit;
  final VoidCallback? onUnsend;
  final VoidCallback onDeleteForMe;
  final VoidCallback onSelectMode;

  /// The global position of the long-press, used to position the menu.
  final Offset tapPosition;

  /// Shows the context menu overlay.
  static Future<void> show(
    BuildContext context, {
    required bool isMine,
    required Message message,
    required String myUserId,
    required bool isEditEligible,
    required VoidCallback onReply,
    required VoidCallback onCopy,
    VoidCallback? onEdit,
    VoidCallback? onUnsend,
    required VoidCallback onDeleteForMe,
    required VoidCallback onSelectMode,
    required Offset tapPosition,
  }) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'MessageContextMenu',
      barrierColor: Colors.black.withValues(alpha: 0.55),
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (ctx, animation, secondaryAnimation) {
        return MessageContextMenu(
          isMine: isMine,
          message: message,
          myUserId: myUserId,
          isEditEligible: isEditEligible,
          onReply: onReply,
          onCopy: onCopy,
          onEdit: onEdit,
          onUnsend: onUnsend,
          onDeleteForMe: onDeleteForMe,
          onSelectMode: onSelectMode,
          tapPosition: tapPosition,
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
            scale: Tween<double>(begin: 0.88, end: 1.0).animate(curved),
            alignment: Alignment(
              (tapPosition.dx / (MediaQuery.sizeOf(ctx).width)) * 2 - 1,
              (tapPosition.dy / (MediaQuery.sizeOf(ctx).height)) * 2 - 1,
            ),
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<MessageContextMenu> createState() => _MessageContextMenuState();
}

class _MessageContextMenuState extends State<MessageContextMenu> {
  static const _menuWidth = 230.0;
  static const _itemHeight = 46.0;
  static const _cornerRadius = 16.0;

  static const _emojis = ['❤️', '😆', '😮', '😢', '😡', '👍', '➕'];

  List<_MenuAction> _buildActions() {
    final actions = <_MenuAction>[];

    actions.add(_MenuAction(
      label: 'Reply',
      icon: Icons.reply_rounded,
      onTap: widget.onReply,
    ));

    actions.add(_MenuAction(
      label: 'Copy',
      icon: Icons.copy_rounded,
      onTap: widget.onCopy,
    ));

    if (widget.isMine && widget.isEditEligible && widget.onEdit != null) {
      actions.add(_MenuAction(
        label: 'Edit',
        icon: Icons.edit_rounded,
        onTap: widget.onEdit!,
      ));
    }

    if (widget.isMine && widget.onUnsend != null) {
      actions.add(_MenuAction(
        label: 'Unsend',
        icon: Icons.delete_sweep_rounded,
        onTap: widget.onUnsend!,
        isDestructive: true,
      ));
    }

    actions.add(_MenuAction(
      label: 'Delete for you',
      icon: Icons.delete_outline_rounded,
      onTap: widget.onDeleteForMe,
      isDestructive: true,
    ));

    actions.add(_MenuAction(
      label: 'Select',
      icon: Icons.check_circle_outline_rounded,
      onTap: widget.onSelectMode,
    ));

    return actions;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = isDark ? const Color(0xFF262626) : Colors.white;
    final dividerColor =
        isDark ? const Color(0xFF383838) : const Color(0xFFEFEFEF);
    final actions = _buildActions();
    final screen = MediaQuery.sizeOf(context);

    // Calculate dimensions
    const reactionBarHeight = 52.0;
    final menuHeight = actions.length * _itemHeight + 4;
    final totalHeight = reactionBarHeight + 10 + menuHeight;

    double dx = widget.tapPosition.dx - _menuWidth / 2;
    double dy = widget.tapPosition.dy - (reactionBarHeight + 20);

    // Clamp horizontally
    dx = dx.clamp(16.0, screen.width - _menuWidth - 16);

    // If near bottom of screen, push up
    if (dy + totalHeight > screen.height - 30) {
      dy = screen.height - totalHeight - 30;
    }
    // If near top, push down
    dy = dy.clamp(50.0, screen.height - totalHeight - 20);

    return Stack(
      children: [
        Positioned(
          left: dx,
          top: dy,
          child: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: _menuWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Reaction bar
                  Container(
                    height: reactionBarHeight,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: surfaceColor,
                      borderRadius: BorderRadius.circular(30),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.28),
                          blurRadius: 18,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: _emojis.map((emoji) {
                        return GestureDetector(
                          onTap: () {
                            Navigator.of(context).pop();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Reacted $emoji'),
                                duration: const Duration(milliseconds: 900),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: Text(
                              emoji,
                              style: const TextStyle(fontSize: 22),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // Vertically Stacked Context Menu
                  Container(
                    decoration: BoxDecoration(
                      color: surfaceColor,
                      borderRadius: BorderRadius.circular(_cornerRadius),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(_cornerRadius),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: List.generate(actions.length * 2 - 1, (i) {
                          if (i.isOdd) {
                            return Divider(
                              height: 1,
                              thickness: 0.6,
                              color: dividerColor,
                            );
                          }
                          final action = actions[i ~/ 2];
                          return _MenuItemRow(
                            action: action,
                            itemHeight: _itemHeight,
                            onTap: () {
                              Navigator.of(context).pop();
                              action.onTap();
                            },
                          );
                        }),
                      ),
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

class _MenuAction {
  const _MenuAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.isDestructive = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool isDestructive;
}

class _MenuItemRow extends StatelessWidget {
  const _MenuItemRow({
    required this.action,
    required this.itemHeight,
    required this.onTap,
  });

  final _MenuAction action;
  final double itemHeight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = action.isDestructive
        ? const Color(0xFFED4956)
        : (isDark ? Colors.white : Colors.black87);

    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: itemHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(action.icon, size: 20, color: color),
              const SizedBox(width: 14),
              Text(
                action.label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w500,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
