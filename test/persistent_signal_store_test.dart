import 'dart:convert';
import 'dart:typed_data';

import 'package:flexiyo/services/persistent_signal_store.dart';
import 'package:flexiyo/storage/secure_keys.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

void main() {
  test('Signal sessions continue after secure stores are reopened', () async {
    final aliceStorage = _MemorySecureStore();
    final bobStorage = _MemorySecureStore();
    var alice = await PersistentSignalStore.open(
      storage: aliceStorage,
      userId: 'alice',
    );
    var bob = await PersistentSignalStore.open(
      storage: bobStorage,
      userId: 'bob',
    );

    final bobPreKey = generatePreKeys(1, 1).single;
    final bobSignedPreKey = generateSignedPreKey(bob.identityKeyPair, 1);
    await bob.storePreKey(bobPreKey.id, bobPreKey);
    await bob.storeSignedPreKey(bobSignedPreKey.id, bobSignedPreKey);

    final bundle = PreKeyBundle(
      bob.registrationId,
      1,
      bobPreKey.id,
      bobPreKey.getKeyPair().publicKey,
      bobSignedPreKey.id,
      bobSignedPreKey.getKeyPair().publicKey,
      bobSignedPreKey.signature,
      bob.identityKey,
    );
    const bobAddress = SignalProtocolAddress('bob', 1);
    const aliceAddress = SignalProtocolAddress('alice', 1);

    await SessionBuilder.fromSignalStore(alice, bobAddress)
        .processPreKeyBundle(bundle);
    final firstCiphertext = await SessionCipher.fromStore(alice, bobAddress)
        .encrypt(Uint8List.fromList(utf8.encode('first message')));
    expect(firstCiphertext.getType(), CiphertextMessage.prekeyType);

    final firstPlaintext = await SessionCipher.fromStore(bob, aliceAddress)
        .decrypt(PreKeySignalMessage(firstCiphertext.serialize()));
    expect(utf8.decode(firstPlaintext), 'first message');

    alice = await PersistentSignalStore.open(
      storage: aliceStorage,
      userId: 'alice',
    );
    bob = await PersistentSignalStore.open(
      storage: bobStorage,
      userId: 'bob',
    );

    final secondCiphertext = await SessionCipher.fromStore(alice, bobAddress)
        .encrypt(Uint8List.fromList(utf8.encode('continued session')));
    expect(secondCiphertext.getType(), CiphertextMessage.prekeyType);

    final secondPlaintext = await SessionCipher.fromStore(bob, aliceAddress)
        .decrypt(PreKeySignalMessage(secondCiphertext.serialize()));
    expect(utf8.decode(secondPlaintext), 'continued session');

    final reply = await SessionCipher.fromStore(bob, aliceAddress)
        .encrypt(Uint8List.fromList(utf8.encode('reply')));
    await SessionCipher.fromStore(alice, bobAddress)
        .decryptFromSignal(SignalMessage.fromSerialized(reply.serialize()));

    final thirdCiphertext = await SessionCipher.fromStore(alice, bobAddress)
        .encrypt(Uint8List.fromList(utf8.encode('ratchet continued')));
    expect(thirdCiphertext.getType(), CiphertextMessage.whisperType);
    final thirdPlaintext = await SessionCipher.fromStore(bob, aliceAddress)
        .decryptFromSignal(
            SignalMessage.fromSerialized(thirdCiphertext.serialize()));
    expect(utf8.decode(thirdPlaintext), 'ratchet continued');
  });
}

class _MemorySecureStore implements SecureKeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<void> saveString(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<String?> readString(String key) async => values[key];

  @override
  Future<void> deleteString(String key) async {
    values.remove(key);
  }
}
