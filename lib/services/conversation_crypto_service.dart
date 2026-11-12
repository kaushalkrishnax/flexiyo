import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flexiyo/core/exceptions.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/services/conversation_key_repository.dart';
import 'package:flexiyo/storage/local_conversation_key_store.dart';

class ConversationCryptoService {
  ConversationCryptoService({
    required ApiService api,
    required LocalConversationKeyStore store,
  })  : _api = api,
        _store = store,
        _keys = ConversationKeyRepository(api);

  final ApiService _api;
  final LocalConversationKeyStore _store;
  final ConversationKeyRepository _keys;

  static final Xchacha20 _aead = Xchacha20.poly1305Aead();
  static final X25519 _x25519 = X25519();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final Map<String, Uint8List> _keyCache = {};
  final Map<String, int> _registeredDeviceIds = {};

  String _cacheId(String userId, String conversationId, int epoch) =>
      '$userId:$conversationId:$epoch';

  Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  Future<SimpleKeyPair> _identityKeyPair(String userId) async {
    final privateSeed = await _store.readIdentityPrivateSeed(userId);
    if (privateSeed != null && privateSeed.length == 32) {
      return _x25519.newKeyPairFromSeed(privateSeed);
    }

    final pair = await _x25519.newKeyPair();
    final privateBytes = await pair.extractPrivateKeyBytes();
    final publicKey = await pair.extractPublicKey();
    await _store.saveIdentityKeyPair(
      userId: userId,
      privateSeed: Uint8List.fromList(privateBytes),
      publicKey: Uint8List.fromList(publicKey.bytes),
    );
    return pair;
  }

  Future<String> getIdentityPublicKey(String userId) async {
    final pair = await _identityKeyPair(userId);
    final publicKey = await pair.extractPublicKey();
    final encoded = base64Encode(publicKey.bytes);
    if (await _store.readIdentityPublicKey(userId) != encoded) {
      final privateSeed = await pair.extractPrivateKeyBytes();
      await _store.saveIdentityKeyPair(
        userId: userId,
        privateSeed: Uint8List.fromList(privateSeed),
        publicKey: Uint8List.fromList(publicKey.bytes),
      );
    }
    return encoded;
  }

  Future<int> ensureDeviceRegistered({required String userId}) async {
    final cached = _registeredDeviceIds[userId];
    if (cached != null) return cached;

    final existingDeviceId = await _store.readDeviceId(userId);
    final installationId = await _store.getOrCreateInstallationId();
    final identityPublicKey = await getIdentityPublicKey(userId);

    if (existingDeviceId != null) {
      try {
        final response = await _api.upgradeConversationKeyDevice(identityPublicKey);
        final verifiedId = (response['deviceId'] as num?)?.toInt();
        if (verifiedId == null || verifiedId != existingDeviceId) {
          throw StateError('Stored device ID does not match the registered device');
        }
        _registeredDeviceIds[userId] = existingDeviceId;
        return existingDeviceId;
      } on UnauthorizedException {
        // The installation was revoked or removed server-side.
        await _store.clearDeviceId(userId);
        _registeredDeviceIds.remove(userId);
        throw StateError(
          'This installation is no longer linked. Pair it again from Linked devices.',
        );
      } catch (error) {
        throw StateError('Registered device could not be verified: $error');
      }
    }

    try {
      final response = await _api.registerConversationKeyDevice(
        installationId: installationId,
        identityPublicKey: identityPublicKey,
      );
      final deviceId = (response['deviceId'] as num?)?.toInt();
      if (deviceId == null || deviceId <= 0) {
        throw StateError('Server returned an invalid device ID');
      }
      await _store.saveDeviceId(userId, deviceId);
      _registeredDeviceIds[userId] = deviceId;
      return deviceId;
    } on ApiException catch (registrationError) {
      if (registrationError.message == 'pairing_required') {
        throw StateError(
          'This installation needs approval from an existing linked device.',
        );
      }
      if (registrationError.message != 'installation_already_registered') {
        rethrow;
      }
      // A legacy (v1) installation with this id exists: upgrade it in place.
      // This only works while the account has no v2 device; afterwards the
      // server requires QR approval.
      final Map<String, dynamic> response;
      try {
        response = await _api.upgradeConversationKeyDevice(identityPublicKey);
      } on ApiException catch (upgradeError) {
        if (upgradeError.message == 'pairing_required') {
          throw StateError(
            'This installation needs approval from an existing linked device.',
          );
        }
        rethrow;
      }
      final deviceId = (response['deviceId'] as num?)?.toInt();
      if (deviceId == null || deviceId <= 0) {
        throw StateError('Server returned an invalid device ID');
      }
      await _store.saveDeviceId(userId, deviceId);
      _registeredDeviceIds[userId] = deviceId;
      return deviceId;
    }
  }

  Future<int?> getDeviceId(String userId) => _store.readDeviceId(userId);

  Future<({Uint8List key, int epoch})> ensureConversationKey({
    required String conversationId,
    required String myUserId,
    required String peerUserId,
  }) async {
    await ensureDeviceRegistered(userId: myUserId);
    var state = await _keys.getEpochs(conversationId);
    var currentEpoch = (state['currentEpoch'] as num?)?.toInt() ?? 0;
    var rotationRequired = state['keyRotationRequired'] == true;

    if (currentEpoch > 0 && !rotationRequired) {
      final cached = await _readKey(myUserId, conversationId, currentEpoch);
      final key = cached ??
          await _fetchAndUnwrapKey(myUserId, conversationId, currentEpoch);
      return (key: key, epoch: currentEpoch);
    }

    final nextEpoch = currentEpoch + 1;
    try {
      final key = await _createAndPublishKey(
        conversationId: conversationId,
        myUserId: myUserId,
        peerUserId: peerUserId,
        epoch: nextEpoch,
      );
      return (key: key, epoch: nextEpoch);
    } catch (_) {
      // Another participant/device may have won the epoch compare-and-swap.
      // Re-read and unwrap the committed epoch rather than failing a send.
      state = await _keys.getEpochs(conversationId);
      currentEpoch = (state['currentEpoch'] as num?)?.toInt() ?? 0;
      rotationRequired = state['keyRotationRequired'] == true;
      if (currentEpoch > 0 && !rotationRequired) {
        final cached = await _readKey(myUserId, conversationId, currentEpoch);
        final key = cached ??
            await _fetchAndUnwrapKey(myUserId, conversationId, currentEpoch);
        return (key: key, epoch: currentEpoch);
      }
      rethrow;
    }
  }

  Future<Uint8List> _createAndPublishKey({
    required String conversationId,
    required String myUserId,
    required String peerUserId,
    required int epoch,
  }) async {
    final myDevices = await _keys.getDeviceKeys(myUserId);
    final peerDevices = await _keys.getDeviceKeys(peerUserId);
    if (myDevices.isEmpty || peerDevices.isEmpty) {
      throw StateError('Both participants need an active conversation-key device');
    }

    final key = _randomBytes(32);
    final envelopes = <Map<String, dynamic>>[];
    final seen = <int>{};
    for (final device in [...myDevices, ...peerDevices]) {
      final deviceId = (device['deviceId'] as num?)?.toInt();
      final publicKey = device['identityPublicKey'] as String?;
      if (deviceId == null || publicKey == null || !seen.add(deviceId)) {
        throw StateError('Invalid or duplicate active device identity');
      }
      envelopes.add(await _sealConversationKey(
        conversationId: conversationId,
        epoch: epoch,
        recipientDeviceId: deviceId,
        recipientPublicKey: publicKey,
        conversationKey: key,
      ));
    }

    await _keys.publishEpoch(
      conversationId: conversationId,
      epoch: epoch,
      envelopes: envelopes,
    );
    await _saveKey(myUserId, conversationId, epoch, key);
    return key;
  }

  Future<Map<String, dynamic>> _sealConversationKey({
    required String conversationId,
    required int epoch,
    required int recipientDeviceId,
    required String recipientPublicKey,
    required Uint8List conversationKey,
  }) async {
    final recipientBytes = base64Decode(recipientPublicKey);
    if (recipientBytes.length != 32) {
      throw StateError('Invalid recipient X25519 public key');
    }

    final ephemeralPair = await _x25519.newKeyPair();
    final ephemeralPublic = await ephemeralPair.extractPublicKey();
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: ephemeralPair,
      remotePublicKey: SimplePublicKey(
        recipientBytes,
        type: KeyPairType.x25519,
      ),
    );

    // A fresh AEAD nonce is used once as the HKDF salt and once as the
    // XChaCha20-Poly1305 nonce. These are separate algorithm domains.
    final nonce = _aead.newNonce();
    final aad = utf8.encode(jsonEncode([
      'flexiyo-key-envelope-v2',
      conversationId,
      epoch,
      recipientDeviceId,
    ]));
    final wrappingKey = await _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: nonce,
      info: aad,
    );
    final box = await _aead.encrypt(
      conversationKey,
      secretKey: wrappingKey,
      nonce: nonce,
      aad: aad,
    );

    return {
      'recipientDeviceId': recipientDeviceId,
      'ephemeralPublicKey': base64Encode(ephemeralPublic.bytes),
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  Future<Uint8List> _unwrapConversationKey({
    required String userId,
    required String conversationId,
    required int epoch,
    required int recipientDeviceId,
    required Map<String, dynamic> envelope,
  }) async {
    final privateSeed = await _store.readIdentityPrivateSeed(userId);
    if (privateSeed == null || privateSeed.length != 32) {
      throw StateError('This device identity key is unavailable');
    }
    final localPair = await _x25519.newKeyPairFromSeed(privateSeed);
    final ephemeral = base64Decode(envelope['ephemeralPublicKey'] as String);
    final nonce = base64Decode(envelope['nonce'] as String);
    final ciphertext = base64Decode(envelope['ciphertext'] as String);
    final mac = base64Decode(envelope['mac'] as String);
    if (ephemeral.length != 32 || nonce.length != 24 || mac.length != 16) {
      throw StateError('Invalid conversation key envelope');
    }
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: localPair,
      remotePublicKey: SimplePublicKey(
        ephemeral,
        type: KeyPairType.x25519,
      ),
    );
    final aad = utf8.encode(jsonEncode([
      'flexiyo-key-envelope-v2',
      conversationId,
      epoch,
      recipientDeviceId,
    ]));
    final wrappingKey = await _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: nonce,
      info: aad,
    );
    final clear = await _aead.decrypt(
      SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
      secretKey: wrappingKey,
      aad: aad,
    );
    if (clear.length != 32) throw StateError('Invalid conversation key length');
    return Uint8List.fromList(clear);
  }

  Future<Uint8List?> _readKey(
    String userId,
    String conversationId,
    int epoch,
  ) async {
    final cacheKey = _cacheId(userId, conversationId, epoch);
    final cached = _keyCache[cacheKey];
    if (cached != null) return Uint8List.fromList(cached);
    final stored = await _store.readConversationKey(
      userId: userId,
      conversationId: conversationId,
      epoch: epoch,
    );
    if (stored != null) _keyCache[cacheKey] = stored;
    return stored;
  }

  Future<void> _saveKey(
    String userId,
    String conversationId,
    int epoch,
    Uint8List key,
  ) async {
    _keyCache[_cacheId(userId, conversationId, epoch)] = Uint8List.fromList(key);
    await _store.saveConversationKey(
      userId: userId,
      conversationId: conversationId,
      epoch: epoch,
      key: key,
    );
  }

  Future<Uint8List> _fetchAndUnwrapKey(
    String userId,
    String conversationId,
    int epoch,
  ) async {
    final deviceId = await ensureDeviceRegistered(userId: userId);
    final response = await _keys.getEnvelopes(conversationId, epoch: epoch);
    final envelopes = (response['envelopes'] as List<dynamic>?) ?? const [];
    final envelope = envelopes.cast<Map<String, dynamic>>().firstWhere(
      (item) => (item['epoch'] as num?)?.toInt() == epoch,
      orElse: () => throw StateError(
        'Conversation key for epoch $epoch has not been provisioned to this device',
      ),
    );
    final key = await _unwrapConversationKey(
      userId: userId,
      conversationId: conversationId,
      epoch: epoch,
      recipientDeviceId: deviceId,
      envelope: envelope,
    );
    await _saveKey(userId, conversationId, epoch, key);
    return key;
  }

  Future<Map<String, dynamic>> encryptMessage({
    required String conversationId,
    required String messageId,
    required String myUserId,
    required String peerUserId,
    required String plaintext,
  }) async {
    final current = await ensureConversationKey(
      conversationId: conversationId,
      myUserId: myUserId,
      peerUserId: peerUserId,
    );
    final nonce = _aead.newNonce();
    final aad = utf8.encode(jsonEncode([
      'flexiyo-message-v2',
      conversationId,
      messageId,
      current.epoch,
    ]));
    final box = await _aead.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(current.key),
      nonce: nonce,
      aad: aad,
    );
    return {
      'encryptionVersion': 2,
      'ciphertext': base64Encode(box.cipherText),
      'nonce': base64Encode(nonce),
      'authTag': base64Encode(box.mac.bytes),
      'keyEpoch': current.epoch,
    };
  }

  Future<String> decryptMessage({
    required String userId,
    required String conversationId,
    required String messageId,
    required int keyEpoch,
    required String ciphertext,
    required String nonce,
    required String authTag,
  }) async {
    final key = await _readKey(userId, conversationId, keyEpoch) ??
        await _fetchAndUnwrapKey(userId, conversationId, keyEpoch);
    final aad = utf8.encode(jsonEncode([
      'flexiyo-message-v2',
      conversationId,
      messageId,
      keyEpoch,
    ]));
    final clear = await _aead.decrypt(
      SecretBox(
        base64Decode(ciphertext),
        nonce: base64Decode(nonce),
        mac: Mac(base64Decode(authTag)),
      ),
      secretKey: SecretKey(key),
      aad: aad,
    );
    return utf8.decode(clear);
  }

  Future<void> provisionCurrentEpochForDevice({
    required String conversationId,
    required String myUserId,
    required String peerUserId,
    required int newDeviceId,
    required String newIdentityPublicKey,
  }) async {
    final epochs = await _keys.getEpochs(conversationId);
    final currentEpoch = (epochs['currentEpoch'] as num?)?.toInt() ?? 0;
    if (currentEpoch < 1) return;
    if (epochs['keyRotationRequired'] == true) {
      await ensureConversationKey(
        conversationId: conversationId,
        myUserId: myUserId,
        peerUserId: peerUserId,
      );
      return;
    }
    final key = await _readKey(myUserId, conversationId, currentEpoch) ??
        await _fetchAndUnwrapKey(myUserId, conversationId, currentEpoch);
    final envelope = await _sealConversationKey(
      conversationId: conversationId,
      epoch: currentEpoch,
      recipientDeviceId: newDeviceId,
      recipientPublicKey: newIdentityPublicKey,
      conversationKey: key,
    );
    await _keys.addEnvelopes(
      conversationId: conversationId,
      epoch: currentEpoch,
      envelopes: [envelope],
    );
  }
}
