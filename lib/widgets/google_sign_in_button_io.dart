import 'package:flexiyo/services/google_auth_service.dart';
import 'package:flutter/material.dart';

import 'google_sign_in_button_shell.dart';

/// Google sign-in button for platforms where sign-in can be started from an
/// app-drawn button.
class GoogleSignInButton extends StatefulWidget {
  const GoogleSignInButton({
    super.key,
    required this.onResult,
    required this.onError,
    this.busy = false,
    this.signUp = false,
  });

  /// Called with the authenticated Google account; the host screen performs
  /// the server-side login with it.
  final Future<void> Function(GoogleAuthResult result) onResult;

  /// Called when Google authentication fails.
  final ValueChanged<Object> onError;

  /// Shows a progress state, e.g. while a login triggered by a previous
  /// result is still in flight.
  final bool busy;

  /// Uses the sign-up label instead of the sign-in label.
  final bool signUp;

  @override
  State<GoogleSignInButton> createState() => _GoogleSignInButtonState();
}

class _GoogleSignInButtonState extends State<GoogleSignInButton> {
  bool _authenticating = false;

  Future<void> _handlePressed() async {
    if (_authenticating || widget.busy) return;
    setState(() => _authenticating = true);
    try {
      final result = await GoogleAuthService.instance.signIn();
      if (result != null) {
        await widget.onResult(result);
      }
    } catch (e) {
      widget.onError(e);
    } finally {
      if (mounted) setState(() => _authenticating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GoogleSignInButtonShell(
      label: widget.signUp ? 'Sign up with Google' : 'Continue with Google',
      onPressed: _handlePressed,
      busy: _authenticating || widget.busy,
    );
  }
}
