import 'dart:convert';
import 'dart:typed_data';

import 'package:flexiyo/models/key_bundle.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/services/persistent_signal_store.dart';
import 'package:flexiyo/storage/secure_keys.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

class EncryptedPayload {
  const EncryptedPayload({required this.payload, required this.messageType});

  final String payload;
  final String messageType;
}

class SignalCryptoService {
  SignalCryptoService._({
    required SecureKeyValueStore storage,
    required ApiService api,
    required PersistentSignalStore store,
  })  : _storage = storage,
        _api = api,
        _store = store;

  static const int _deviceId = 1;
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
    final registeredKey = _store.storageKey('device.registered');
    if (await _storage.readString(registeredKey) == 'true') {
      await _replenishPreKeysIfNeeded();
      return;
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

    await _api.registerDevice(payload);
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
      'deviceId': _deviceId.toString(),
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
    final address = SignalProtocolAddress(recipientId, _deviceId);
    if (!await _store.containsSession(address)) {
      final bundle = await _api.fetchKeyBundle(recipientId);
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
    );
  }

  Future<String> decryptFromUser({
    required String senderId,
    required String payload,
    required String messageType,
  }) async {
    final address = SignalProtocolAddress(senderId, _deviceId);
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
    final preKey = Curve.decodePoint(
      Uint8List.fromList(base64Decode(bundle.preKey)),
      0,
    );

    return PreKeyBundle(
      bundle.registrationId,
      bundle.deviceId,
      bundle.preKeyId,
      preKey,
      bundle.signedPreKeyId,
      signedPreKey,
      Uint8List.fromList(base64Decode(bundle.signedPreKeySignature)),
      identityKey,
    );
  }
}
