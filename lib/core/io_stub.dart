// Web stub for dart:io types. Only the shape needed by the app's mobile-only
// code paths is provided; those paths are guarded by `kIsWeb` at runtime.
import 'dart:typed_data';

class File {
  File(String path);

  String get path => '';

  Future<Uint8List> readAsBytes() async => Uint8List(0);

  Future<void> writeAsBytes(List<int> bytes, {bool flush = false}) async {}

  Future<void> delete() async {}

  Future<bool> exists() async => false;

  Future<int> length() async => 0;
}

class Directory {
  Directory(String path);

  String get path => '';

  Future<Directory> create({bool recursive = false}) async => this;

  Future<bool> exists() async => false;
}
