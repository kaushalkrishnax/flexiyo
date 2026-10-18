import 'package:flutter/foundation.dart';

/// A Signal Protocol pre-key bundle from a remote user.
/// Used to establish an initial session.
@immutable
class KeyBundle {
  const KeyBundle({
    required this.userId,
    required this.deviceId,
    required this.registrationId,
    required this.identityKey,
    required this.signedPreKeyId,
    required this.signedPreKey,
    required this.signedPreKeySignature,
    required this.preKeyId,
    required this.preKey,
  });

  final String userId;
  final int deviceId;
  final int registrationId;

  /// Base64-encoded identity public key.
  final String identityKey;

  final int signedPreKeyId;

  /// Base64-encoded signed pre-key public key.
  final String signedPreKey;

  /// Base64-encoded signature of the signed pre-key.
  final String signedPreKeySignature;

  final int? preKeyId;

  /// Base64-encoded one-time pre-key public key. Null when the bundle has no
  /// one-time pre-key (X3DH without a one-time key, protocol-valid).
  final String? preKey;

  factory KeyBundle.fromJson(Map<String, dynamic> json) {
    final signedPreKey = json['signedPreKey'] as Map? ?? const {};
    final preKey = json['preKey'] as Map? ?? const {};
    final deviceIdValue = json['deviceId'] ?? json['device_id'];
    return KeyBundle(
      userId: (json['userId'] ?? json['user_id']) as String,
      deviceId: deviceIdValue is int
          ? deviceIdValue
          : int.tryParse(deviceIdValue?.toString() ?? '') ?? 1,
      registrationId:
          (json['registrationId'] ?? json['registration_id']) as int,
      identityKey: (json['identityKey'] ?? json['identity_key']) as String,
      signedPreKeyId:
          (signedPreKey['keyId'] ?? json['signed_pre_key_id']) as int,
      signedPreKey:
          (signedPreKey['publicKey'] ?? json['signed_pre_key']) as String,
      signedPreKeySignature: (signedPreKey['signature'] ??
          json['signed_pre_key_signature']) as String,
      preKeyId: preKey['keyId'] as int? ?? 0,
      preKey: preKey['publicKey'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'device_id': deviceId,
        'registration_id': registrationId,
        'identity_key': identityKey,
        'signed_pre_key_id': signedPreKeyId,
        'signed_pre_key': signedPreKey,
        'signed_pre_key_signature': signedPreKeySignature,
        'pre_key_id': preKeyId,
        'pre_key': preKey,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KeyBundle &&
          other.userId == userId &&
          other.deviceId == deviceId);

  @override
  int get hashCode => Object.hash(userId, deviceId);

  @override
  String toString() => 'KeyBundle(userId: $userId, deviceId: $deviceId)';
}
