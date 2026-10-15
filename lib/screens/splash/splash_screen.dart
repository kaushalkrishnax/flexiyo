import 'package:flexiyo/core/theme.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/widgets/auth_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  void _checkAuth() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = ref.read(authProvider);
      if (auth.isInitialized) {
        _navigate(auth.isAuthenticated);
      }
    });
  }

  void _navigate(bool isAuthenticated) {
    if (!mounted) return;
    if (isAuthenticated) {
      context.go('/chats');
    } else {
      context.go('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.isInitialized) {
        _navigate(next.isAuthenticated);
      }
    });

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? AppTheme.bgDark : Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const FlexiyoLogo(size: 96),
            const SizedBox(height: 24),
            Text(
              'Flexiyo',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : const Color(0xFF18181B),
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Private. Encrypted. Yours.',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white54 : Colors.black54,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

