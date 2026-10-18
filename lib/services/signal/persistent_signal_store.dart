import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../../storage/secure_keys.dart';

class PersistentSignalStore implements SignalProtocolStore {
  PersistentSignalStore._(
    this._storage,
    this._prefix,
    this._identityKeyPair,
    this._registrationId,
  );

  final SecureKeyValueStore _storage;
  final String _prefix;
  final IdentityKeyPair _identityKeyPair;
  final int _registrationId;

  IdentityKeyPair get identityKeyPair => _identityKeyPair;
  IdentityKey get identityKey => _identityKeyPair.getPublicKey();
  int get registrationId => _registrationId;
  String storageKey(String suffix) => _key(suffix);

  static Future<PersistentSignalStore> open({
    required SecureKeyValueStore storage,
    required String userId,
  }) async {
    final encodedUserId =
        base64Url.encode(utf8.encode(userId)).replaceAll('=', '');
    final prefix = 'signal.$encodedUserId.';
    final identityKey = '$prefix.identity';
    final registrationKey = '$prefix.registration';

    var identity = await storage.readString(identityKey);
    var registration = await storage.readString(registrationKey);
    if (identity == null || registration == null) {
      final identityKeyPair = generateIdentityKeyPair();
      final registrationId = generateRegistrationId(false);
      identity = base64Encode(identityKeyPair.serialize());
      registration = registrationId.toString();
      await storage.saveString(identityKey, identity);
      await storage.saveString(registrationKey, registration);
    }

    return PersistentSignalStore._(
      storage,
      prefix,
      IdentityKeyPair.fromSerialized(base64Decode(identity)),
      int.parse(registration),
    );
  }

  String _key(String suffix) => '$_prefix$suffix';

  String _addressKey(SignalProtocolAddress address) {
    final name =
        base64Url.encode(utf8.encode(address.getName())).replaceAll('=', '');
    return '$name.${address.getDeviceId()}';
  }

  Future<List<dynamic>> _readIndex(String key) async {
    final value = await _storage.readString(_key(key));
    if (value == null) return [];
    try {
      final decoded = jsonDecode(value);
      return decoded is List ? decoded : [];
    } on FormatException {
      return [];
    }
  }

  Future<void> _writeIndex(String key, List<dynamic> values) =>
      _storage.saveString(_key(key), jsonEncode(values));

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async => _identityKeyPair;

  @override
  Future<int> getLocalRegistrationId() async => _registrationId;

  @override
  Future<bool> saveIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
  ) async {
    if (identityKey == null) return false;
    final key = _key('identity.${_addressKey(address)}');
    final encoded = base64Encode(identityKey.serialize());
    final previous = await _storage.readString(key);
    if (previous == encoded) return false;
    await _storage.saveString(key, encoded);
    return true;
  }

  @override
  Future<bool> isTrustedIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
    Direction direction,
  ) async {
    if (identityKey == null) return false;
    final trusted = await getIdentity(address);
    return trusted == null ||
        base64Encode(trusted.serialize()) ==
            base64Encode(identityKey.serialize());
  }

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    final encoded = await _storage.readString(
      _key('identity.${_addressKey(address)}'),
    );
    if (encoded == null) return null;
    return IdentityKey.fromBytes(Uint8List.fromList(base64Decode(encoded)), 0);
  }

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final encoded = await _storage.readString(_key('prekey.$preKeyId'));
    if (encoded == null) {
      throw InvalidKeyIdException('No pre-key found for ID $preKeyId');
    }
    return PreKeyRecord.fromBuffer(Uint8List.fromList(base64Decode(encoded)));
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) => _storage
      .saveString(_key('prekey.$preKeyId'), base64Encode(record.serialize()));

  @override
  Future<bool> containsPreKey(int preKeyId) async =>
      await _storage.readString(_key('prekey.$preKeyId')) != null;

  @override
  Future<void> removePreKey(int preKeyId) =>
      _storage.deleteString(_key('prekey.$preKeyId'));

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    final encoded = await _storage.readString(
      _key('session.${_addressKey(address)}'),
    );
    if (encoded == null) return SessionRecord();
    return SessionRecord.fromSerialized(
        Uint8List.fromList(base64Decode(encoded)));
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async =>
      await _storage.readString(_key('session.${_addressKey(address)}')) !=
      null;

  @override
  Future<void> storeSession(
    SignalProtocolAddress address,
    SessionRecord record,
  ) async {
    final addressKey = _addressKey(address);
    await _storage.saveString(
      _key('session.$addressKey'),
      base64Encode(record.serialize()),
    );
    final entries = (await _readIndex('sessions.index'))
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .where((entry) => entry['key'] != addressKey)
        .toList();
    entries.add({
      'key': addressKey,
      'name': address.getName(),
      'deviceId': address.getDeviceId(),
    });
    await _writeIndex('sessions.index', entries);
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    final entries = (await _readIndex('sessions.index')).whereType<Map>();
    return entries
        .where((entry) => entry['name'] == name && entry['deviceId'] != 1)
        .map((entry) => entry['deviceId'] as int)
        .toList();
  }

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
    final addressKey = _addressKey(address);
    await _storage.deleteString(_key('session.$addressKey'));
    final entries = (await _readIndex('sessions.index'))
        .whereType<Map>()
        .where((entry) => entry['key'] != addressKey)
        .toList();
    await _writeIndex('sessions.index', entries);
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    final entries =
        (await _readIndex('sessions.index')).whereType<Map>().toList();
    for (final entry in entries.where((entry) => entry['name'] == name)) {
      await _storage.deleteString(_key('session.${entry['key']}'));
    }
    await _writeIndex(
      'sessions.index',
      entries.where((entry) => entry['name'] != name).toList(),
    );
  }

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final encoded = await _storage.readString(
      _key('signed-prekey.$signedPreKeyId'),
    );
    if (encoded == null) {
      throw InvalidKeyIdException(
          'No signed pre-key found for ID $signedPreKeyId');
    }
    return SignedPreKeyRecord.fromSerialized(
      Uint8List.fromList(base64Decode(encoded)),
    );
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    final ids = (await _readIndex('signed-prekeys.index')).whereType<int>();
    return Future.wait(ids.map(loadSignedPreKey));
  }

  @override
  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) async {
    await _storage.saveString(
      _key('signed-prekey.$signedPreKeyId'),
      base64Encode(record.serialize()),
    );
    final ids = (await _readIndex('signed-prekeys.index'))
        .whereType<int>()
        .toSet()
      ..add(signedPreKeyId);
    await _writeIndex('signed-prekeys.index', ids.toList());
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async =>
      await _storage.readString(_key('signed-prekey.$signedPreKeyId')) != null;

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    await _storage.deleteString(_key('signed-prekey.$signedPreKeyId'));
    final ids = (await _readIndex('signed-prekeys.index'))
        .whereType<int>()
        .where((id) => id != signedPreKeyId)
        .toList();
    await _writeIndex('signed-prekeys.index', ids);
  }
}
