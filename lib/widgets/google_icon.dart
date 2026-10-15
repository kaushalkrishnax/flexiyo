import 'package:flutter/material.dart';

/// Pixel-perfect 4-color Google G icon matching official brand guidelines.
class GoogleIcon extends StatelessWidget {
  const GoogleIcon({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _GoogleIconPainter(),
    );
  }
}

class _GoogleIconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24.0;
    canvas.save();
    canvas.scale(scale, scale);

    // Blue
    final bluePaint = Paint()..color = const Color(0xFF4285F4);
    final bluePath = Path()
      ..moveTo(23.745, 12.27)
      ..cubicTo(23.745, 11.48, 23.674, 10.73, 23.543, 10.01)
      ..lineTo(12.0, 10.01)
      ..lineTo(12.0, 14.77)
      ..lineTo(18.583, 14.77)
      ..cubicTo(18.3, 16.31, 17.43, 17.62, 16.124, 18.5)
      ..lineTo(16.124, 21.62)
      ..lineTo(20.095, 21.62)
      ..cubicTo(22.418, 19.48, 23.745, 16.17, 23.745, 12.27)
      ..close();
    canvas.drawPath(bluePath, bluePaint);

    // Green
    final greenPaint = Paint()..color = const Color(0xFF34A853);
    final greenPath = Path()
      ..moveTo(12.0, 24.0)
      ..cubicTo(15.24, 24.0, 17.96, 22.92, 20.095, 21.62)
      ..lineTo(16.124, 18.5)
      ..cubicTo(15.02, 19.24, 13.62, 19.68, 12.0, 19.68)
      ..cubicTo(8.87, 19.68, 6.22, 17.57, 5.27, 14.71)
      ..lineTo(1.17, 14.71)
      ..lineTo(1.17, 17.89)
      ..cubicTo(3.19, 21.9, 7.33, 24.0, 12.0, 24.0)
      ..close();
    canvas.drawPath(greenPath, greenPaint);

    // Yellow
    final yellowPaint = Paint()..color = const Color(0xFFFBBC05);
    final yellowPath = Path()
      ..moveTo(5.27, 14.71)
      ..cubicTo(5.03, 13.99, 4.9, 13.22, 4.9, 12.0)
      ..cubicTo(4.9, 10.78, 5.03, 10.01, 5.27, 9.29)
      ..lineTo(5.27, 6.11)
      ..lineTo(1.17, 6.11)
      ..cubicTo(0.42, 7.6, 0.0, 9.71, 0.0, 12.0)
      ..cubicTo(0.0, 14.29, 0.42, 16.4, 1.17, 17.89)
      ..lineTo(5.27, 14.71)
      ..close();
    canvas.drawPath(yellowPath, yellowPaint);

    // Red
    final redPaint = Paint()..color = const Color(0xFFEA4335);
    final redPath = Path()
      ..moveTo(12.0, 4.32)
      ..cubicTo(13.76, 4.32, 15.34, 4.93, 16.59, 6.12)
      ..lineTo(20.19, 2.52)
      ..cubicTo(17.95, 0.44, 15.24, 0.0, 12.0, 0.0)
      ..cubicTo(7.33, 0.0, 3.19, 2.1, 1.17, 6.11)
      ..lineTo(5.27, 9.29)
      ..cubicTo(6.22, 6.43, 8.87, 4.32, 12.0, 4.32)
      ..close();
    canvas.drawPath(redPath, redPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

