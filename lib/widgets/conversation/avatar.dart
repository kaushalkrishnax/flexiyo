import 'package:flutter/material.dart';

/// A consistent circular avatar widget that shows the first letter of [username]
/// over a deterministic background color derived from the username's hash.
///
/// No network images are used (backend does not yet expose avatar URLs).
class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, required this.username, this.radius = 24});

  final String username;
  final double radius;

  // Curated palette — vivid but not jarring in both light and dark themes.
  static const _palette = [
    Color(0xFF5C6BC0), // indigo
    Color(0xFF42A5F5), // blue
    Color(0xFF26C6DA), // cyan
    Color(0xFF26A69A), // teal
    Color(0xFF66BB6A), // green
    Color(0xFFD4E157), // lime
    Color(0xFFFFCA28), // amber
    Color(0xFFFFA726), // orange
    Color(0xFFEF5350), // red
    Color(0xFFEC407A), // pink
    Color(0xFFAB47BC), // purple
    Color(0xFF7E57C2), // deep-purple
  ];

  /// Returns a deterministic color from [_palette] based on [username].
  Color _colorFor(String name) {
    final hash = name.isEmpty ? 0 : name.codeUnits.fold(0, (h, c) => h ^ c);
    return _palette[hash.abs() % _palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final initial = username.isNotEmpty ? username[0].toUpperCase() : '?';
    final bg = _colorFor(username);

    return CircleAvatar(
      radius: radius,
      backgroundColor: bg,
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * 0.75,
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
  }
}
