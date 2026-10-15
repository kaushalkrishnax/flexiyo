import 'package:flexiyo/models/message.dart';
import 'package:flexiyo/widgets/avatar.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    required this.isFirst,
    required this.isLast,
    required this.showAvatar,
    required this.otherUsername,
    this.onLongPress,
    this.onLongPressStart,
    this.onTap,
    this.onReactionTap,
    required this.isSelected,
    this.replyToMessage,
  });

  /// The message to display.
  final Message message;

  /// Optional callback when reaction pill is tapped.
  final VoidCallback? onReactionTap;

  /// Whether this message was sent by the current user.
  final bool isMine;

  /// First message in a consecutive group from the same sender.
  final bool isFirst;

  /// Last message in a consecutive group from the same sender.
  final bool isLast;

  /// Show the sender's avatar (incoming only, on the last message in a group).
  final bool showAvatar;

  /// Username of the other participant (used for avatar + reply labels).
  final String otherUsername;

  final VoidCallback? onLongPress;
  final ValueChanged<LongPressStartDetails>? onLongPressStart;
  final VoidCallback? onTap;

  /// Whether this bubble is currently selected (multi-select mode).
  final bool isSelected;

  /// If non-null, a quote of the replied-to message is shown above the content.
  final Message? replyToMessage;

  // Geometry helpers

  BorderRadius _bubbleRadius() {
    const r = Radius.circular(20);
    const tail = Radius.circular(6);

    // Single standalone message: curved on all 4 corners!
    if (isFirst && isLast) {
      return BorderRadius.circular(20);
    }

    if (isMine) {
      return BorderRadius.only(
        topLeft: r,
        topRight: isFirst ? r : tail,
        bottomLeft: r,
        bottomRight: isLast ? tail : tail,
      );
    } else {
      return BorderRadius.only(
        topLeft: isFirst ? r : tail,
        topRight: r,
        bottomLeft: isLast ? tail : tail,
        bottomRight: r,
      );
    }
  }

  // Status icon (outgoing only, last in group)

  Widget _statusIcon(BuildContext context) {
    switch (message.status) {
      case MessageStatus.sending:
        return Icon(Icons.check,
            size: 12, color: Colors.white.withValues(alpha: 0.6));
      case MessageStatus.sent:
        return Icon(Icons.check,
            size: 12, color: Colors.white.withValues(alpha: 0.9));
      case MessageStatus.delivered:
        return Icon(Icons.done_all_rounded,
            size: 13, color: Colors.white.withValues(alpha: 0.9));
      case MessageStatus.read:
        return const Icon(Icons.done_all_rounded,
            size: 13, color: Colors.lightBlueAccent);
      case MessageStatus.failed:
        return const Icon(Icons.close, size: 12, color: Colors.redAccent);
    }
  }

  // Timestamp

  String _timestamp() => DateFormat('HH:mm').format(message.createdAt);

  // Reply quote

  Widget _replyQuote(BuildContext context, Message replied) {
    final cs = Theme.of(context).colorScheme;
    final quoteText =
        replied.isUnsent ? 'Message unsent' : (replied.decryptedText ?? '');
    final isQuoteUnsent = replied.isUnsent;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isMine
            ? Colors.black.withValues(alpha: 0.25)
            : cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(
            color: isMine ? Colors.white54 : cs.primary,
            width: 3,
          ),
        ),
      ),
      child: Text(
        quoteText,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: isMine
                  ? Colors.white.withValues(alpha: 0.75)
                  : cs.onSurfaceVariant,
              fontStyle: isQuoteUnsent ? FontStyle.italic : FontStyle.normal,
            ),
      ),
    );
  }

  // Unsent tombstone

  Widget _unsentBubble(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: _bubbleRadius(),
      ),
      child: Text(
        'Message unsent',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
      ),
    );
  }

  // Build

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.sizeOf(context).width;

    // Vertical spacing between bubbles (more breathing room between groups and bubbles)
    final verticalPad = isLast ? 14.0 : 6.0;

    // If unsent, render tombstone and bail early.
    if (message.isUnsent) {
      return _UnsentRow(
        isMine: isMine,
        showAvatar: showAvatar,
        otherUsername: otherUsername,
        verticalPad: verticalPad,
        isSelected: isSelected,
        onTap: onTap,
        onLongPress: onLongPress,
        child: _unsentBubble(context),
      );
    }

    final bodyText =
        message.decryptedText ?? 'Message unavailable on this device';

    // Bubble decoration
    final BoxDecoration bubbleDecoration;
    if (isMine) {
      bubbleDecoration = BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.purple[700]!, Colors.indigo[600]!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: _bubbleRadius(),
      );
    } else {
      bubbleDecoration = BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : cs.surfaceContainerHighest,
        borderRadius: _bubbleRadius(),
      );
    }

    final textColor = isMine ? Colors.white : cs.onSurface;
    final metaColor =
        isMine ? Colors.white.withValues(alpha: 0.65) : cs.onSurfaceVariant;

    final bubble = GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      onLongPressStart: onLongPressStart,
      child: Stack(
        children: [
          Container(
            constraints: BoxConstraints(maxWidth: screenWidth * 0.72),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: bubbleDecoration,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Reply quote (if any)
                if (replyToMessage != null)
                  _replyQuote(context, replyToMessage!),

                // Body
                Text(
                  bodyText,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: textColor,
                      ),
                ),

                const SizedBox(height: 4),

                // Timestamp + edited + status row
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (message.isEdited)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text(
                          'Edited',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: metaColor),
                        ),
                      ),
                    Text(
                      _timestamp(),
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: metaColor),
                    ),
                    if (isMine && isLast) ...[
                      const SizedBox(width: 4),
                      _statusIcon(context),
                    ],
                  ],
                ),
              ],
            ),
          ),

          // Selection highlight overlay
          if (isSelected)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.2),
                  borderRadius: _bubbleRadius(),
                ),
              ),
            ),

          // Emoji Reaction Pill Badge
          if (message.reaction != null && message.reaction!.isNotEmpty)
            Positioned(
              bottom: -9,
              right: isMine ? 10 : null,
              left: !isMine ? 10 : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF262626) : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFF383838)
                        : const Color(0xFFE5E5EA),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:
                          Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Text(
                  message.reaction!,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    final hasReaction =
        message.reaction != null && message.reaction!.isNotEmpty;

    return _BubbleRow(
      isMine: isMine,
      showAvatar: showAvatar,
      otherUsername: otherUsername,
      verticalPad: verticalPad,
      isSelected: isSelected,
      hasReaction: hasReaction,
      child: bubble,
    );
  }
}

// Private layout helpers

/// Lays out a bubble in a row, optionally with avatar on the left for
/// incoming messages.
class _BubbleRow extends StatelessWidget {
  const _BubbleRow({
    required this.isMine,
    required this.showAvatar,
    required this.otherUsername,
    required this.verticalPad,
    required this.isSelected,
    this.hasReaction = false,
    required this.child,
  });

  final bool isMine;
  final bool showAvatar;
  final String otherUsername;
  final double verticalPad;
  final bool isSelected;
  final bool hasReaction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      color: isSelected
          ? cs.primaryContainer.withValues(alpha: 0.25)
          : Colors.transparent,
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: verticalPad / 2,
        bottom: verticalPad / 2 + (hasReaction ? 8.0 : 0.0),
      ),
      child: Row(
        mainAxisAlignment:
            isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMine) ...[
            if (showAvatar)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: UserAvatar(username: otherUsername, radius: 14),
              )
            else
              const SizedBox(width: 34), // placeholder to keep alignment
          ],
          child,
        ],
      ),
    );
  }
}

/// Variant of [_BubbleRow] used for unsent (tombstone) bubbles.
class _UnsentRow extends StatelessWidget {
  const _UnsentRow({
    required this.isMine,
    required this.showAvatar,
    required this.otherUsername,
    required this.verticalPad,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
    required this.child,
  });

  final bool isMine;
  final bool showAvatar;
  final String otherUsername;
  final double verticalPad;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: _BubbleRow(
        isMine: isMine,
        showAvatar: showAvatar,
        otherUsername: otherUsername,
        verticalPad: verticalPad,
        isSelected: isSelected,
        child: child,
      ),
    );
  }
}
