import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_sign_in/google_sign_in.dart';

class GoogleAuthResult {
  const GoogleAuthResult({
    this.idToken,
    this.email,
    this.displayName,
    this.googleId,
    this.photoUrl,
  });

  final String? idToken;
  final String? email;
  final String? displayName;
  final String? googleId;
  final String? photoUrl;
}

class GoogleAuthService {
  GoogleAuthService._();
  static final GoogleAuthService instance = GoogleAuthService._();

  // Web application OAuth client ID from Google Cloud Console → Credentials.
  // - Android/iOS: pass it as `serverClientId` so Google returns an idToken.
  // - Web: pass it as `clientId` (`serverClientId` is not supported on web).
  // The deployed origin must be listed under the OAuth client's
  // "Authorized JavaScript origins" in Google Cloud Console for browser
  // sign-in to work.
  static const String webClientId =
      '1053892601915-pv8md97j50fb70u72rrdkfkvlfabog25.apps.googleusercontent.com';

  Future<void>? _initialization;

  /// Initializes the Google Sign-In SDK once per app run, with the client ID
  /// type each platform requires.
  Future<void> ensureInitialized() => _initialization ??= kIsWeb
      ? GoogleSignIn.instance.initialize(clientId: webClientId)
      : GoogleSignIn.instance.initialize(serverClientId: webClientId);

  /// Whether sign-in can be triggered from an app-drawn button. False on web,
  /// where Google only allows it via the SDK-rendered button widget.
  bool get supportsAppTriggeredSignIn =>
      GoogleSignIn.instance.supportsAuthenticate();

  Future<GoogleAuthResult?> signIn() async {
    if (!supportsAppTriggeredSignIn) {
      throw UnsupportedError(
        'This platform requires the GoogleSignInButton widget.',
      );
    }
    try {
      await ensureInitialized();
      final account = await GoogleSignIn.instance.authenticate();
      return _toResult(account);
    } catch (e) {
      // Re-throw with clean user-facing error message
      final msg = e.toString().toLowerCase();
      if (msg.contains('sign_in_canceled') ||
          msg.contains('canceled') ||
          msg.contains('cancelled')) {
        return null;
      }
      if (msg.contains('origin') && msg.contains('client id')) {
        throw Exception(
          'Google sign-in is not allowed for this site address. Add it under '
          '"Authorized JavaScript origins" for the OAuth client in Google '
          'Cloud Console, then try again.',
        );
      }
      if (msg.contains('people api')) {
        throw Exception(
          'Google sign-in requires the "People API" to be enabled for the '
          'OAuth project in Google Cloud Console.',
        );
      }
      throw Exception('Google sign in error: $e');
    }
  }

  /// Sign-in results emitted by the Google-rendered button widget, which is
  /// the only way to sign in on web.
  Stream<GoogleAuthResult> get authenticationEvents =>
      GoogleSignIn.instance.authenticationEvents
          .where((event) => event is GoogleSignInAuthenticationEventSignIn)
          .map((event) =>
              _toResult((event as GoogleSignInAuthenticationEventSignIn).user));

  GoogleAuthResult _toResult(GoogleSignInAccount account) {
    final auth = account.authentication;
    return GoogleAuthResult(
      idToken: auth.idToken,
      email: account.email,
      displayName: account.displayName,
      googleId: account.id,
      photoUrl: account.photoUrl,
    );
  }

  Future<void> signOut() async {
    try {
      await ensureInitialized();
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }
}
