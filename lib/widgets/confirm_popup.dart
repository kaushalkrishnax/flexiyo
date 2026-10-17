import 'package:flutter/material.dart';

/// Shared two-action confirmation popup used across the app (logout,
/// discarding a camera photo, etc.).
///
/// Layout: a title, a short explanation, then a destructive/confirm action on
/// top and a safe action below, split by hairline dividers. It is a touch
/// narrower than the 280px minimum of a plain [Dialog] so it reads as a
/// compact warning rather than a full-width alert.
class ConfirmPopup extends StatelessWidget {
  const ConfirmPopup({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    this.destructive = true,
  });

  /// Default width shared by every confirmation popup in the app.
  static const double width = 260;

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;

  /// When true the confirm action is painted in the warning color.
  final bool destructive;

  /// Shows the popup and resolves to true when the confirm action is picked
  /// or false on cancel/dismiss.
  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    required String cancelLabel,
    bool destructive = true,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmPopup(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        destructive: destructive,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF2A2C31) : Colors.white;
    final titleColor = isDark ? Colors.white : Colors.black87;
    final bodyColor = isDark ? Colors.white70 : Colors.black54;
    final dividerColor = isDark ? Colors.white12 : const Color(0x1F000000);

    return Dialog(
      backgroundColor: surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      constraints: const BoxConstraints(maxWidth: width),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
            child: Column(
              children: [
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: bodyColor,
                    fontSize: 14,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          Container(height: 0.5, color: dividerColor),
          InkWell(
            onTap: () => Navigator.of(context).pop(true),
            child: SizedBox(
              width: double.infinity,
              height: 50,
              child: Center(
                child: Text(
                  confirmLabel,
                  style: TextStyle(
                    color: destructive ? const Color(0xFFFF2E63) : titleColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          Container(height: 0.5, color: dividerColor),
          InkWell(
            onTap: () => Navigator.of(context).pop(false),
            child: SizedBox(
              width: double.infinity,
              height: 50,
              child: Center(
                child: Text(
                  cancelLabel,
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
