import 'dart:typed_data';

import 'media_cache.dart';

/// In-memory cache for web. path_provider has no web implementation, so
/// decrypted plaintext is kept in a process-lifetime map instead of files.
final Map<String, Uint8List> _store = {};

class WebMediaCacheFile implements MediaCacheFile {
  WebMediaCacheFile(this._key);

  final String _key;

  @override
  String get path => 'web://$_key';

  @override
  Future<bool> exists() async => _store.containsKey(_key);

  @override
  Future<Uint8List> readAsBytes() async =>
      Uint8List.fromList(_store[_key] ?? const <int>[]);

  @override
  Future<int> length() async => _store[_key]?.length ?? 0;

  @override
  Future<void> writeAsBytes(List<int> bytes, {bool flush = false}) async {
    _store[_key] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete() async => _store.remove(_key);
}

Future<MediaCacheFile> getCacheFile(String mediaId, String suffix) async {
  return WebMediaCacheFile('media_$mediaId.$suffix');
}
