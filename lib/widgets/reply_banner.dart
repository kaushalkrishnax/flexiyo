import 'package:flexiyo/models/message.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';

/// Displays a reply preview banner in the composer area when the user has
/// selected a message to reply to.
///
/// Shows a left-accent border, the original message text (1-line truncated),
/// and an X button to dismiss the reply.
class ReplyBanner extends StatelessWidget {
  const ReplyBanner({
    super.key,
    required this.message,
    required this.onDismiss,
  });

  final Message message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final previewText = message.decryptedText ?? '';

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        border: Border(
          top: BorderSide(color: cs.outlineVariant, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          // Left accent bar
          Container(
            width: 3,
            height: 36,
            decoration: BoxDecoration(
              color: cs.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          // Reply content
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Replying',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: cs.primary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  previewText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          // Dismiss button
          IconButton(
            onPressed: onDismiss,
            icon:
                const HugeIcon(icon: HugeIcons.strokeRoundedCancel01, size: 18),
            color: cs.onSurfaceVariant,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}
