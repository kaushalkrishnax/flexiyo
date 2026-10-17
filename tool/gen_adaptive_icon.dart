import 'dart:io';

import 'package:image/image.dart' as img;

/// Rebuilds the Android adaptive-icon foreground from [source].
///
/// Adaptive layers live on a 108dp canvas, but launcher masks only expose the
/// centre 72dp. The artwork is scaled to exactly that visible region so masks
/// crop it cleanly instead of zooming into a full-bleed square.
void main() {
  const sourcePath = 'assets/images/app_icon.png';
  final source = img.decodeImage(File(sourcePath).readAsBytesSync());
  if (source == null) {
    stderr.writeln('Cannot decode $sourcePath');
    exit(1);
  }

  const densities = <String, double>{
    'mdpi': 1,
    'hdpi': 1.5,
    'xhdpi': 2,
    'xxhdpi': 3,
    'xxxhdpi': 4,
  };

  for (final entry in densities.entries) {
    final canvasSize = (108 * entry.value).round();
    final artSize = (72 * entry.value).round();
    final canvas = img.Image(
      width: canvasSize,
      height: canvasSize,
      numChannels: 4,
    );
    img.fill(canvas, color: img.ColorRgba8(0, 0, 0, 0));

    final artwork = img.copyResize(
      source,
      width: artSize,
      height: artSize,
      interpolation: img.Interpolation.cubic,
    );
    final inset = ((canvasSize - artSize) / 2).round();
    img.compositeImage(canvas, artwork, dstX: inset, dstY: inset);

    final target = File(
      'android/app/src/main/res/drawable-${entry.key}/flexiyo_launcher_foreground.png',
    );
    target.parent.createSync(recursive: true);
    target.writeAsBytesSync(img.encodePng(canvas));
    stdout.writeln('wrote ${target.path} ($canvasSize x $canvasSize)');
  }
}
