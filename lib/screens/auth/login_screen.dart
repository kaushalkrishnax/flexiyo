import 'package:flexiyo/core/exceptions.dart';
import 'package:flexiyo/core/theme.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/services/google_auth_service.dart';
import 'package:flexiyo/widgets/auth_background.dart';
import 'package:flexiyo/widgets/auth_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hugeicons/hugeicons.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  String? _error;
  bool _submitting = false;
  bool _googleSubmitting = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _formatError(Object error) {
    if (error is FlexiyoException) {
      final msg = error.message.trim();
      final lower = msg.toLowerCase();

      if (error is NetworkException ||
          lower.contains('failed host lookup') ||
          lower.contains('nodename nor servname') ||
          lower.contains('socketexception') ||
          lower.contains('connection refused') ||
          lower.contains('connection error')) {
        if (lower.contains('timeout')) {
          return 'Connection timed out. Please try again.';
        }
        return 'Cannot connect to server. Please check your internet connection.';
      }

      if (msg.isNotEmpty &&
          msg != 'Request failed' &&
          msg != 'Unauthorized' &&
          msg != 'Not found' &&
          msg != 'Network error') {
        return msg;
      }
      if (error is UnauthorizedException || lower.contains('unauthorized')) {
        return 'Invalid credentials';
      }
      if (error is NotFoundException || lower.contains('not found')) {
        return 'Account not found. Please check your username.';
      }
    }

    final strLower = error.toString().toLowerCase();
    if (strLower.contains('failed host lookup') ||
        strLower.contains('nodename nor servname') ||
        strLower.contains('socketexception')) {
      return 'Cannot connect to server. Please check your internet connection.';
    }

    final raw = error.toString();
    final cleaned = raw
        .replaceAll(RegExp(r'^Exception:\s*'), '')
        .replaceAll(RegExp(r'^FlexiyoException(\(\d*\))?:\s*'), '')
        .trim();

    if (cleaned.isNotEmpty &&
        !cleaned.toLowerCase().contains('request failed')) {
      return cleaned;
    }

    return 'Invalid credentials';
  }

  Future<void> _submit() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = 'Please enter both your username and password.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await ref.read(authProvider.notifier).login(
            username: username,
            password: password,
          );
      if (!mounted) return;
      context.go('/chats');
    } catch (error) {
      if (!mounted) return;
      _passwordController.clear();
      setState(() => _error = _formatError(error));
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _handleGoogleSignIn() async {
    if (_googleSubmitting || _submitting) return;

    setState(() {
      _googleSubmitting = true;
      _error = null;
    });

    try {
      final googleResult = await GoogleAuthService.instance.signIn();
      if (googleResult == null) {
        // User cancelled sign in
        if (mounted) setState(() => _googleSubmitting = false);
        return;
      }

      await ref.read(authProvider.notifier).loginWithGoogle(
            idToken: googleResult.idToken,
            email: googleResult.email,
            googleId: googleResult.googleId,
            name: googleResult.displayName,
          );

      if (!mounted) return;
      context.go('/chats');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _formatError(e));
    } finally {
      if (mounted) {
        setState(() => _googleSubmitting = false);
      }
    }
  }

  void _showForgotPasswordDialog() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isDark ? AppTheme.bgDarkElevated : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Account Recovery',
          style: TextStyle(
            color: isDark ? Colors.white : const Color(0xFF18181B),
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'Flexiyo uses zero-knowledge encryption. If you previously linked an email address during signup, you can recover your account via your email.\n\nOtherwise, for security reasons, end-to-end encrypted accounts cannot be recovered without your password or device keys.',
          style: TextStyle(
            color: isDark ? Colors.white70 : Colors.black87,
            fontSize: 14,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK',
                style: TextStyle(
                    color: AppTheme.primary, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAuthenticated =
        ref.watch(authProvider.select((s) => s.isAuthenticated));
    if (isAuthenticated) {
      WidgetsBinding.instance.addPostFrameCallback((_) => context.go('/chats'));
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AuthBackground(
      child: Center(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 380,
                minHeight: constraints.maxHeight - 32,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Top Centered Logo
                      const Center(child: FlexiyoLogo(size: 84)),
                      const SizedBox(height: 20),

                      // Title & Subtitle
                      Center(
                        child: Text(
                          'Welcome back',
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -0.4,
                            color:
                                isDark ? Colors.white : const Color(0xFF18181B),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Center(
                        child: Text(
                          'End-to-End Encrypted Messaging',
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark ? Colors.white60 : Colors.black54,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),

                      // Username / Email input field
                      AuthTextField(
                        label: 'Username, email or mobile number',
                        controller: _usernameController,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 12),

                      // Password input field
                      AuthTextField(
                        label: 'Password',
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submit(),
                        trailing: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 20,
                            color: isDark ? Colors.white54 : Colors.black54,
                          ),
                          onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword),
                        ),
                      ),

                      // Error alert badge
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF2C1517)
                                : const Color(0xFFFFECEF),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: const Color(0xFFED4956)
                                  .withValues(alpha: isDark ? 0.5 : 0.3),
                              width: 1.0,
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.error_outline_rounded,
                                color: Color(0xFFED4956),
                                size: 18,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: const TextStyle(
                                    color: Color(0xFFED4956),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      const SizedBox(height: 18),

                      // Primary Log in Button
                      SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          onPressed: (_submitting || _googleSubmitting)
                              ? null
                              : _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primary,
                            disabledBackgroundColor:
                                AppTheme.primary.withValues(alpha: 0.5),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                            ),
                          ),
                          child: _submitting
                              ? const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.0,
                                        color: Colors.white,
                                      ),
                                    ),
                                    SizedBox(width: 10),
                                    Text(
                                      'Logging in…',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 15,
                                      ),
                                    ),
                                  ],
                                )
                              : const Text(
                                  'Log in',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                  ),
                                ),
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Forgot Password Link
                      Center(
                        child: TextButton(
                          onPressed: _showForgotPasswordDialog,
                          child: Text(
                            'Forgotten password?',
                            style: TextStyle(
                              color: isDark ? Colors.white70 : Colors.black87,
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Google Sign In Button
                      SizedBox(
                        height: 48,
                        child: OutlinedButton(
                          onPressed: (_submitting || _googleSubmitting)
                              ? null
                              : _handleGoogleSignIn,
                          style: OutlinedButton.styleFrom(
                            backgroundColor:
                                isDark ? const Color(0xFF18181B) : Colors.white,
                            side: BorderSide(
                              color: isDark
                                  ? AppTheme.borderDefault
                                  : const Color(0xFFE4E4E7),
                              width: 1.0,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                            ),
                          ),
                          child: _googleSubmitting
                              ? Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.0,
                                        color: isDark
                                            ? Colors.white
                                            : Colors.black87,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      'Connecting to Google…',
                                      style: TextStyle(
                                        color: isDark
                                            ? Colors.white
                                            : const Color(0xFF18181B),
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ],
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const HugeIcon(
                                      icon: HugeIcons.strokeRoundedGoogle,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      'Continue with Google',
                                      style: TextStyle(
                                        color: isDark
                                            ? Colors.white
                                            : const Color(0xFF18181B),
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),

                      const SizedBox(height: 18),

                      // Bottom Outlined "Create new account" Button
                      SizedBox(
                        height: 46,
                        child: OutlinedButton(
                          onPressed: () => context.go('/register'),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(
                                color: AppTheme.primary, width: 1.2),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(23),
                            ),
                          ),
                          child: const Text(
                            'Create new account',
                            style: TextStyle(
                              color: AppTheme.primary,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // Flexiyo text on bottom
                      Center(
                        child: Text(
                          'Flexiyo',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -0.2,
                            color: isDark ? Colors.white54 : Colors.black45,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
