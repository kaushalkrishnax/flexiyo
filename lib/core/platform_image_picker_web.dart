import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Opens the browser's file chooser and resolves with the chosen image bytes,
/// or null if the user cancels or the file can't be read.
Future<Uint8List?> pickImageBytes() {
  final completer = Completer<Uint8List?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = 'image/*';
  input.style.display = 'none';
  web.document.body?.append(input);

  void finish(Uint8List? bytes) {
    if (completer.isCompleted) return;
    input.remove();
    completer.complete(bytes);
  }

  // The handler must be synchronous: a function converted with `toJS` cannot
  // return a Future, so the async read is chained here instead.
  input.addEventListener(
    'change',
    ((web.Event _) {
      final files = input.files;
      if (files == null || files.length == 0) {
        finish(null);
        return;
      }
      final file = files.item(0)!;
      file.arrayBuffer().toDart.then(
            (buffer) => finish(buffer.toDart.asUint8List()),
            onError: (_) => finish(null),
          );
    }).toJS,
  );
  input.addEventListener('cancel', ((web.Event _) => finish(null)).toJS);

  input.click();
  return completer.future;
}
