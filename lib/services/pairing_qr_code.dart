import 'dart:convert';

/// Validated contents of a `flexiyo-pairing-v2` QR code.
///
/// The payload is only ever exchanged between two devices the user controls.
/// It carries the one-time pairing secret, which the API must never receive.
class PairingQrCode {
  const PairingQrCode({
    required this.sessionId,
    required this.initiatorEphemeralPublic,
    required this.pairingSecret,
    this.expiresAt,
  });

  static const type = 'flexiyo-pairing-v2';

  final String sessionId;
  final String initiatorEphemeralPublic;
  final String pairingSecret;

  /// Server-provided Unix timestamp in seconds, when present.
  final int? expiresAt;

  DateTime? get expiry => expiresAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(expiresAt! * 1000);

  bool isExpiredAt(DateTime now) {
    final at = expiry;
    return at != null && !at.isAfter(now);
  }

  factory PairingQrCode.fromPayload(Map<String, dynamic> payload) {
    if (payload['type'] != type) {
      throw const FormatException('Not a Flexiyo pairing code');
    }
    final sessionId = payload['sessionId'];
    final initiatorPublic = payload['initiatorEphemeralPublic'];
    final secret = payload['pairingSecret'];
    if (sessionId is! String ||
        sessionId.isEmpty ||
        initiatorPublic is! String ||
        secret is! String) {
      throw const FormatException('Pairing code is incomplete');
    }
    if (!_isKey(initiatorPublic) || !_isKey(secret)) {
      throw const FormatException('Pairing code has invalid key material');
    }
    final expiresAt = payload['expiresAt'];
    if (expiresAt != null && expiresAt is! num) {
      throw const FormatException('Pairing code has an invalid expiry');
    }
    return PairingQrCode(
      sessionId: sessionId,
      initiatorEphemeralPublic: initiatorPublic,
      pairingSecret: secret,
      expiresAt: (expiresAt as num?)?.toInt(),
    );
  }

  factory PairingQrCode.parse(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Pairing code is not a JSON object');
    }
    return PairingQrCode.fromPayload(decoded);
  }

  Map<String, dynamic> toJson() => {
        'type': type,
        'sessionId': sessionId,
        'initiatorEphemeralPublic': initiatorEphemeralPublic,
        'pairingSecret': pairingSecret,
        if (expiresAt != null) 'expiresAt': expiresAt,
      };

  String encode() => jsonEncode(toJson());

  static bool _isKey(String value) {
    try {
      return base64Decode(value).length == 32;
    } on FormatException {
      return false;
    }
  }
}
