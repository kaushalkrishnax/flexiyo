import 'dart:convert';

import 'package:flexiyo/services/pairing_qr_code.dart';
import 'package:flutter_test/flutter_test.dart';

String _key(int seed) => base64Encode(List<int>.filled(32, seed));

void main() {
  final sessionId = '11111111-1111-4111-8111-111111111111';
  final publicKey = _key(1);
  final secret = _key(2);

  group('PairingQrCode', () {
    test('round-trips a complete payload', () {
      final expiresAt = DateTime.now().add(const Duration(minutes: 3));
      final qr = PairingQrCode(
        sessionId: sessionId,
        initiatorEphemeralPublic: publicKey,
        pairingSecret: secret,
        expiresAt: expiresAt.millisecondsSinceEpoch ~/ 1000,
      );

      final parsed = PairingQrCode.parse(qr.encode());

      expect(parsed.sessionId, sessionId);
      expect(parsed.initiatorEphemeralPublic, publicKey);
      expect(parsed.pairingSecret, secret);
      expect(parsed.expiresAt, qr.expiresAt);
    });

    test('rejects a payload from another protocol', () {
      expect(
        () => PairingQrCode.fromPayload({
          'type': 'flexiyo-pairing-v1',
          'sessionId': sessionId,
          'initiatorEphemeralPublic': publicKey,
          'pairingSecret': secret,
        }),
        throwsFormatException,
      );
    });

    test('rejects short or malformed key material', () {
      for (final bad in ['not-base64', base64Encode(List<int>.filled(16, 1))]) {
        expect(
          () => PairingQrCode.fromPayload({
            'type': PairingQrCode.type,
            'sessionId': sessionId,
            'initiatorEphemeralPublic': bad,
            'pairingSecret': secret,
          }),
          throwsFormatException,
        );
      }
    });

    test('rejects missing fields', () {
      expect(
        () => PairingQrCode.fromPayload({
          'type': PairingQrCode.type,
          'sessionId': sessionId,
          'initiatorEphemeralPublic': publicKey,
        }),
        throwsFormatException,
      );
    });

    test('rejects a non-object QR value', () {
      expect(() => PairingQrCode.parse('just text'), throwsFormatException);
    });

    test('detects expiry', () {
      final qr = PairingQrCode(
        sessionId: sessionId,
        initiatorEphemeralPublic: publicKey,
        pairingSecret: secret,
        expiresAt: DateTime.now()
            .subtract(const Duration(seconds: 1))
            .millisecondsSinceEpoch ~/
            1000,
      );

      expect(qr.isExpiredAt(DateTime.now()), isTrue);
      expect(
        PairingQrCode(
          sessionId: sessionId,
          initiatorEphemeralPublic: publicKey,
          pairingSecret: secret,
        ).isExpiredAt(DateTime.now()),
        isFalse,
      );
    });
  });
}
