import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Animated three-dot typing indicator, shown when the remote peer is typing.
///
/// The three dots animate in a sequential wave (each dot rises slightly after
/// the previous one). Wrap visibility in an [AnimatedSwitcher] at the call
/// site if a fade-in/out transition is desired.
class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  static const _dotCount = 3;
  static const _cycleDuration = Duration(milliseconds: 900);
  static const _dotSize = 7.0;
  static const _bounceHeight = 5.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _cycleDuration)
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Returns a [0, 1] bounce value for the dot at [index] given animation [t].
  double _dotBounce(int index, double t) {
    // Each dot is phase-shifted by 1/dotCount of the full cycle.
    final shifted = (t - index / _dotCount + 1) % 1.0;
    // Only the first half of the shifted cycle produces the upward arch.
    if (shifted > 0.5) return 0.0;
    return math.sin(shifted * 2 * math.pi).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bubbleBg =
        isDark ? const Color(0xFF2C2C2E) : cs.surfaceContainerHighest;

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 12, bottom: 6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bubbleBg,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
              bottomRight: Radius.circular(20),
              bottomLeft: Radius.circular(4),
            ),
          ),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(_dotCount, (i) {
                  final bounce = _dotBounce(i, _controller.value);
                  return Padding(
                    padding: EdgeInsets.only(
                      right: i < _dotCount - 1 ? 4 : 0,
                      bottom: bounce * _bounceHeight,
                    ),
                    child: Container(
                      width: _dotSize,
                      height: _dotSize,
                      decoration: BoxDecoration(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                        shape: BoxShape.circle,
                      ),
                    ),
                  );
                }),
              );
            },
          ),
        ),
      ),
    );
  }
}
