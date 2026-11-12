import 'package:flutter/foundation.dart';

/// An installation registered to the signed-in account.
///
/// Timestamps are Unix seconds, matching the Worker response.
@immutable
class PairedDevice {
  const PairedDevice({
    required this.id,
    required this.installationId,
    required this.status,
    required this.encryptionVersion,
    this.createdAt,
    this.lastSeenAt,
    this.revokedAt,
  });

  final int id;
  final String installationId;
  final String status;
  final int encryptionVersion;
  final int? createdAt;
  final int? lastSeenAt;
  final int? revokedAt;

  bool get isActive => status == 'active';
  bool get supportsConversationKeys => encryptionVersion >= 2;
  bool get wasRevoked => revokedAt != null || status == 'revoked';

  factory PairedDevice.fromJson(Map<String, dynamic> json) {
    int? seconds(Object? value) => value is num ? value.toInt() : null;
    return PairedDevice(
      id: (json['deviceId'] as num?)?.toInt() ?? 0,
      installationId: json['installationId'] as String? ?? '',
      status: json['status'] as String? ?? 'unknown',
      encryptionVersion: (json['encryptionVersion'] as num?)?.toInt() ?? 1,
      createdAt: seconds(json['createdAt']),
      lastSeenAt: seconds(json['lastSeenAt']),
      revokedAt: seconds(json['revokedAt']),
    );
  }
}
