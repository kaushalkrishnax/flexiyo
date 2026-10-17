import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Firebase Cloud Messaging setup for notification delivery while the app is
/// backgrounded or closed. Realtime chat still flows over WebSockets — FCM
/// only covers offline delivery of new messages and message requests.
///
/// Android-only for now: iOS needs its own Firebase app registration
/// (`GoogleService-Info.plist`) and APNs keys before it can join.
///
/// Every failure path is swallowed: the app must keep working when Firebase
/// or Google Play Services is unavailable.
class PushService {
  PushService._();

  static bool _firebaseReady = false;
  static bool _refreshListenerAttached = false;

  /// Registers this device's FCM token with the backend. [register] posts the
  /// token to the API (the caller owns auth), so this class stays free of
  /// API-service dependencies. Idempotent — safe to call on every sign-in.
  static Future<void> init({
    required Future<void> Function(String token, String platform) register,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    if (!_firebaseReady) {
      try {
        await Firebase.initializeApp();
        _firebaseReady = true;
      } catch (_) {
        return; // Missing config / Play Services: stay silent.
      }
    }

    try {
      final messaging = FirebaseMessaging.instance;
      // Android 13+ asks the user once; below that this resolves granted.
      await messaging.requestPermission();

      // The backend delivers via the FCM HTTP v1 API using classic
      // registration tokens; FID direct-send would need a matching
      // server-side rollout first.
      // ignore: deprecated_member_use
      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) {
        try {
          await register(token, 'android');
        } catch (_) {
          // Retried on the next sign-in or app start.
        }
      }

      if (!_refreshListenerAttached) {
        _refreshListenerAttached = true;
        // ignore: deprecated_member_use
        messaging.onTokenRefresh.listen((refreshed) async {
          try {
            await register(refreshed, 'android');
          } catch (_) {
            // Retried on the next app start.
          }
        });
      }
    } catch (_) {
      // Notification setup must never block the app.
    }
  }

  /// Best-effort removal so a signed-out device stops receiving this
  /// account's notifications. Must be called while the JWT is still valid.
  static Future<void> unregister({
    required Future<void> Function(String token) unregister,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      // ignore: deprecated_member_use
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) {
        await unregister(token);
      }
    } catch (_) {}
  }
}
