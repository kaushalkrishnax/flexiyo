import 'dart:convert';
import 'dart:typed_data';

import 'package:flexiyo/storage/secure_keys.dart';
import 'package:uuid/uuid.dart';

class LocalConversationKeyStore {
  LocalConversationKeyStore(this._storage);

  final SecureKeyValueStore _storage;
  static const _uuid = Uuid();
  static const _installationKey = 'flexiyo.installation_id';

  String _accountPrefix(String userId) =>
      'flexiyo.v2.account.${base64UrlEncode(utf8.encode(userId))}';

  String _identityPrivateKey(String userId) =>
      '${_accountPrefix(userId)}.identity.private';
  String _identityPublicKey(String userId) =>
      '${_accountPrefix(userId)}.identity.public';
  String _deviceIdKey(String userId) => '${_accountPrefix(userId)}.device_id';
  String _conversationKeyName(String userId, String conversationId, int epoch) =>
      '${_accountPrefix(userId)}.ck.$conversationId.$epoch';

  Future<String> getOrCreateInstallationId() async {
    final existing = await _storage.readString(_installationKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final created = _uuid.v4();
    await _storage.saveString(_installationKey, created);
    return created;
  }

  Future<void> saveIdentityKeyPair({
    required String userId,
    required Uint8List privateSeed,
    required Uint8List publicKey,
  }) async {
    if (privateSeed.length != 32 || publicKey.length != 32) {
      throw ArgumentError('X25519 identity keys must be 32 bytes');
    }
    await _storage.saveString(_identityPrivateKey(userId), base64Encode(privateSeed));
    await _storage.saveString(_identityPublicKey(userId), base64Encode(publicKey));
  }

  Future<Uint8List?> readIdentityPrivateSeed(String userId) async {
    final value = await _storage.readString(_identityPrivateKey(userId));
    if (value == null) return null;
    try {
      final key = Uint8List.fromList(base64Decode(value));
      return key.length == 32 ? key : null;
    } on FormatException {
      return null;
    }
  }

  Future<String?> readIdentityPublicKey(String userId) =>
      _storage.readString(_identityPublicKey(userId));

  Future<void> saveDeviceId(String userId, int deviceId) =>
      _storage.saveString(_deviceIdKey(userId), deviceId.toString());

  Future<void> clearDeviceId(String userId) =>
      _storage.deleteString(_deviceIdKey(userId));

  Future<int?> readDeviceId(String userId) async {
    final value = await _storage.readString(_deviceIdKey(userId));
    return value == null ? null : int.tryParse(value);
  }

  Future<void> saveConversationKey({
    required String userId,
    required String conversationId,
    required int epoch,
    required Uint8List key,
  }) async {
    if (key.length != 32) throw ArgumentError('Conversation keys must be 32 bytes');
    await _storage.saveString(
      _conversationKeyName(userId, conversationId, epoch),
      base64Encode(key),
    );
  }

  Future<Uint8List?> readConversationKey({
    required String userId,
    required String conversationId,
    required int epoch,
  }) async {
    final value = await _storage.readString(
      _conversationKeyName(userId, conversationId, epoch),
    );
    if (value == null) return null;
    try {
      final key = Uint8List.fromList(base64Decode(value));
      return key.length == 32 ? key : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> savePairingPrivateSeed(String sessionId, Uint8List seed) =>
      _storage.saveString('flexiyo.v2.pairing.$sessionId', base64Encode(seed));

  Future<Uint8List?> readPairingPrivateSeed(String sessionId) async {
    final value = await _storage.readString('flexiyo.v2.pairing.$sessionId');
    if (value == null) return null;
    try {
      return Uint8List.fromList(base64Decode(value));
    } on FormatException {
      return null;
    }
  }

  Future<void> savePairingSecret(String sessionId, Uint8List secret) =>
      _storage.saveString('flexiyo.v2.pairing.secret.$sessionId', base64Encode(secret));

  Future<Uint8List?> readPairingSecret(String sessionId) async {
    final value = await _storage.readString('flexiyo.v2.pairing.secret.$sessionId');
    if (value == null) return null;
    try {
      final secret = Uint8List.fromList(base64Decode(value));
      return secret.length == 32 ? secret : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> deletePairingPrivateSeed(String sessionId) =>
      _storage.deleteString('flexiyo.v2.pairing.$sessionId');

  Future<void> deletePairingSecret(String sessionId) =>
      _storage.deleteString('flexiyo.v2.pairing.secret.$sessionId');
}
