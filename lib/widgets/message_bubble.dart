import 'package:flexiyo/core/seen_status.dart';
import 'package:flexiyo/models/message.dart';
import 'package:flexiyo/widgets/avatar.dart';
import 'package:flexiyo/widgets/media_image_bubble.dart';
import 'package:flexiyo/widgets/media_voice_bubble.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';

/// Distance (logical px) a bubble slides when fully swiped for a reply.
const double kMessageSwipeMaxOffset = 96;

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
    this.swipeAnimation,
    this.swiping = false,
    this.timesReveal,
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

  /// Drives the per-message reply swipe: the bubble (not the avatar) slides
  /// with it. Null disables the offset entirely.
  final Animation<double>? swipeAnimation;

  /// Whether this bubble is the one currently under the reply swipe.
  final bool swiping;

  /// Drives the chat-wide timestamp peek: message rows slide left and their
  /// timestamps appear in a shared right-aligned lane. Null disables it.
  final Animation<double>? timesReveal;

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

  /// Caption above the quoted bubble, e.g. "You replied to aadha".
  String _replyLabel(Message replied) {
    // Was the replied-to message sent by the current user? If the quoted
    // message shares this bubble's sender it comes from the same party.
    final quotedIsMine =
        replied.senderId == message.senderId ? isMine : !isMine;

    if (isMine) {
      return quotedIsMine
          ? 'You replied to yourself'
          : 'You replied to $otherUsername';
    }
    return quotedIsMine
        ? '$otherUsername replied to you'
        : '$otherUsername replied to themselves';
  }

  /// Faded copy of the quoted message, sized like a regular bubble so the
  /// reply visibly answers the real thing.
  Widget _replyParentBubble(
    BuildContext context,
    Message replied, {
    required double maxWidth,
    required bool isDark,
  }) {
    final quoteText = replied.mediaRef?.label ?? replied.decryptedText ?? '';

    final quoteBg = isMine
        ? const Color(0xFF1572DB).withValues(alpha: 0.38)
        : (isDark
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0xFFEDEEF1));
    final quoteTextColor = isMine
        ? Colors.white.withValues(alpha: 0.82)
        : (isDark ? Colors.white : const Color(0xFF000B13))
            .withValues(alpha: 0.62);

    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: quoteBg,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Text(
        quoteText.isEmpty ? 'Message' : quoteText,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: quoteTextColor),
      ),
    );
  }

  /// Vertical pipe hugging the quoted bubble on the side the reply came from:
  /// right for my replies, left for the other person's.
  Widget _replyPipe(bool isDark) {
    return Container(
      key: const ValueKey('replyPipe'),
      width: 3,
      decoration: BoxDecoration(
        color: isDark ? Colors.white30 : Colors.black26,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.sizeOf(context).width;

    final verticalPad = isLast ? 14.0 : 6.0;

    final isMediaMessage = message.isMedia;
    final bodyText = message.decryptedText ??
        (!isMine && message.encryptedPayload != null
            ? 'Message could not be decrypted'
            : 'Message unavailable on this device');

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

    final textColor = isMine
        ? Colors.white
        : (isDark ? Colors.white : const Color(0xFF000B13));
    final metaColor = isMediaMessage
        ? Colors.grey[400]
        : isMine
            ? Colors.white.withValues(alpha: 0.7)
            : Colors.grey[500];

    // Per-message times and delivery ticks are intentionally not shown in the
    // bubble; times surface via the slide-to-reveal gesture instead.
    final showFailed =
        isMine && isLast && message.status == MessageStatus.failed;

    final maxBubbleWidth = screenWidth * (isMediaMessage ? 0.78 : 0.7);

    final bubbleCore = GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      onLongPressStart: onLongPressStart,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            constraints: BoxConstraints(maxWidth: maxBubbleWidth),
            padding: isMediaMessage
                ? const EdgeInsets.all(0)
                : const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: bubbleDecoration,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isMediaMessage)
                  message.isVoiceMedia
                      ? MediaVoiceBubble(message: message, isMine: isMine)
                      : MediaImageBubble(message: message, isMine: isMine)
                else
                  Text(
                    bodyText,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: textColor,
                        ),
                  ),
                if (message.isEdited || showFailed) ...[
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
                          Text(
                            'Edited',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: metaColor),
                          ),
                        if (message.isEdited && showFailed)
                          const SizedBox(width: 5),
                        if (showFailed)
                          const HugeIcon(
                            icon: HugeIcons.strokeRoundedCancel01,
                            size: 12,
                            color: Colors.redAccent,
                          ),
                      ],
                    ),
                  ),
                ],
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

    // A reply is drawn as a grey caption naming the reply, the faded parent
    // bubble with a pipe on the reply's side, then the answer itself.
    final bubble = replyToMessage == null
        ? bubbleCore
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment:
                isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxBubbleWidth),
                child: Text(
                  _replyLabel(replyToMessage!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.2,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey[500],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Padding(
                    padding: EdgeInsets.only(
                      right: isMine ? 10 : 0,
                      left: isMine ? 0 : 10,
                    ),
                    child: _replyParentBubble(
                      context,
                      replyToMessage!,
                      maxWidth: maxBubbleWidth,
                      isDark: isDark,
                    ),
                  ),
                  Positioned(
                    top: 3,
                    bottom: 3,
                    right: isMine ? 0 : null,
                    left: isMine ? null : 0,
                    child: _replyPipe(isDark),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              bubbleCore,
            ],
          );

    final hasReaction =
        message.reaction != null && message.reaction!.isNotEmpty;

    // Read receipt, rendered under my last bubble only.
    final showSeenLabel =
        isMine && isLast && message.status == MessageStatus.read;

    final rowChild = showSeenLabel
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              bubble,
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  seenStatusLabel(message.readAt),
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
      swipeAnimation: swipeAnimation,
      swiping: swiping,
      timesReveal: timesReveal,
      timesLabel: _compactTime(message.createdAt),
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
    this.swipeAnimation,
    this.swiping = false,
    this.timesReveal,
    this.timesLabel,
    required this.child,
  });

  final bool isMine;
  final bool showAvatar;
  final String otherUsername;
  final double verticalPad;
  final bool isSelected;
  final bool hasReaction;
  final Animation<double>? swipeAnimation;
  final bool swiping;
  final Animation<double>? timesReveal;
  final String? timesLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // Only the bubble slides during a reply swipe: incoming avatars stay
    // anchored while the bubble travels away from them.
    Widget bubble = child;
    final swipe = swipeAnimation;
    if (swipe != null) {
      bubble = AnimatedBuilder(
        animation: swipe,
        child: child,
        builder: (context, inner) {
          final t = swiping ? swipe.value : 0.0;
          return Transform.translate(
            offset: Offset((isMine ? -1 : 1) * t * kMessageSwipeMaxOffset, 0),
            child: inner,
          );
        },
      );
    }

    final row = Row(
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
        bubble,
      ],
    );

    final reveal = timesReveal;
    final label = timesLabel;
    final rowContent = reveal == null || label == null
        ? row
        : AnimatedBuilder(
            animation: reveal,
            child: row,
            builder: (context, child) {
              final progress = reveal.value;
              return Stack(
                children: [
                  Transform.translate(
                    offset: Offset(-88 * progress, 0),
                    child: child,
                  ),
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 8,
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: progress,
                        child: Center(
                          child: Text(
                            label,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      color: isSelected ? cs.primaryContainer.withValues(alpha: 0.25) : null,
      padding: EdgeInsets.only(
        left: 8,
        right: isMine ? 4 : 8,
        top: verticalPad / 2,
        bottom: verticalPad / 2 + (hasReaction ? 8.0 : 0.0),
      ),
      child: rowContent,
    );
  }
}

/// Compact "5:33 pm" label shown in the right-side timestamp lane.
String _compactTime(DateTime when) {
  final local = when.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${local.hour < 12 ? 'am' : 'pm'}';
}
