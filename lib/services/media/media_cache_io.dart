import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'media_cache.dart';

class IoMediaCacheFile implements MediaCacheFile {
  IoMediaCacheFile(this.file);

  final File file;

  @override
  String get path => file.path;

  @override
  Future<bool> exists() => file.exists();

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();

  @override
  Future<int> length() => file.length();

  @override
  Future<void> writeAsBytes(List<int> bytes, {bool flush = false}) =>
      file.writeAsBytes(bytes, flush: flush);

  @override
  Future<void> delete() => file.delete();
}

Directory? _cacheDir;

Future<MediaCacheFile> getCacheFile(String mediaId, String suffix) async {
  _cacheDir ??= await getTemporaryDirectory();
  return IoMediaCacheFile(
    File(p.join(_cacheDir!.path, 'media_$mediaId.$suffix')),
  );
}
