import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flexiyo/core/constants.dart';
import 'package:flexiyo/storage/secure_keys.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum ViewPolicy { once, twice, unlimited }

extension ViewPolicyExt on ViewPolicy {
  String get value => const ['once', 'twice', 'unlimited'][index];

  String get label {
    switch (this) {
      case ViewPolicy.once:
        return 'View once';
      case ViewPolicy.twice:
        return 'View twice';
      case ViewPolicy.unlimited:
        return 'Unlimited views';
    }
  }

  static ViewPolicy fromString(String? v) {
    switch (v) {
      case 'once':
        return ViewPolicy.once;
      case 'twice':
        return ViewPolicy.twice;
      default:
        return ViewPolicy.unlimited;
    }
  }
}

enum MediaKind { image, voice }

extension MediaKindExt on MediaKind {
  String get value => this == MediaKind.image ? 'image' : 'voice';

  static MediaKind fromString(String? v) =>
      v == 'voice' ? MediaKind.voice : MediaKind.image;
}

/// E2EE envelope embedded in the message text: `FYMEDIA:{"v":1,"k":..,"n":..,"mac":..,"id":..}`.
/// Carries only AES-256-GCM key material and metadata — the ciphertext lives in R2.
class MediaRef {
  MediaRef({
    required this.id,
    required this.kind,
    required this.policy,
    required this.key,
    required this.nonce,
    required this.mac,
    this.durationMs,
    this.size,
  });

  static const mediaPrefix = 'FYMEDIA:';
  static const currentVersion = 1;

  final String id;
  final MediaKind kind;
  final ViewPolicy policy;
  final Uint8List key;
  final Uint8List nonce;
  final Uint8List mac;
  final int? durationMs;
  final int? size;

  String get label => kind == MediaKind.voice ? '🎤 Voice note' : '📷 Photo';

  Map<String, dynamic> toJson() => {
        'v': currentVersion,
        'k': base64Url.encode(key),
        'n': base64Url.encode(nonce),
        'mac': base64Url.encode(mac),
        'id': id,
        'kind': kind.value,
        'p': policy.value,
        if (durationMs != null) 'd': durationMs,
        if (size != null) 's': size,
      };

  String toEnvelopeString() => '$mediaPrefix${jsonEncode(toJson())}';

  static MediaRef? parse(String text) {
    if (!text.startsWith(mediaPrefix)) return null;
    try {
      final json = jsonDecode(text.substring(mediaPrefix.length))
          as Map<String, dynamic>;
      final key = base64Url.decode(json['k'] as String);
      final nonce = base64Url.decode(json['n'] as String);
      final mac = base64Url.decode(json['mac'] as String);
      if (key.length != 32 || nonce.length != 12 || mac.length != 16) {
        return null;
      }
      return MediaRef(
        id: json['id'] as String,
        kind: MediaKindExt.fromString(json['kind'] as String?),
        policy: ViewPolicyExt.fromString(json['p'] as String?),
        key: Uint8List.fromList(key),
        nonce: Uint8List.fromList(nonce),
        mac: Uint8List.fromList(mac),
        durationMs: json['d'] as int?,
        size: json['s'] as int?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// AES-256-GCM media encryption + upload/download through the Worker; the
/// server stores and serves only ciphertext.
class MediaService {
  MediaService(this._secureKeys);

  /// Matches the Worker-side cap in functions/src/routes/media.ts.
  static const int maxUploadBytes = 25 * 1024 * 1024;

  final SecureKeys _secureKeys;

  Directory? _cacheDir;

  Future<Directory> get _cacheDirFuture async =>
      _cacheDir ??= await getTemporaryDirectory();

  Future<File> _cacheFile(String mediaId, String suffix) async {
    final dir = await _cacheDirFuture;
    return File(p.join(dir.path, 'media_$mediaId.$suffix'));
  }

  /// Encrypts [plaintext] with a fresh random AES-256 key; returns the key,
  /// nonce and the ciphertext‖tag blob (nonce travels in the envelope).
  static Future<({Uint8List key, Uint8List nonce, Uint8List ctMac})>
      encryptBytes(Uint8List plaintext) async {
    final algorithm = AesGcm.with256bits();
    final secretKey = await algorithm.newSecretKey();
    final nonce = algorithm.newNonce();
    final box = await algorithm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
    );
    final keyBytes = Uint8List.fromList(await secretKey.extractBytes());
    final ctMac = Uint8List.fromList(
      box.concatenation(nonce: false, mac: true),
    );
    return (key: keyBytes, nonce: Uint8List.fromList(nonce), ctMac: ctMac);
  }

  static Future<Uint8List> decryptBytes(
    Uint8List ctMac, {
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List mac,
  }) async {
    final algorithm = AesGcm.with256bits();
    final secretKey = SecretKey(key);
    final ciphertext = ctMac.sublist(0, ctMac.length - mac.length);
    final box = SecretBox(ciphertext, nonce: nonce, mac: Mac(mac));
    final clear = await algorithm.decrypt(box, secretKey: secretKey);
    return Uint8List.fromList(clear);
  }

  Future<MediaRef> encryptAndUpload({
    required Uint8List bytes,
    required String conversationId,
    required MediaKind kind,
    required ViewPolicy policy,
    int? durationMs,
  }) async {
    if (bytes.isEmpty) throw Exception('Nothing to send');
    if (bytes.length > maxUploadBytes) {
      throw Exception('Media exceeds the 25 MB limit');
    }
    final token = await _secureKeys.getJwt();
    if (token == null) throw Exception('Not authenticated');

    final enc = await encryptBytes(bytes);

    final url = Uri.parse('${AppConstants.apiBaseUrl}/api/media').replace(
      queryParameters: {
        'conversationId': conversationId,
        'kind': kind.value,
        'viewPolicy': policy.value,
        if (durationMs != null) 'durationMs': '$durationMs',
      },
    );

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 2),
      sendTimeout: const Duration(minutes: 2),
      headers: {'Authorization': 'Bearer $token'},
    ));
    String mediaId;
    try {
      final response = await dio.post<dynamic>(
        url.toString(),
        data: enc.ctMac,
        options: Options(
          contentType: 'application/octet-stream',
          headers: {'Content-Type': 'application/octet-stream'},
        ),
      );
      final data = response.data;
      final serverId = data is Map ? data['id'] : null;
      if (serverId is! String || serverId.isEmpty) {
        throw Exception('Media upload failed');
      }
      // The Worker allocates the id that fetches and unsends look media up
      // by; carrying a client-side id in the envelope would 404 on receipt.
      mediaId = serverId;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final message = e.response?.data is Map
          ? (e.response!.data as Map)['error']?.toString()
          : null;
      if (status == 413) throw Exception(message ?? 'File too large');
      if (status == 429) {
        throw Exception(message ?? 'Daily upload limit reached');
      }
      throw Exception(message ?? 'Media upload failed');
    }

    final ref = MediaRef(
      id: mediaId,
      kind: kind,
      policy: policy,
      key: enc.key,
      nonce: enc.nonce,
      mac: enc.ctMac.sublist(enc.ctMac.length - 16),
      durationMs: durationMs,
      size: bytes.length,
    );

    // Pre-seed the sender cache so their own bubble renders without a fetch.
    try {
      final cache =
          await _cacheFile(mediaId, kind == MediaKind.voice ? 'm4a' : 'img');
      await cache.writeAsBytes(bytes, flush: true);
    } catch (_) {}
    return ref;
  }

  /// Fetches, decrypts and (optionally) caches media. Pass `storeCache: false`
  /// for view-limited recipient media — decrypted bytes must not persist.
  Future<Uint8List> fetchAndDecrypt(
    MediaRef ref, {
    bool useCache = true,
    bool storeCache = true,
  }) async {
    final suffix = ref.kind == MediaKind.voice ? 'm4a' : 'img';
    final cache = await _cacheFile(ref.id, suffix);
    if (useCache && await cache.exists()) {
      final cached = await cache.readAsBytes();
      if (cached.isNotEmpty) return cached;
    }

    final token = await _secureKeys.getJwt();
    if (token == null) throw Exception('Not authenticated');

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 2),
      headers: {'Authorization': 'Bearer $token'},
      responseType: ResponseType.bytes,
    ));

    List<int> raw;
    try {
      final resp = await dio.get<dynamic>(
        '${AppConstants.apiBaseUrl}/api/media/${ref.id}',
      );
      final data = resp.data;
      raw = data is Uint8List ? data : Uint8List.fromList(data as List<int>);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 410) throw MediaExpiredException();
      if (status == 429) throw Exception('Daily download limit reached');
      rethrow;
    }

    final plaintext = await decryptBytes(
      Uint8List.fromList(raw),
      key: ref.key,
      nonce: ref.nonce,
      mac: ref.mac,
    );

    try {
      if (storeCache) {
        await cache.writeAsBytes(plaintext, flush: true);
      } else if (await cache.exists()) {
        await cache.delete();
      }
    } catch (_) {}
    return plaintext;
  }

  /// Cached plaintext bytes, if any; never touches the network.
  Future<Uint8List?> cachedBytes(MediaRef ref) async {
    final suffix = ref.kind == MediaKind.voice ? 'm4a' : 'img';
    final cache = await _cacheFile(ref.id, suffix);
    if (!await cache.exists()) return null;
    final bytes = await cache.readAsBytes();
    return bytes.isEmpty ? null : bytes;
  }

  /// Decrypted file on disk for players that need a path; fetches if missing.
  Future<File> ensureCachedFile(MediaRef ref) async {
    final suffix = ref.kind == MediaKind.voice ? 'm4a' : 'img';
    final cache = await _cacheFile(ref.id, suffix);
    if (await cache.exists() && await cache.length() > 0) return cache;
    await fetchAndDecrypt(ref, useCache: false);
    return cache;
  }
}

/// Thrown when the server reports the view quota is exhausted (HTTP 410).
class MediaExpiredException implements Exception {
  @override
  String toString() => 'This media is no longer available';
}

final mediaServiceProvider = Provider<MediaService>((ref) {
  return MediaService(ref.watch(secureKeysProvider));
});
