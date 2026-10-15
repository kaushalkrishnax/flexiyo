import 'package:flexiyo/core/theme.dart';
import 'package:flutter/material.dart';

/// Renders the Flexiyo Music-inspired ambient background with glowing orbs.
class AuthBackground extends StatelessWidget {
  const AuthBackground({
    super.key,
    required this.child,
    this.showBackArrow = false,
    this.onBack,
  });

  final Widget child;
  final bool showBackArrow;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? AppTheme.bgDark : Colors.white;
    final backArrowColor = isDark ? Colors.white : Colors.black87;

    return Scaffold(
      backgroundColor: bgColor,
      body: Stack(
        children: [
          // Ambient Orb 1 (Top-Left: Blue/Purple)
          Positioned(
            top: -size.width * 0.35,
            left: -size.width * 0.35,
            child: IgnorePointer(
              child: Container(
                width: size.width * 0.9,
                height: size.width * 0.9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: isDark
                        ? [
                            const Color(0xFF1E40AF).withValues(alpha: 0.35),
                            const Color(0xFF7C3AED).withValues(alpha: 0.20),
                            Colors.transparent,
                          ]
                        : [
                            const Color(0xFF38BDF8).withValues(alpha: 0.14),
                            const Color(0xFFA855F7).withValues(alpha: 0.08),
                            Colors.transparent,
                          ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // Ambient Orb 2 (Bottom-Right: Magenta/Violet)
          Positioned(
            bottom: -size.width * 0.35,
            right: -size.width * 0.35,
            child: IgnorePointer(
              child: Container(
                width: size.width * 0.9,
                height: size.width * 0.9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: isDark
                        ? [
                            const Color(0xFFEC4899).withValues(alpha: 0.30),
                            const Color(0xFF8B5CF6).withValues(alpha: 0.15),
                            Colors.transparent,
                          ]
                        : [
                            const Color(0xFFF472B6).withValues(alpha: 0.14),
                            const Color(0xFFC084FC).withValues(alpha: 0.08),
                            Colors.transparent,
                          ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // Content
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showBackArrow)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        icon: Icon(Icons.arrow_back_rounded, color: backArrowColor, size: 24),
                        onPressed: onBack ?? () => Navigator.of(context).maybePop(),
                      ),
                    ),
                  ),
                Expanded(child: child),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Logo with ambient glow matching Instagram's centered brand mark
class FlexiyoLogo extends StatelessWidget {
  const FlexiyoLogo({super.key, this.size = 80});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Ambient glow behind logo
        Container(
          width: size * 1.35,
          height: size * 1.35,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                AppTheme.primary.withValues(alpha: 0.45),
                const Color(0xFF00B4D8).withValues(alpha: 0.20),
                Colors.transparent,
              ],
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
        ),
        // Logo image
        Image.asset(
          'assets/images/logo.png',
          width: size,
          height: size,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Color(0xFFD11D89), Color(0xFF00B4D8)],
              ),
            ),
            child: const Icon(Icons.lock_rounded, color: Colors.white, size: 40),
          ),
        ),
      ],
    );
  }
}
