import 'package:flexiyo/models/message.dart';
import 'package:flexiyo/widgets/avatar.dart';
import 'package:flexiyo/widgets/media_image_bubble.dart';
import 'package:flexiyo/widgets/media_voice_bubble.dart';
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

  BorderRadius _bubbleRadius() {
    const r = Radius.circular(24);
    const tail = Radius.circular(8);

    // Fiyonv chat styling: a lone message is a full pill; inside a run of
    // consecutive sends only the shared edges get the small tail radius.
    if (isFirst && isLast) {
      return BorderRadius.circular(24);
    }

    if (isMine) {
      return BorderRadius.only(
        topLeft: r,
        topRight: !isFirst ? tail : r,
        bottomLeft: r,
        bottomRight: !isLast ? tail : r,
      );
    } else {
      return BorderRadius.only(
        topLeft: !isFirst ? tail : r,
        topRight: r,
        bottomLeft: !isLast ? tail : r,
        bottomRight: r,
      );
    }
  }

  Widget _statusIcon(BuildContext context) {
    switch (message.status) {
      case MessageStatus.read:
        // Read is always expressed as the "Seen" label under the bubble —
        // no blue double-tick inside it.
        return const SizedBox.shrink();
      case MessageStatus.sending:
        return Icon(Icons.check,
            size: 12, color: Colors.white.withValues(alpha: 0.6));
      case MessageStatus.sent:
        return Icon(Icons.check,
            size: 12, color: Colors.white.withValues(alpha: 0.9));
      case MessageStatus.delivered:
        return Icon(Icons.done_all_rounded,
            size: 13, color: Colors.white.withValues(alpha: 0.9));
      case MessageStatus.failed:
        return const Icon(Icons.close, size: 12, color: Colors.redAccent);
    }
  }

  String _timestamp() => DateFormat('HH:mm').format(message.createdAt);

  Widget _replyQuote(BuildContext context, Message replied) {
    final cs = Theme.of(context).colorScheme;
    final quoteText = replied.isUnsent
        ? 'Message unsent'
        : (replied.mediaRef?.label ?? replied.decryptedText ?? '');
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.sizeOf(context).width;

    final verticalPad = isLast ? 14.0 : 6.0;

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

    final isMediaMessage = message.isMedia;
    final bodyText =
        message.decryptedText ?? 'Message unavailable on this device';

    final BoxDecoration bubbleDecoration;
    if (isMediaMessage) {
      // Media bubbles paint their own surface.
      bubbleDecoration = BoxDecoration(
        color: Colors.transparent,
        borderRadius: _bubbleRadius(),
      );
    } else if (isMine) {
      bubbleDecoration = BoxDecoration(
        color: const Color(0xFF1572DB),
        borderRadius: _bubbleRadius(),
      );
    } else {
      bubbleDecoration = BoxDecoration(
        color: isDark ? const Color(0xFF191D28) : const Color(0xFFF1F2F4),
        borderRadius: _bubbleRadius(),
      );
    }

    final textColor =
        isMine ? Colors.white : (isDark ? Colors.white : const Color(0xFF000B13));
    final metaColor = isMediaMessage
        ? Colors.grey[400]
        : isMine
            ? Colors.white.withValues(alpha: 0.7)
            : Colors.grey[500];

    final bubble = GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      onLongPressStart: onLongPressStart,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: screenWidth * (isMediaMessage ? 0.78 : 0.7),
            ),
            padding: isMediaMessage
                ? const EdgeInsets.all(0)
                : const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: bubbleDecoration,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (replyToMessage != null)
                  _replyQuote(context, replyToMessage!),

                if (isMediaMessage)
                  Padding(
                    padding: replyToMessage != null
                        ? const EdgeInsets.only(top: 6)
                        : EdgeInsets.zero,
                    child: message.isVoiceMedia
                        ? MediaVoiceBubble(message: message, isMine: isMine)
                        : MediaImageBubble(message: message, isMine: isMine),
                  )
                else
                  Text(
                    bodyText,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: textColor,
                        ),
                  ),

                const SizedBox(height: 4),

                Padding(
                  padding: EdgeInsets.only(
                    left: isMediaMessage ? 8 : 0,
                    right: isMediaMessage ? 6 : 0,
                    bottom: isMediaMessage ? 2 : 0,
                  ),
                  child: Row(
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
                ),
              ],
            ),
          ),

          if (isSelected)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.2),
                  borderRadius: _bubbleRadius(),
                ),
              ),
            ),

          if (message.reaction != null && message.reaction!.isNotEmpty)
            // Reaction pill hangs below-left of the bubble, aligning with the
            // start of the message content.
            Positioned(
              bottom: -9,
              left: 10,
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

    // Read receipt, rendered under my last bubble only.
    final showSeenLabel = isMine && isLast && message.status == MessageStatus.read;

    final rowChild = showSeenLabel
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              bubble,
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  'Seen',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Colors.grey[500],
                      ),
                ),
              ),
            ],
          )
        : bubble;

    return _BubbleRow(
      isMine: isMine,
      showAvatar: showAvatar,
      otherUsername: otherUsername,
      verticalPad: verticalPad,
      isSelected: isSelected,
      hasReaction: hasReaction,
      child: rowChild,
    );
  }
}

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
              const SizedBox(width: 34),
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
