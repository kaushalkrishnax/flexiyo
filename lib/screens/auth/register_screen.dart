import 'dart:async';
import 'package:flexiyo/core/exceptions.dart';
import 'package:flexiyo/core/theme.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/services/google_auth_service.dart';
import 'package:flexiyo/widgets/auth_background.dart';
import 'package:flexiyo/widgets/auth_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hugeicons/hugeicons.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  int _step = 1;

  // Step 1: Username
  final _usernameController = TextEditingController();
  Timer? _debounceTimer;
  bool _isCheckingUsername = false;
  bool _isUsernameAvailable = false;
  String? _usernameError;
  bool _googleSubmitting = false;

  // Step 2: Password
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _rememberLoginInfo = true;
  bool _isCreatingAccount = false;
  String? _passwordError;

  // Step 3: Optional Email
  final _emailController = TextEditingController();
  final _verificationCodeController = TextEditingController();
  bool _isSavingEmail = false;
  bool _isVerifyingEmail = false;
  bool _emailCodeSent = false;
  String? _emailError;
  String? _emailSuccess;

  @override
  void initState() {
    super.initState();
    _usernameController.addListener(_onUsernameChanged);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _usernameController.removeListener(_onUsernameChanged);
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _emailController.dispose();
    _verificationCodeController.dispose();
    super.dispose();
  }

  // Step 1: Live Username Validation & Availability Check

  void _onUsernameChanged() {
    _debounceTimer?.cancel();
    final raw = _usernameController.text.trim();

    if (raw.isEmpty) {
      setState(() {
        _isCheckingUsername = false;
        _isUsernameAvailable = false;
        _usernameError = null;
      });
      return;
    }

    if (raw.length < 3) {
      setState(() {
        _isCheckingUsername = false;
        _isUsernameAvailable = false;
        _usernameError = 'Username must be at least 3 characters.';
      });
      return;
    }

    if (raw.length > 30) {
      setState(() {
        _isCheckingUsername = false;
        _isUsernameAvailable = false;
        _usernameError = 'Username must be at most 30 characters.';
      });
      return;
    }

    if (!RegExp(r'^[a-zA-Z0-9_.]+$').hasMatch(raw)) {
      setState(() {
        _isCheckingUsername = false;
        _isUsernameAvailable = false;
        _usernameError =
            'Username may only contain letters, numbers, underscores, and dots.';
      });
      return;
    }

    setState(() {
      _isCheckingUsername = true;
      _usernameError = null;
    });

    _debounceTimer = Timer(const Duration(milliseconds: 350), () async {
      await _checkUsernameAvailability(raw);
    });
  }

  Future<void> _checkUsernameAvailability(String username) async {
    try {
      final apiService = ref.read(apiServiceProvider);
      final result = await apiService.checkUsernameAvailability(username);

      if (!mounted || _usernameController.text.trim() != username) return;

      final isAvailable = result['available'] == true;
      final message = result['message'] as String?;

      setState(() {
        _isCheckingUsername = false;
        _isUsernameAvailable = isAvailable;
        if (!isAvailable) {
          _usernameError =
              message ?? 'The username $username is not available.';
        } else {
          _usernameError = null;
        }
      });
    } catch (e) {
      if (!mounted || _usernameController.text.trim() != username) return;
      setState(() {
        _isCheckingUsername = false;
        _isUsernameAvailable = false;
        _usernameError = _formatError(e);
      });
    }
  }

  Future<void> _handleStep1Next() async {
    final username = _usernameController.text.trim();
    if (username.isEmpty) {
      setState(() => _usernameError = 'Please enter a username.');
      return;
    }
    if (_isCheckingUsername) return;

    if (!_isUsernameAvailable) {
      setState(() => _isCheckingUsername = true);
      await _checkUsernameAvailability(username);
      if (!_isUsernameAvailable) return;
    }

    setState(() {
      _step = 2;
      _passwordError = null;
    });
  }

  Future<void> _handleGoogleSignUp() async {
    if (_googleSubmitting) return;

    setState(() {
      _googleSubmitting = true;
      _usernameError = null;
    });

    try {
      final googleResult = await GoogleAuthService.instance.signIn();
      if (googleResult == null) {
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
      ref.read(authProvider.notifier).completeOnboarding();
      context.go('/chats');
    } catch (e) {
      if (!mounted) return;
      setState(() => _usernameError = _formatError(e));
    } finally {
      if (mounted) {
        setState(() => _googleSubmitting = false);
      }
    }
  }

  // Step 2: Password Creation & Registration

  Future<void> _handleCreateAccount() async {
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (password.length < 8) {
      setState(() =>
          _passwordError = 'Password must be at least 8 characters long.');
      return;
    }

    if (password != confirmPassword) {
      setState(() => _passwordError = 'Passwords do not match.');
      return;
    }

    setState(() {
      _isCreatingAccount = true;
      _passwordError = null;
    });

    try {
      final username = _usernameController.text.trim();
      await ref.read(authProvider.notifier).register(
            username: username,
            password: password,
          );

      if (!mounted) return;
      // Account is created! Proceed to Step 3 (Optional Email)
      setState(() {
        _isCreatingAccount = false;
        _step = 3;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isCreatingAccount = false;
        _passwordError = _formatError(error);
      });
    }
  }

  void _showRememberInfoDialog() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isDark ? AppTheme.bgDarkElevated : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Remember Login Info',
          style: TextStyle(
            color: isDark ? Colors.white : const Color(0xFF18181B),
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'Your credentials and cryptographic encryption keys will be securely saved on this device so you can sign in automatically without entering your password every time.\n\nYou can sign out anytime in Settings.',
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

  // Step 3: Optional Email & Skip

  Future<void> _handleSaveEmail() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@') || !email.contains('.')) {
      setState(() => _emailError = 'Please enter a valid email address.');
      return;
    }

    setState(() {
      _isSavingEmail = true;
      _emailError = null;
      _emailSuccess = null;
    });

    try {
      await ref.read(authProvider.notifier).updateEmail(email);
      if (!mounted) return;
      setState(() {
        _isSavingEmail = false;
        _emailCodeSent = true;
        _emailSuccess = 'Verification code sent to $email';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSavingEmail = false;
        _emailError = _formatError(e);
      });
    }
  }

  Future<void> _handleVerifyEmailCode() async {
    final code = _verificationCodeController.text.trim();
    if (code.isEmpty || code.length < 6) {
      setState(() => _emailError = 'Please enter the verification code.');
      return;
    }

    setState(() {
      _isVerifyingEmail = true;
      _emailError = null;
    });

    try {
      await ref.read(authProvider.notifier).verifyEmail(code);
      if (!mounted) return;
      _finishOnboarding();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isVerifyingEmail = false;
        _emailError = _formatError(e);
      });
    }
  }

  void _finishOnboarding() {
    ref.read(authProvider.notifier).completeOnboarding();
    context.go('/chats');
  }

  // Navigation & Helpers

  void _handleBack() {
    if (_step == 1) {
      context.go('/login');
    } else if (_step == 2) {
      setState(() => _step = 1);
    } else if (_step == 3) {
      _finishOnboarding();
    }
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
        return 'Cannot connect to server. Please check your internet connection.';
      }

      if (msg.isNotEmpty &&
          msg != 'Request failed' &&
          msg != 'Registration failed' &&
          msg != 'Network error') {
        return msg;
      }
    }

    final strLower = error.toString().toLowerCase();
    if (strLower.contains('already exists') || strLower.contains('taken')) {
      return 'That username is already taken. Please choose another.';
    }
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
    return 'Action failed. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AuthBackground(
      showBackArrow: true,
      onBack: _handleBack,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: child,
              ),
              child: _buildCurrentStep(isDark),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentStep(bool isDark) {
    switch (_step) {
      case 1:
        return _buildStep1Username(isDark);
      case 2:
        return _buildStep2Password(isDark);
      case 3:
      default:
        return _buildStep3Email(isDark);
    }
  }

  // STEP 1: CREATE A USERNAME
  Widget _buildStep1Username(bool isDark) {
    final hasText = _usernameController.text.trim().isNotEmpty;
    final hasError = _usernameError != null;
    final isAvailable = _isUsernameAvailable && hasText && !hasError;

    return Column(
      key: const ValueKey(1),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Title
        Text(
          'Create a username',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            letterSpacing: -0.5,
            color: isDark ? Colors.white : const Color(0xFF18181B),
          ),
        ),
        const SizedBox(height: 10),

        // Subtitle
        Text(
          'To begin creating an account, add a username or use our suggestion. You can change this at any time.',
          style: TextStyle(
            fontSize: 14,
            height: 1.4,
            color: isDark ? Colors.white70 : Colors.black87,
          ),
        ),
        const SizedBox(height: 28),

        // Username input field with floating label
        AuthTextField(
          label: 'Username',
          controller: _usernameController,
          autofocus: true,
          hasError: hasError,
          isAvailable: isAvailable,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => _handleStep1Next(),
          trailing: _isCheckingUsername
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.0,
                    color: AppTheme.primary,
                  ),
                )
              : (hasError
                  ? const Icon(
                      Icons.error_outline_rounded,
                      color: Color(0xFFED4956),
                      size: 24,
                    )
                  : (isAvailable
                      ? const Icon(
                          Icons.check_circle_outline,
                          color: Color(0xFF22C55E),
                          size: 24,
                        )
                      : null)),
        ),

        // Error message below input box
        if (hasError) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              _usernameError!,
              style: const TextStyle(
                color: Color(0xFFED4956),
                fontSize: 13,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],

        const SizedBox(height: 24),

        // Next Button
        SizedBox(
          height: 48,
          child: ElevatedButton(
            onPressed:
                isAvailable && !_isCheckingUsername ? _handleStep1Next : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              disabledBackgroundColor: AppTheme.primary.withValues(alpha: 0.35),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            child: const Text(
              'Next',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ),
        ),

        const SizedBox(height: 28),

        // Divider: --- OR ---
        Row(
          children: [
            Expanded(
              child: Container(
                height: 1,
                color: (isDark ? Colors.white : Colors.black)
                    .withValues(alpha: 0.12),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text(
                'OR',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white38 : Colors.black38,
                  letterSpacing: 1.0,
                ),
              ),
            ),
            Expanded(
              child: Container(
                height: 1,
                color: (isDark ? Colors.white : Colors.black)
                    .withValues(alpha: 0.12),
              ),
            ),
          ],
        ),

        const SizedBox(height: 20),

        // Google Sign Up Button
        SizedBox(
          height: 48,
          child: OutlinedButton(
            onPressed: _googleSubmitting ? null : _handleGoogleSignUp,
            style: OutlinedButton.styleFrom(
              backgroundColor: isDark ? const Color(0xFF18181B) : Colors.white,
              side: BorderSide(
                color:
                    isDark ? AppTheme.borderDefault : const Color(0xFFE4E4E7),
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
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Connecting to Google…',
                        style: TextStyle(
                          color:
                              isDark ? Colors.white : const Color(0xFF18181B),
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
                        'Sign up with Google',
                        style: TextStyle(
                          color:
                              isDark ? Colors.white : const Color(0xFF18181B),
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
          ),
        ),

        const SizedBox(height: 28),

        // Already have an account? Log in
        Center(
          child: TextButton(
            onPressed: () => context.go('/login'),
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 14),
                children: [
                  TextSpan(
                    text: 'Already have an account? ',
                    style: TextStyle(
                        color: isDark ? Colors.white54 : Colors.black54),
                  ),
                  const TextSpan(
                    text: 'Log in',
                    style: TextStyle(
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // STEP 2: CREATE A PASSWORD
  Widget _buildStep2Password(bool isDark) {
    return Column(
      key: const ValueKey(2),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Title
        Text(
          'Create a password',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            letterSpacing: -0.5,
            color: isDark ? Colors.white : const Color(0xFF18181B),
          ),
        ),
        const SizedBox(height: 10),

        // Subtitle
        Text(
          'Create a password with at least 8 letters and numbers that others cannot guess. You will use it to log into your Flexiyo account.',
          style: TextStyle(
            fontSize: 14,
            height: 1.4,
            color: isDark ? Colors.white70 : Colors.black87,
          ),
        ),
        const SizedBox(height: 28),

        // Password Input Box
        AuthTextField(
          label: 'Password',
          controller: _passwordController,
          obscureText: _obscurePassword,
          autofocus: true,
          textInputAction: TextInputAction.next,
          trailing: IconButton(
            icon: Icon(
              _obscurePassword
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 20,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
            onPressed: () =>
                setState(() => _obscurePassword = !_obscurePassword),
          ),
        ),

        const SizedBox(height: 14),

        // Confirm Password Input Box
        AuthTextField(
          label: 'Confirm password',
          controller: _confirmPasswordController,
          obscureText: _obscureConfirmPassword,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _handleCreateAccount(),
          trailing: IconButton(
            icon: Icon(
              _obscureConfirmPassword
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 20,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
            onPressed: () => setState(
                () => _obscureConfirmPassword = !_obscureConfirmPassword),
          ),
        ),

        // Error message
        if (_passwordError != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF2C1517) : const Color(0xFFFFECEF),
              borderRadius: BorderRadius.circular(12),
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
                    _passwordError!,
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

        const SizedBox(height: 16),

        // "Remember login info" checkbox (matches screenshot)
        Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: _rememberLoginInfo,
                activeColor: AppTheme.primary,
                checkColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
                onChanged: (val) =>
                    setState(() => _rememberLoginInfo = val ?? true),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GestureDetector(
                onTap: _showRememberInfoDialog,
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                    children: const [
                      TextSpan(text: 'Remember login info. '),
                      TextSpan(
                        text: 'Learn more',
                        style: TextStyle(
                          color: AppTheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 28),

        // "Create Account" Button (Curved pill button matching "Create new account")
        SizedBox(
          height: 48,
          child: ElevatedButton(
            onPressed: _isCreatingAccount ? null : _handleCreateAccount,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              disabledBackgroundColor: AppTheme.primary.withValues(alpha: 0.5),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            child: _isCreatingAccount
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
                        'Creating account…',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  )
                : const Text(
                    'Create Account',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  // STEP 3: OPTIONAL EMAIL STEP
  Widget _buildStep3Email(bool isDark) {
    return Column(
      key: const ValueKey(3),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Title
        Text(
          'Add your email',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            letterSpacing: -0.5,
            color: isDark ? Colors.white : const Color(0xFF18181B),
          ),
        ),
        const SizedBox(height: 10),

        // Subtitle
        Text(
          'An email protects your account and allows you to recover it if you ever forget your password. This step is optional and can be skipped.',
          style: TextStyle(
            fontSize: 14,
            height: 1.4,
            color: isDark ? Colors.white70 : Colors.black87,
          ),
        ),
        const SizedBox(height: 22),

        // Benefits Card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.bgDarkSurface : const Color(0xFFF4F4F5),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? AppTheme.borderDefault : const Color(0xFFE4E4E7),
              width: 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Why add an email?',
                style: TextStyle(
                  color: isDark ? Colors.white : const Color(0xFF18181B),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 14),
              _buildBenefitRow(
                icon: Icons.vpn_key_rounded,
                iconColor: const Color(0xFF38BDF8),
                title: 'Account Recovery',
                desc:
                    'Flexiyo is end-to-end encrypted. An email is the only way to recover your account if you forget your password.',
                isDark: isDark,
              ),
              const SizedBox(height: 12),
              _buildBenefitRow(
                icon: Icons.shield_rounded,
                iconColor: const Color(0xFF34D399),
                title: 'Security Alerts',
                desc:
                    'Receive immediate notifications if a new or unrecognized device signs into your account.',
                isDark: isDark,
              ),
              const SizedBox(height: 12),
              _buildBenefitRow(
                icon: Icons.mark_email_read_rounded,
                iconColor: const Color(0xFFF472B6),
                title: 'Zero Spam Guarantee',
                desc:
                    'No marketing, no tracking. Your email address is strictly used for critical security alerts.',
                isDark: isDark,
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),

        if (!_emailCodeSent) ...[
          // Email input box
          AuthTextField(
            label: 'Email address',
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _handleSaveEmail(),
          ),

          if (_emailError != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                _emailError!,
                style: const TextStyle(
                  color: Color(0xFFED4956),
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ],

          const SizedBox(height: 20),

          // Primary: Add Email button (Curved pill)
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _isSavingEmail ? null : _handleSaveEmail,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                disabledBackgroundColor:
                    AppTheme.primary.withValues(alpha: 0.5),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
              child: _isSavingEmail
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
                          'Sending code…',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    )
                  : const Text(
                      'Add Email',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
            ),
          ),
        ] else ...[
          // Verification Code Sent State
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF132A1C) : const Color(0xFFECFDF5),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFF22C55E)
                    .withValues(alpha: isDark ? 0.4 : 0.6),
                width: 1.0,
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.check_circle_outline,
                  color: Color(0xFF22C55E),
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _emailSuccess ?? 'Verification code sent.',
                    style: const TextStyle(
                      color: Color(0xFF22C55E),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 6-digit Code input box with floating label
          AuthTextField(
            label: '6-digit verification code',
            controller: _verificationCodeController,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _handleVerifyEmailCode(),
          ),

          if (_emailError != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                _emailError!,
                style: const TextStyle(
                  color: Color(0xFFED4956),
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ],

          const SizedBox(height: 20),

          // Verify Button (Curved pill)
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _isVerifyingEmail ? null : _handleVerifyEmailCode,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                disabledBackgroundColor:
                    AppTheme.primary.withValues(alpha: 0.5),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
              child: _isVerifyingEmail
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
                          'Verifying…',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    )
                  : const Text(
                      'Verify & Continue',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
            ),
          ),
        ],

        const SizedBox(height: 14),

        // Prominent "Skip for now" Button (Curved pill)
        SizedBox(
          height: 46,
          child: TextButton(
            onPressed: _finishOnboarding,
            style: TextButton.styleFrom(
              foregroundColor: isDark ? Colors.white70 : Colors.black87,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            child: const Text(
              'Skip for now',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),

        const SizedBox(height: 12),

        // Account status notice
        Center(
          child: Text(
            'Your account @${_usernameController.text.trim()} is created and ready.\nYou can add or change your email later in Settings.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: isDark ? Colors.white38 : Colors.black45,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBenefitRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String desc,
    required bool isDark,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: iconColor, size: 16),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: isDark ? Colors.white : const Color(0xFF18181B),
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                desc,
                style: TextStyle(
                  color: isDark ? Colors.white60 : Colors.black54,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
