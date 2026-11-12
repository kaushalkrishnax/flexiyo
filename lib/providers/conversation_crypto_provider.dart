
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/services/conversation_crypto_service.dart';
import 'package:flexiyo/services/device_pairing_service.dart';
import 'package:flexiyo/storage/local_conversation_key_store.dart';
import 'package:flexiyo/storage/secure_keys.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final localConversationKeyStoreProvider =
    Provider<LocalConversationKeyStore>((ref) {
  return LocalConversationKeyStore(ref.watch(secureKeysProvider));
});

final conversationCryptoProvider =
    Provider<ConversationCryptoService>((ref) {
  return ConversationCryptoService(
    api: ref.watch(apiServiceProvider),
    store: ref.watch(localConversationKeyStoreProvider),
  );
});

final devicePairingProvider = Provider<DevicePairingService>((ref) {
  return DevicePairingService(
    api: ref.watch(apiServiceProvider),
    store: ref.watch(localConversationKeyStoreProvider),
    crypto: ref.watch(conversationCryptoProvider),
  );
});
