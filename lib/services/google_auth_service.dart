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

  bool _initialized = false;

  // Platform-specific configuration: web takes the client ID, other platforms
  // take it as `serverClientId` so Google returns an idToken.
  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    if (kIsWeb) {
      await GoogleSignIn.instance.initialize(clientId: webClientId);
    } else {
      await GoogleSignIn.instance.initialize(serverClientId: webClientId);
    }
    _initialized = true;
  }

  Future<GoogleAuthResult?> signIn() async {
    try {
      await _ensureInitialized();
      final account = await GoogleSignIn.instance.authenticate();

      final auth = account.authentication;
      return GoogleAuthResult(
        idToken: auth.idToken,
        email: account.email,
        displayName: account.displayName,
        googleId: account.id,
        photoUrl: account.photoUrl,
      );
    } catch (e) {
      // Re-throw with clean user-facing error message
      final msg = e.toString().toLowerCase();
      if (msg.contains('sign_in_canceled') ||
          msg.contains('canceled') ||
          msg.contains('cancelled')) {
        return null;
      }
      // Web-only failure modes with console-side fixes worth surfacing.
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

  Future<void> signOut() async {
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }
}
