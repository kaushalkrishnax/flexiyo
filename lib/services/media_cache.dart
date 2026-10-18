import 'dart:typed_data';

export 'media_cache_io.dart' if (dart.library.html) 'media_cache_web.dart';

abstract class MediaCacheFile {
  String get path;

  Future<bool> exists();

  Future<Uint8List> readAsBytes();

  Future<int> length();

  Future<void> writeAsBytes(List<int> bytes, {bool flush = false});

  Future<void> delete();
}
