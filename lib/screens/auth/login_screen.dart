import 'package:flexiyo/core/exceptions.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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

    if (cleaned.isNotEmpty && !cleaned.toLowerCase().contains('request failed')) {
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

  @override
  Widget build(BuildContext context) {
    final isAuthenticated =
        ref.watch(authProvider.select((s) => s.isAuthenticated));
    if (isAuthenticated) {
      WidgetsBinding.instance.addPostFrameCallback((_) => context.go('/chats'));
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? Colors.black : Colors.white;
    final inputBg = isDark ? const Color(0xFF1E1E1E) : const Color(0xFFFAFAFA);
    final borderColor =
        isDark ? const Color(0xFF333333) : const Color(0xFFDBDBDB);
    const brandBlue = Color(0xFF0095F6);

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Text(
                            'Flexiyo',
                            style: TextStyle(
                              fontFamily: 'serif',
                              fontSize: 44,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -1.0,
                              color: isDark ? Colors.white : Colors.black,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Center(
                          child: Text(
                            'Welcome back',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Center(
                          child: Text(
                            'Signal E2EE • Encrypted Messaging',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white54 : Colors.black45,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        const SizedBox(height: 36),

                        // Username input
                        Container(
                          decoration: BoxDecoration(
                            color: inputBg,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: borderColor, width: 0.8),
                          ),
                          child: TextField(
                            controller: _usernameController,
                            textInputAction: TextInputAction.next,
                            style: TextStyle(
                              fontSize: 14,
                              color: isDark ? Colors.white : Colors.black,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Phone number, username, or email',
                              hintStyle: TextStyle(
                                fontSize: 13,
                                color: isDark ? Colors.white38 : Colors.black38,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),

                        // Password input with visibility toggle
                        Container(
                          decoration: BoxDecoration(
                            color: inputBg,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: borderColor, width: 0.8),
                          ),
                          child: TextField(
                            controller: _passwordController,
                            obscureText: _obscurePassword,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _submit(),
                            style: TextStyle(
                              fontSize: 14,
                              color: isDark ? Colors.white : Colors.black,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Password',
                              hintStyle: TextStyle(
                                fontSize: 13,
                                color: isDark ? Colors.white38 : Colors.black38,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  size: 20,
                                  color:
                                      isDark ? Colors.white54 : Colors.black45,
                                ),
                                onPressed: () {
                                  setState(() =>
                                      _obscurePassword = !_obscurePassword);
                                },
                              ),
                            ),
                          ),
                        ),

                        if (_error != null) ...[
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF2C1517)
                                  : const Color(0xFFFDE8E8),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: const Color(0xFFED4956)
                                    .withValues(alpha: 0.4),
                                width: 0.8,
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
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: 20),

                        SizedBox(
                          height: 44,
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 150),
                            opacity: _submitting ? 0.7 : 1.0,
                            child: ElevatedButton(
                              onPressed: _submitting ? null : _submit,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: brandBlue,
                                disabledBackgroundColor:
                                    brandBlue.withValues(alpha: 0.6),
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              child: _submitting
                                  ? const Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        SizedBox(
                                          width: 15,
                                          height: 15,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 1.8,
                                            color: Colors.white,
                                          ),
                                        ),
                                        SizedBox(width: 10),
                                        Text(
                                          'Logging in…',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ],
                                    )
                                  : const Text(
                                      'Log in',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Divider(height: 1, thickness: 0.5, color: borderColor),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    "Don't have an account? ",
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white54 : Colors.black54,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => context.go('/register'),
                    child: const Text(
                      'Sign up',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: brandBlue,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
