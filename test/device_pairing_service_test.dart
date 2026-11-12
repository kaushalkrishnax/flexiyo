import 'package:cryptography/cryptography.dart';
import 'package:flexiyo/core/exceptions.dart';
import 'package:flexiyo/models/conversation.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/services/conversation_crypto_service.dart';
import 'package:flexiyo/services/device_pairing_service.dart';
import 'package:flexiyo/storage/local_conversation_key_store.dart';
import 'package:flexiyo/storage/secure_keys.dart';
import 'package:flutter_test/flutter_test.dart';

const _userId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _sessionId = '11111111-1111-4111-8111-111111111111';

class _MemorySecureStore implements SecureKeyValueStore {
  final Map<String, String> _values = {};

  @override
  Future<void> saveString(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<String?> readString(String key) async => _values[key];

  @override
  Future<void> deleteString(String key) async {
    _values.remove(key);
  }
}

/// In-memory stand-in for the pairing endpoints. Real key wrapping still runs
/// in [DevicePairingService], so the proof is verified with actual X25519 and
/// XChaCha20-Poly1305 operations.
class _FakePairingApi extends ApiService {
  _FakePairingApi() : super(SecureKeys.instance);

  Map<String, dynamic>? session;
  Map<String, dynamic>? lastJoin;
  int approveCalls = 0;

  @override
  Future<Map<String, dynamic>> createPairingSession(
    String initiatorEphemeralPublic,
  ) async {
    final expiresAt =
        DateTime.now().add(const Duration(minutes: 3)).millisecondsSinceEpoch ~/
            1000;
    session = {
      'sessionId': _sessionId,
      'status': 'pending',
      'expiresAt': expiresAt,
    };
    return {
      'sessionId': _sessionId,
      'initiatorEphemeralPublic': initiatorEphemeralPublic,
      'expiresAt': expiresAt,
    };
  }

  @override
  Future<Map<String, dynamic>> joinPairingSession({
    required String sessionId,
    required String installationId,
    required String identityPublicKey,
    required String joinedEphemeralPublic,
    required String nonce,
    required String ciphertext,
    required String mac,
  }) async {
    lastJoin = {
      'sessionId': sessionId,
      'installationId': installationId,
      'identityPublicKey': identityPublicKey,
      'joinedEphemeralPublic': joinedEphemeralPublic,
      'nonce': nonce,
      'ciphertext': ciphertext,
      'mac': mac,
    };
    session = {
      ...?session,
      'status': 'joined',
      'joinedInstallationId': installationId,
      'joinedIdentityPublic': identityPublicKey,
      'joinedEphemeralPublic': joinedEphemeralPublic,
      'joinedNonce': nonce,
      'joinedCiphertext': ciphertext,
      'joinedMac': mac,
    };
    return {'joined': true, 'sessionId': sessionId};
  }

  @override
  Future<Map<String, dynamic>> getPairingSession(String sessionId) async {
    final current = session;
    if (current == null) {
      throw const NotFoundException('Pairing session not found');
    }
    return Map<String, dynamic>.from(current);
  }

  @override
  Future<Map<String, dynamic>> approvePairingSession(String sessionId) async {
    approveCalls += 1;
    session = {...?session, 'status': 'approved', 'deviceId': 77};
    return {'approved': true, 'deviceId': 77};
  }

  @override
  Future<void> cancelPairingSession(String sessionId) async {
    session = {...?session, 'status': 'cancelled'};
  }

  @override
  Future<List<Conversation>> getConversations({String scope = 'inbox'}) async {
    return const [
      Conversation(
        id: 'conversation-1',
        otherUserId: 'bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb',
        otherUsername: 'bob',
        disappearingTimer: 0,
      ),
    ];
  }
}

class _FakeCrypto extends ConversationCryptoService {
  _FakeCrypto(ApiService api, LocalConversationKeyStore store)
      : super(api: api, store: store);

  final List<String> provisioned = [];

  @override
  Future<int> ensureDeviceRegistered({required String userId}) async => 77;

  @override
  Future<void> provisionCurrentEpochForDevice({
    required String conversationId,
    required String myUserId,
    required String peerUserId,
    required int newDeviceId,
    required String newIdentityPublicKey,
  }) async {
    provisioned.add('$conversationId:$newDeviceId');
  }
}

void main() {
  test('QR pairing exchanges a verifiable proof and provisions keys', () async {
    final api = _FakePairingApi();
    final initiatorStore = LocalConversationKeyStore(_MemorySecureStore());
    final joiningStore = LocalConversationKeyStore(_MemorySecureStore());
    final initiatorCrypto = _FakeCrypto(api, initiatorStore);
    final joiningCrypto = _FakeCrypto(api, joiningStore);

    final initiator = DevicePairingService(
      api: api,
      store: initiatorStore,
      crypto: initiatorCrypto,
    );
    final joining = DevicePairingService(
      api: api,
      store: joiningStore,
      crypto: joiningCrypto,
    );

    final payload = await initiator.createQrSession(userId: _userId);
    final pairingSecret = payload['pairingSecret'] as String;
    expect(pairingSecret, isNotEmpty);
    expect(await initiatorStore.readPairingSecret(_sessionId), isNotNull);

    await joining.joinQrSession(payload, userId: _userId);

    // The joining device never persists or uploads the QR secret.
    expect(api.lastJoin, isNotNull);
    expect(api.lastJoin!.containsKey('pairingSecret'), isFalse);
    expect(api.lastJoin!.values, isNot(contains(pairingSecret)));
    expect(await joiningStore.readPairingSecret(_sessionId), isNull);

    expect(await initiator.verifyJoinedDevice(_sessionId), isTrue);

    final deviceId = await initiator.approveJoinedDevice(
      _sessionId,
      myUserId: _userId,
    );
    expect(deviceId, 77);
    expect(api.approveCalls, 1);
    expect(initiatorCrypto.provisioned, ['conversation-1:77']);

    // One-time secrets are cleared once provisioning succeeds.
    expect(await initiatorStore.readPairingSecret(_sessionId), isNull);
    expect(await initiatorStore.readPairingPrivateSeed(_sessionId), isNull);

    await joining.acceptApproval(_sessionId, userId: _userId);
    expect(await joiningStore.readDeviceId(_userId), 77);
  });

  test('a tampered joining proof is rejected', () async {
    final api = _FakePairingApi();
    final initiatorStore = LocalConversationKeyStore(_MemorySecureStore());
    final joiningStore = LocalConversationKeyStore(_MemorySecureStore());
    final initiator = DevicePairingService(
      api: api,
      store: initiatorStore,
      crypto: _FakeCrypto(api, initiatorStore),
    );
    final joining = DevicePairingService(
      api: api,
      store: joiningStore,
      crypto: _FakeCrypto(api, joiningStore),
    );

    final payload = await initiator.createQrSession(userId: _userId);
    await joining.joinQrSession(payload, userId: _userId);

    final ciphertext = api.session!['joinedCiphertext'] as String;
    api.session!['joinedCiphertext'] =
        '${ciphertext[0] == 'A' ? 'B' : 'A'}${ciphertext.substring(1)}';

    expect(
      () => initiator.verifyJoinedDevice(_sessionId),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('an invalid QR payload is rejected before contacting the server', () async {
    final api = _FakePairingApi();
    final joiningStore = LocalConversationKeyStore(_MemorySecureStore());
    final joining = DevicePairingService(
      api: api,
      store: joiningStore,
      crypto: _FakeCrypto(api, joiningStore),
    );

    await expectLater(
      joining.joinQrSession({
        'type': 'flexiyo-pairing-v2',
        'sessionId': _sessionId,
        'initiatorEphemeralPublic': 'invalid',
        'pairingSecret': 'invalid',
      }, userId: _userId),
      throwsA(isA<FormatException>()),
    );
    expect(api.lastJoin, isNull);
  });
}
