import 'dart:convert';

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
  final int? expiresAt;

  /// 6-character alphanumeric display code (`XXX-XXX`) derived from [sessionId]
  String get shortCode {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    int hash = 0x811C9DC5;
    for (final byte in utf8.encode(sessionId)) {
      hash = ((hash * 0x01000193) ^ byte) & 0xFFFFFFFF;
    }
    var value = BigInt.from(hash & 0x7FFFFFFF);
    var code = '';
    for (var i = 0; i < 6; i++) {
      code = alphabet[(value % BigInt.from(36)).toInt()] + code;
      value ~/= BigInt.from(36);
    }
    return '${code.substring(0, 3)}-${code.substring(3)}';
  }

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
