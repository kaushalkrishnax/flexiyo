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

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['email', 'profile'],
  );

  Future<GoogleAuthResult?> signIn() async {
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) return null; // User cancelled

      final auth = await account.authentication;
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
      if (msg.contains('sign_in_canceled') || msg.contains('canceled') || msg.contains('cancelled')) {
        return null;
      }
      throw Exception('Google sign in error: $e');
    }
  }

  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
  }
}

