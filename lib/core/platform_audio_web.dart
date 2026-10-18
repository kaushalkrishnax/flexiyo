import 'dart:typed_data';

import 'package:dio/dio.dart';

/// On web the recorder produces an in-memory blob; the returned value is a
/// synthetic name and the real location arrives from `stop()` as a blob URL.
Future<String> newVoiceRecordingPath() async =>
    'voice_${DateTime.now().millisecondsSinceEpoch}.wav';

/// Reads a recorded blob URL into memory.
Future<Uint8List> readAudioBytes(String path) async {
  final response = await Dio().get<dynamic>(
    path,
    options: Options(responseType: ResponseType.bytes),
  );
  final data = response.data;
  if (data is Uint8List) return data;
  if (data is List<int>) return Uint8List.fromList(data);
  if (data is ByteBuffer) return Uint8List.view(data);
  return Uint8List(0);
}

Future<void> deleteAudioFile(String path) async {
  // Blob URLs are reclaimed by the browser; nothing to delete.
}
