import 'dart:typed_data';

/// The in-app gallery sheet and camera handle native picks; the browser file
/// chooser is web-only.
Future<Uint8List?> pickImageBytes({bool fromCamera = false}) =>
    throw UnsupportedError('pickImageBytes() is web-only');
