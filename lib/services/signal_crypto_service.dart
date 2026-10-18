import 'dart:convert';
import 'dart:typed_data';

import 'package:flexiyo/models/key_bundle.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/services/persistent_signal_store.dart';
import 'package:flexiyo/storage/secure_keys.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:uuid/uuid.dart';

class EncryptedPayload {
  const EncryptedPayload({
    required this.payload,
    required this.messageType,
    required this.recipientDeviceId,
  });

  final String payload;
  final String messageType;
  final int recipientDeviceId;
}

class SignalCryptoService {
  SignalCryptoService._({
    required SecureKeyValueStore storage,
    required ApiService api,
    required PersistentSignalStore store,
  })  : _storage = storage,
        _api = api,
        _store = store;

  static const int _preKeyCount = 100;
  static const int _preKeyReplenishThreshold = 20;

  final SecureKeyValueStore _storage;
  final ApiService _api;
  final PersistentSignalStore _store;

  static Future<SignalCryptoService> open({
    required SecureKeyValueStore storage,
    required ApiService api,
    required String userId,
  }) async {
    final store = await PersistentSignalStore.open(
      storage: storage,
      userId: userId,
    );
    final service = SignalCryptoService._(
      storage: storage,
      api: api,
      store: store,
    );
    await service.ensureDeviceRegistered();
    return service;
  }

  Future<void> ensureDeviceRegistered() async {
    await _installationId();
    final registeredKey = _store.storageKey('device.registered');
    if (await _storage.readString(registeredKey) == 'true') {
      try {
        final remaining = await _api.getPreKeyCount();
        if (remaining >= _preKeyReplenishThreshold) return;
        await _replenishPreKeysIfNeeded();
        return;
      } catch (_) {
        // The backend may have been reset while this installation still has
        // its local registration flag. Re-register the existing key material.
        await _storage.deleteString(registeredKey);
      }
    }

    final pendingKey = _store.storageKey('device.registration.pending');
    final savedPayload = await _storage.readString(pendingKey);
    final Map<String, dynamic> payload;
    if (savedPayload != null) {
      payload = jsonDecode(savedPayload) as Map<String, dynamic>;
    } else {
      payload = await _createDevicePayload();
      await _storage.saveString(pendingKey, jsonEncode(payload));
    }

    payload['installationId'] = await _installationId();

    final deviceId = await _api.registerDevice(payload);
    if (deviceId > 0) {
      await _storage.saveString(
        _store.storageKey('device.id'),
        deviceId.toString(),
      );
    }
    await _storage.saveString(registeredKey, 'true');
    await _storage.deleteString(pendingKey);
    await _replenishPreKeysIfNeeded();
  }

  Future<void> saveLocalMessageText(String messageId, String plaintext) =>
      _storage.saveString(
          _store.storageKey('message.$messageId.text'), plaintext);

  Future<String?> getLocalMessageText(String messageId) =>
      _storage.readString(_store.storageKey('message.$messageId.text'));

  Future<void> deleteLocalMessageText(String messageId) =>
      _storage.deleteString(_store.storageKey('message.$messageId.text'));

  Future<Map<String, dynamic>> _createDevicePayload() async {
    final signedPreKey = generateSignedPreKey(_store.identityKeyPair, 1);
    await _store.storeSignedPreKey(signedPreKey.id, signedPreKey);

    final preKeys = generatePreKeys(1, _preKeyCount);
    for (final preKey in preKeys) {
      await _store.storePreKey(preKey.id, preKey);
    }
    await _storage.saveString(
      _store.storageKey('prekey.nextId'),
      (_preKeyCount + 1).toString(),
    );

    return {
      'installationId': await _installationId(),
      'registrationId': _store.registrationId,
      'identityKey': base64Encode(_store.identityKey.serialize()),
      'signedPreKey': {
        'keyId': signedPreKey.id,
        'publicKey': base64Encode(
          signedPreKey.getKeyPair().publicKey.serialize(),
        ),
        'signature': base64Encode(signedPreKey.signature),
      },
      'preKeys': preKeys
          .map(
            (preKey) => {
              'keyId': preKey.id,
              'publicKey': base64Encode(
                preKey.getKeyPair().publicKey.serialize(),
              ),
            },
          )
          .toList(),
    };
  }

  Future<String> _installationId() async {
    const key = 'flexiyo.installation_id';
    final existing = await _storage.readString(key);
    if (existing != null && existing.isNotEmpty) return existing;
    final created = const Uuid().v4();
    await _storage.saveString(key, created);
    return created;
  }

  Future<void> _replenishPreKeysIfNeeded() async {
    final remaining = await _api.getPreKeyCount();
    if (remaining >= _preKeyReplenishThreshold) return;

    final nextIdKey = _store.storageKey('prekey.nextId');
    final startId = int.tryParse(await _storage.readString(nextIdKey) ?? '') ??
        (_preKeyCount + 1);
    final preKeys = generatePreKeys(startId, _preKeyCount);
    for (final preKey in preKeys) {
      await _store.storePreKey(preKey.id, preKey);
    }

    await _storage.saveString(
      nextIdKey,
      (startId + _preKeyCount).toString(),
    );
    await _api.replenishPreKeys(
      preKeys
          .map(
            (preKey) => {
              'keyId': preKey.id,
              'publicKey': base64Encode(
                preKey.getKeyPair().publicKey.serialize(),
              ),
            },
          )
          .toList(),
    );
  }

  Future<EncryptedPayload> encryptForUser(
    String recipientId,
    String plaintext,
  ) async {
    final bundle = await _api.fetchKeyBundle(recipientId);
    final address = SignalProtocolAddress(recipientId, bundle.deviceId);
    if (!await _store.containsSession(address)) {
      await SessionBuilder.fromSignalStore(_store, address)
          .processPreKeyBundle(_toPreKeyBundle(bundle));
    }

    final ciphertext = await SessionCipher.fromStore(_store, address).encrypt(
      Uint8List.fromList(utf8.encode(plaintext)),
    );
    return EncryptedPayload(
      payload: base64Encode(ciphertext.serialize()),
      messageType: ciphertext.getType() == CiphertextMessage.prekeyType
          ? 'prekey'
          : 'signal',
      recipientDeviceId: bundle.deviceId,
    );
  }

  Future<String> decryptFromUser({
    required String senderId,
    required int senderDeviceId,
    required String payload,
    required String messageType,
  }) async {
    final address = SignalProtocolAddress(senderId, senderDeviceId);
    final bytes = Uint8List.fromList(base64Decode(payload));
    final cipher = SessionCipher.fromStore(_store, address);
    final plaintext = messageType == 'prekey'
        ? await cipher.decrypt(PreKeySignalMessage(bytes))
        : await cipher.decryptFromSignal(SignalMessage.fromSerialized(bytes));
    return utf8.decode(plaintext);
  }

  PreKeyBundle _toPreKeyBundle(KeyBundle bundle) {
    final identityKey = IdentityKey.fromBytes(
      Uint8List.fromList(base64Decode(bundle.identityKey)),
      0,
    );
    final signedPreKey = Curve.decodePoint(
      Uint8List.fromList(base64Decode(bundle.signedPreKey)),
      0,
    );
    final preKey = bundle.preKey != null
        ? Curve.decodePoint(
            Uint8List.fromList(base64Decode(bundle.preKey!)),
            0,
          )
        : null;

    return PreKeyBundle(
      bundle.registrationId,
      bundle.deviceId,
      bundle.preKeyId ?? 0,
      preKey,
      bundle.signedPreKeyId,
      signedPreKey,
      Uint8List.fromList(base64Decode(bundle.signedPreKeySignature)),
      identityKey,
    );
  }
}
