import 'package:flutter/material.dart';

/// Pulsing skeleton blocks used instead of spinners everywhere a screen
/// depends on async data. Skeletons communicate layout (what will appear
/// where) instead of process (a spinner), so users see the final shape early.
class _Skeleton extends StatefulWidget {
  const _Skeleton({
    required this.child,
    this.borderRadius,
  });

  final Widget child;
  final BorderRadius? borderRadius;

  @override
  State<_Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<_Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fillColor = isDark ? const Color(0xFF2A2A2C) : const Color(0xFFE8E8EA);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Opacity(
        // Gently pulses so it reads as loading without any racing shimmer.
        opacity: 0.55 + 0.45 * _controller.value,
        child: Container(
          decoration: BoxDecoration(
            color: fillColor,
            borderRadius: widget.borderRadius ?? BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }
}

// Public API — sized skeletons

class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 14,
    this.borderRadius,
  });

  final double? width;
  final double height;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    return _Skeleton(
      borderRadius: borderRadius,
      child: SizedBox(
        width: width,
        height: height,
      ),
    );
  }
}

class SkeletonCircle extends StatelessWidget {
  const SkeletonCircle({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    return _Skeleton(
      borderRadius: BorderRadius.circular(size / 2),
      child: SizedBox(
        width: size,
        height: size,
      ),
    );
  }
}

/// Full chats-list skeleton: avatar circle + two text lines, repeated.
class ChatsSkeletonList extends StatelessWidget {
  const ChatsSkeletonList({super.key, this.itemCount = 8});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        itemCount,
        (index) => const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            children: [
              SkeletonCircle(size: 56),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBox(width: 140, height: 13),
                    SizedBox(height: 8),
                    SkeletonBox(height: 12),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Conversation thread skeleton: bubbles rising from the bottom, composer bar.
class ConversationSkeleton extends StatelessWidget {
  const ConversationSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    Widget bubble({required double width, required double height, bool mine = false}) {
      return Row(
        mainAxisAlignment:
            mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!mine) const SizedBox(width: 42),
          SkeletonBox(
            width: width,
            height: height,
            borderRadius: BorderRadius.circular(18),
          ),
          if (mine) const SizedBox(width: 8),
        ],
      );
    }

    return Column(
      children: [
        const Spacer(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              bubble(width: 150, height: 14),
              const SizedBox(height: 10),
              bubble(width: 220, height: 14),
              const SizedBox(height: 10),
              bubble(width: 110, height: 14, mine: true),
              const SizedBox(height: 10),
              bubble(width: 190, height: 14, mine: true),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
          child: Row(
            children: [
              const SkeletonCircle(size: 36),
              const SizedBox(width: 8),
              Expanded(
                child: SkeletonBox(
                  height: 44,
                  borderRadius: BorderRadius.circular(22),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
