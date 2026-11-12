import 'package:flexiyo/widgets/conversation/avatar.dart';
import 'package:flutter/material.dart';

/// Centered drop-shaped jump-to-latest control shown while the reader is
/// scrolled away from the newest message.
class NewMessagesIndicator extends StatelessWidget {
  const NewMessagesIndicator({
    super.key,
    required this.username,
    required this.count,
    required this.onTap,
  });

  final String username;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '$count new messages. Jump to latest.',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: PhysicalShape(
          clipper: const NewMessagesDropClipper(),
          color: colors.surfaceContainerHigh,
          elevation: 6,
          shadowColor: Colors.black.withValues(alpha: 0.22),
          child: SizedBox(
            width: 64,
            height: 70,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  top: 4,
                  left: 12,
                  child: UserAvatar(username: username, radius: 20),
                ),
                if (count > 1)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Container(
                      constraints: const BoxConstraints(
                        minWidth: 19,
                        minHeight: 19,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: colors.primary,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: colors.surfaceContainerHigh,
                          width: 1.5,
                        ),
                      ),
                      child: Text(
                        count > 9 ? '9+' : '$count',
                        style: TextStyle(
                          color: colors.onPrimary,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Teardrop with the rounded end at the bottom, pointing at the composer.
class NewMessagesDropClipper extends CustomClipper<Path> {
  const NewMessagesDropClipper();

  @override
  Path getClip(Size size) {
    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..cubicTo(
        size.width * 0.16,
        0,
        0,
        size.height * 0.17,
        0,
        size.height * 0.43,
      )
      ..cubicTo(
        0,
        size.height * 0.68,
        size.width * 0.28,
        size.height * 0.89,
        size.width / 2,
        size.height,
      )
      ..cubicTo(
        size.width * 0.72,
        size.height * 0.89,
        size.width,
        size.height * 0.68,
        size.width,
        size.height * 0.43,
      )
      ..cubicTo(
        size.width,
        size.height * 0.17,
        size.width * 0.84,
        0,
        size.width / 2,
        0,
      )
      ..close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}
