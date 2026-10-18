import 'dart:typed_data';

/// The in-app gallery sheet handles native picks; the browser file chooser is
/// web-only.
Future<Uint8List?> pickImageBytes() =>
    throw UnsupportedError('pickImageBytes() is web-only');
