import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Path for a new voice recording. Native writes to a temp file.
Future<String> newVoiceRecordingPath() async {
  final dir = await getTemporaryDirectory();
  return p.join(dir.path, 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a');
}

Future<Uint8List> readAudioBytes(String path) => File(path).readAsBytes();

Future<void> deleteAudioFile(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } catch (_) {}
}
