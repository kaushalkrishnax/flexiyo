import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:flexiyo/services/google_auth_service.dart';
import 'package:flutter/material.dart';
import 'package:google_identity_services_web/id.dart' as gis;
import 'package:web/web.dart' as web;

import 'google_sign_in_button_shell.dart';

/// Height of the app-styled buttons this widget has to match.
const double _buttonHeight = 46;

/// The SDK renders a 40px-tall button; scaling by this factor brings it to
/// [_buttonHeight]. Configured widths are divided by the same factor so the
/// scaled button still fills the slot.
const double _buttonScale = _buttonHeight / 40;

/// The SDK caps rendered buttons at 400px.
const double _maxButtonWidth = 400;

bool _stylesInjected = false;

/// One stylesheet for every rendered button: centres the SDK's button inside
/// its host and scales it to the app's button height.
void _ensureStyles() {
  if (_stylesInjected) return;
  _stylesInjected = true;
  web.document.head?.append(
    web.HTMLStyleElement()
      ..textContent = '''
        .flexiyo-gsi-host {
          display: flex;
          align-items: center;
          justify-content: center;
          width: 100%;
          height: 100%;
        }
        .flexiyo-gsi-host > div {
          transform: scale($_buttonScale);
          transform-origin: center center;
        }
      ''',
  );
}

/// Google sign-in button for web, rendered by the Google Identity Services
/// SDK.
///
/// The SDK rejects app-triggered sign-in on web, so sign-in can only start
/// from a button the SDK itself renders; the resulting account arrives on
/// [GoogleAuthService.authenticationEvents]. The SDK button is rendered into a
/// plain host element (instead of the plugin's widget) so its fixed 40px
/// height can be scaled up to match the surrounding app buttons.
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
  late final Future<void> _initialized;
  StreamSubscription<GoogleAuthResult>? _subscription;

  web.HTMLDivElement? _host;
  String? _renderedSignature;

  @override
  void initState() {
    super.initState();
    _initialized = GoogleAuthService.instance.ensureInitialized();
    _initialized.then((_) {}, onError: widget.onError);
    _subscription = GoogleAuthService.instance.authenticationEvents.listen(
      widget.onResult,
      onError: widget.onError,
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  /// (Re)renders the SDK button once the host element exists. Runs after the
  /// frame so the host is attached to the DOM, and only when the rendered
  /// shape (theme, label, width) actually changed.
  void _scheduleRender({required bool isDark, required double width}) {
    final signature = '${widget.signUp}|$isDark|${width.toStringAsFixed(1)}';
    if (signature == _renderedSignature) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || signature == _renderedSignature) return;
      final host = _host;
      if (host == null) return;
      _renderedSignature = signature;
      _ensureStyles();
      host.innerHTML = ''.toJS;
      gis.id.renderButton(
        host,
        gis.GsiButtonConfiguration(
          type: gis.ButtonType.standard,
          theme:
              isDark ? gis.ButtonTheme.filled_black : gis.ButtonTheme.outline,
          size: gis.ButtonSize.large,
          text: widget.signUp
              ? gis.ButtonText.signup_with
              : gis.ButtonText.continue_with,
          shape: gis.ButtonShape.pill,
          logo_alignment: gis.ButtonLogoAlignment.center,
          width: width,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label =
        widget.signUp ? 'Sign up with Google' : 'Continue with Google';

    return FutureBuilder<void>(
      future: _initialized,
      builder: (context, snapshot) {
        if (widget.busy) {
          return GoogleSignInButtonShell(label: label, busy: true);
        }
        if (snapshot.connectionState != ConnectionState.done ||
            snapshot.hasError) {
          return GoogleSignInButtonShell(label: label);
        }
        return SizedBox(
          height: _buttonHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Undo the CSS scale so the rendered width still fills the slot.
              final width = math.min(
                  constraints.maxWidth / _buttonScale, _maxButtonWidth);
              _scheduleRender(isDark: isDark, width: width);
              return HtmlElementView.fromTagName(
                tagName: 'div',
                onElementCreated: (Object element) {
                  final host = element as web.HTMLDivElement;
                  host.className = 'flexiyo-gsi-host';
                  _host = host;
                  _scheduleRender(isDark: isDark, width: width);
                },
              );
            },
          ),
        );
      },
    );
  }
}
