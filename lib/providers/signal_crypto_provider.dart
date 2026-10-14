import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/services/signal_crypto_service.dart';
import 'package:flexiyo/storage/secure_keys.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final signalCryptoProvider =
    FutureProvider.family<SignalCryptoService, String>((ref, userId) {
  return SignalCryptoService.open(
    storage: ref.watch(secureKeysProvider),
    api: ref.watch(apiServiceProvider),
    userId: userId,
  );
});
