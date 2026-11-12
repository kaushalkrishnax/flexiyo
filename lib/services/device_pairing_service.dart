import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/services/conversation_crypto_service.dart';
import 'package:flexiyo/services/pairing_qr_code.dart';
import 'package:flexiyo/storage/local_conversation_key_store.dart';

class DevicePairingService {
  DevicePairingService({
    required ApiService api,
    required LocalConversationKeyStore store,
    required ConversationCryptoService crypto,
  })  : _api = api,
        _store = store,
        _crypto = crypto;

  final ApiService _api;
  final LocalConversationKeyStore _store;
  final ConversationCryptoService _crypto;

  static final X25519 _x25519 = X25519();
  static final Xchacha20 _aead = Xchacha20.poly1305Aead();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  List<int> _proofAad(
    String sessionId,
    String installationId,
    String identityPublicKey,
  ) =>
      utf8.encode(jsonEncode([
        'flexiyo-pairing-proof-v2',
        sessionId,
        installationId,
        identityPublicKey,
      ]));

  Future<({KeyPair pair, String publicKey})> _identity(String userId) async {
    final seed = await _store.readIdentityPrivateSeed(userId);
    if (seed != null && seed.length == 32) {
      final pair = await _x25519.newKeyPairFromSeed(seed);
      final publicKey = await pair.extractPublicKey();
      return (pair: pair, publicKey: base64Encode(publicKey.bytes));
    }

    final pair = await _x25519.newKeyPair();
    final privateBytes = await pair.extractPrivateKeyBytes();
    final publicKey = await pair.extractPublicKey();
    await _store.saveIdentityKeyPair(
      userId: userId,
      privateSeed: Uint8List.fromList(privateBytes),
      publicKey: Uint8List.fromList(publicKey.bytes),
    );
    return (pair: pair, publicKey: base64Encode(publicKey.bytes));
  }

  Future<Map<String, dynamic>> createQrSession({
    required String userId,
  }) async {
    await _crypto.ensureDeviceRegistered(userId: userId);

    final ephemeral = await _x25519.newKeyPair();
    final privateSeed = await ephemeral.extractPrivateKeyBytes();
    final publicKey = await ephemeral.extractPublicKey();
    final pairingSecret = Uint8List.fromList(List<int>.generate(
      32,
      (_) => Random.secure().nextInt(256),
    ));

    final response = await _api.createPairingSession(
      base64Encode(publicKey.bytes),
    );
    final sessionId = response['sessionId'] as String?;
    if (sessionId == null || sessionId.isEmpty) {
      throw StateError('Server did not create a pairing session');
    }

    await _store.savePairingPrivateSeed(
      sessionId,
      Uint8List.fromList(privateSeed),
    );
    await _store.savePairingSecret(sessionId, pairingSecret);
    await _store.savePairingPayload(
      sessionId,
      {
        'sessionId': sessionId,
        'initiatorEphemeralPublic': base64Encode(publicKey.bytes),
        'pairingSecret': base64Encode(pairingSecret),
        'expiresAt': response['expiresAt'],
      },
    );
    await _store.savePendingPairingSession(userId, sessionId);

    return {
      'type': 'flexiyo-pairing-v2',
      'sessionId': sessionId,
      'initiatorEphemeralPublic': base64Encode(publicKey.bytes),
      'pairingSecret': base64Encode(pairingSecret),
      'expiresAt': response['expiresAt'],
    };
  }

  Future<void> joinQrSession(
    Map<String, dynamic> qrPayload, {
    required String userId,
  }) async {
    if (qrPayload['type'] != 'flexiyo-pairing-v2') {
      throw StateError('Unsupported pairing QR code');
    }
    final sessionId = qrPayload['sessionId'] as String?;
    final initiatorPublic = qrPayload['initiatorEphemeralPublic'] as String?;
    final pairingSecretValue = qrPayload['pairingSecret'] as String?;
    if (sessionId == null || initiatorPublic == null || pairingSecretValue == null) {
      throw StateError('Pairing QR code is incomplete');
    }

    final initiatorBytes = base64Decode(initiatorPublic);
    final pairingSecret = base64Decode(pairingSecretValue);
    if (initiatorBytes.length != 32 || pairingSecret.length != 32) {
      throw StateError('Invalid pairing QR cryptographic material');
    }

    final identity = await _identity(userId);
    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPublic = await ephemeral.extractPublicKey();
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(
        initiatorBytes,
        type: KeyPairType.x25519,
      ),
    );

    final installationId = await _store.getOrCreateInstallationId();
    final aad = _proofAad(sessionId, installationId, identity.publicKey);
    final nonce = _aead.newNonce();
    final wrappingKey = await _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: pairingSecret,
      info: aad,
    );
    final challenge = List<int>.generate(
      32,
      (_) => Random.secure().nextInt(256),
    );
    final proof = await _aead.encrypt(
      challenge,
      secretKey: wrappingKey,
      nonce: nonce,
      aad: aad,
    );

    await _api.joinPairingSession(
      sessionId: sessionId,
      installationId: installationId,
      identityPublicKey: identity.publicKey,
      joinedEphemeralPublic: base64Encode(ephemeralPublic.bytes),
      nonce: base64Encode(nonce),
      ciphertext: base64Encode(proof.cipherText),
      mac: base64Encode(proof.mac.bytes),
    );
  }

  Future<Map<String, dynamic>> inspectPairingSession(String sessionId) =>
      _api.getPairingSession(sessionId);

  Future<bool> verifyJoinedDevice(String sessionId) async {
    final session = await _api.getPairingSession(sessionId);
    if (session['status'] != 'joined') return false;

    final privateSeed = await _store.readPairingPrivateSeed(sessionId);
    final pairingSecret = await _store.readPairingSecret(sessionId);
    if (privateSeed == null || privateSeed.length != 32 ||
        pairingSecret == null || pairingSecret.length != 32) {
      throw StateError('Pairing secret is unavailable on the initiating device');
    }

    final installationId = session['joinedInstallationId'] as String?;
    final identityPublicKey = session['joinedIdentityPublic'] as String?;
    if (installationId == null || identityPublicKey == null) {
      throw StateError('Joined device identity is incomplete');
    }
    final joinedPublic = base64Decode(session['joinedEphemeralPublic'] as String);
    final nonce = base64Decode(session['joinedNonce'] as String);
    final ciphertext = base64Decode(session['joinedCiphertext'] as String);
    final mac = base64Decode(session['joinedMac'] as String);
    if (joinedPublic.length != 32 || nonce.length != 24 || mac.length != 16 ||
        ciphertext.length != 32) {
      throw StateError('Invalid pairing proof envelope');
    }

    final pair = await _x25519.newKeyPairFromSeed(privateSeed);
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: pair,
      remotePublicKey: SimplePublicKey(
        joinedPublic,
        type: KeyPairType.x25519,
      ),
    );
    final aad = _proofAad(sessionId, installationId, identityPublicKey);
    final wrappingKey = await _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: pairingSecret,
      info: aad,
    );
    final challenge = await _aead.decrypt(
      SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
      secretKey: wrappingKey,
      aad: aad,
    );
    return challenge.length == 32;
  }

  Future<int> approveJoinedDevice(
    String sessionId, {
    required String myUserId,
  }) async {
    final session = await _api.getPairingSession(sessionId);
    int? deviceId;
    if (session['status'] == 'approved') {
      deviceId = (session['deviceId'] as num?)?.toInt();
    } else {
      if (!await verifyJoinedDevice(sessionId)) {
        throw StateError('Pairing proof verification failed');
      }
      final approved = await _api.approvePairingSession(sessionId);
      deviceId = (approved['deviceId'] as num?)?.toInt();
    }

    if (deviceId == null || deviceId <= 0) {
      throw StateError('Server did not approve the paired device');
    }
    final identityPublic = session['joinedIdentityPublic'] as String?;
    if (identityPublic == null || identityPublic.isEmpty) {
      throw StateError('Joining device identity is missing');
    }

    // Provision every currently available conversation. On retry this is
    // idempotent and repairs a partial pass after the server approved pairing.
    final conversations = await _api.getConversations(scope: 'all');
    for (final conversation in conversations) {
      await _crypto.provisionCurrentEpochForDevice(
        conversationId: conversation.id,
        myUserId: myUserId,
        peerUserId: conversation.otherUserId,
        newDeviceId: deviceId,
        newIdentityPublicKey: identityPublic,
      );
    }

    await _store.deletePairingPrivateSeed(sessionId);
    await _store.deletePairingSecret(sessionId);
    return deviceId;
  }

  Future<void> acceptApproval(
    String sessionId, {
    required String userId,
  }) async {
    final session = await _api.getPairingSession(sessionId);
    if (session['status'] != 'approved') {
      throw StateError('Device pairing has not been approved');
    }
    final deviceId = (session['deviceId'] as num?)?.toInt();
    if (deviceId == null || deviceId <= 0) {
      throw StateError('Approved device ID is missing');
    }
    await _store.saveDeviceId(userId, deviceId);
    await _crypto.ensureDeviceRegistered(userId: userId);
  }

  Future<void> cancelPairing(String sessionId) async {
    await _api.cancelPairingSession(sessionId);
    await _store.deletePairingPrivateSeed(sessionId);
    await _store.deletePairingSecret(sessionId);
    await _store.deletePairingPayload(sessionId);
  }

  Future<void> deletePairingPayload(String sessionId) =>
      _store.deletePairingPayload(sessionId);

  Future<void> savePendingPairingSession(String userId, String sessionId) =>
      _store.savePendingPairingSession(userId, sessionId);

  Future<String?> readPendingPairingSession(String userId) =>
      _store.readPendingPairingSession(userId);

  Future<void> clearPendingPairingSession(String userId) =>
      _store.clearPendingPairingSession(userId);

  /// Reuses an existing unexpired pending session instead of reissuing
  Future<PairingQrCode?> reusableSession({required String userId}) async {
    final sessionId = await readPendingPairingSession(userId);
    if (sessionId == null) return null;
    final payload = await _store.readPairingPayload(sessionId);
    if (payload == null) return null;
    try {
      final qr = PairingQrCode.fromPayload(payload);
      if (qr.isExpiredAt(DateTime.now())) {
        await clearPendingPairingSession(userId);
        await deletePairingPayload(sessionId);
        return null;
      }
      return qr;
    } on FormatException {
      return null;
    }
  }
}
