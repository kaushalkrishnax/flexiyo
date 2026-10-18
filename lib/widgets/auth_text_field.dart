import 'package:flexiyo/core/theme.dart';
import 'package:flutter/material.dart';

enum AuthTextFieldLabelType {
  floating,
  none,
}

/// Unified clean text field with flexible flavors:
/// - `labelType: AuthTextFieldLabelType.floating`: smoothly animated floating label (used in auth/profile).
/// - `labelType: AuthTextFieldLabelType.none`: clean inline input with hint and optional leading/trailing (used in search/inputs).
/// - `leading`: Left-aligned icon or action.
/// - `trailing`: Right-aligned icon or action (password visibility, clear icon, checkmark, etc.).
class AuthTextField extends StatefulWidget {
  const AuthTextField({
    super.key,
    this.label = '',
    this.hintText,
    required this.controller,
    this.labelType = AuthTextFieldLabelType.floating,
    this.leading,
    this.trailing,
    this.height,
    this.borderRadius,
    this.boxColor,
    this.borderColor,
    this.obscureText = false,
    this.textInputAction = TextInputAction.next,
    this.keyboardType = TextInputType.text,
    this.autofocus = false,
    this.hasError = false,
    this.isAvailable = false,
    this.onSubmitted,
    this.onChanged,
    this.focusNode,
  });

  final String label;
  final String? hintText;
  final TextEditingController controller;
  final AuthTextFieldLabelType labelType;
  final Widget? leading;
  final Widget? trailing;
  final double? height;
  final BorderRadius? borderRadius;
  final Color? boxColor;
  final Color? borderColor;
  final bool obscureText;
  final TextInputAction textInputAction;
  final TextInputType keyboardType;
  final bool autofocus;
  final bool hasError;
  final bool isAvailable;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;

  @override
  State<AuthTextField> createState() => _AuthTextFieldState();
}

/// Alias for general app usage outside auth
typedef AppTextField = AuthTextField;

class _AuthTextFieldState extends State<AuthTextField> {
  late FocusNode _focusNode;
  bool _ownsFocusNode = false;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode != null) {
      _focusNode = widget.focusNode!;
    } else {
      _focusNode = FocusNode();
      _ownsFocusNode = true;
    }
    _focusNode.addListener(_handleStateChange);
    widget.controller.addListener(_handleStateChange);
  }

  @override
  void didUpdateWidget(covariant AuthTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleStateChange);
      widget.controller.addListener(_handleStateChange);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      if (_ownsFocusNode) {
        _focusNode.removeListener(_handleStateChange);
        _focusNode.dispose();
      } else {
        oldWidget.focusNode?.removeListener(_handleStateChange);
      }
      if (widget.focusNode != null) {
        _focusNode = widget.focusNode!;
        _ownsFocusNode = false;
      } else {
        _focusNode = FocusNode();
        _ownsFocusNode = true;
      }
      _focusNode.addListener(_handleStateChange);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleStateChange);
    _focusNode.removeListener(_handleStateChange);
    if (_ownsFocusNode) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _handleStateChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isFloating = _focusNode.hasFocus || widget.controller.text.isNotEmpty;
    final isFocused = _focusNode.hasFocus;

    Color effectiveBorderColor;
    if (widget.borderColor != null) {
      effectiveBorderColor = widget.borderColor!;
    } else if (widget.hasError) {
      effectiveBorderColor = const Color(0xFFED4956);
    } else if (widget.isAvailable) {
      effectiveBorderColor = const Color(0xFF22C55E);
    } else if (isFocused) {
      effectiveBorderColor = isDark
          ? Colors.white.withValues(alpha: 0.38)
          : Colors.black.withValues(alpha: 0.38);
    } else {
      effectiveBorderColor =
          isDark ? AppTheme.borderDefault : const Color(0xFFDBDBDB);
    }

    final effectiveBoxColor = widget.boxColor ??
        (isDark ? AppTheme.bgDarkSurface : const Color(0xFFFAFAFA));

    final effectiveRadius = widget.borderRadius ?? BorderRadius.circular(14);
    final textColor = isDark ? Colors.white : const Color(0xFF18181B);
    final hintColor =
        isDark ? const Color(0xFF8E8E93) : const Color(0xFF8E8E93);

    // FLAVOR: None (inline / capsule / search input)
    if (widget.labelType == AuthTextFieldLabelType.none) {
      final effectiveHeight = widget.height ?? 40.0;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!_focusNode.hasFocus) {
            _focusNode.requestFocus();
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: effectiveHeight,
          decoration: BoxDecoration(
            color: effectiveBoxColor,
            borderRadius: effectiveRadius,
            border: Border.all(color: effectiveBorderColor, width: 1.0),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (widget.leading != null) ...[
                widget.leading!,
                const SizedBox(width: 8),
              ],
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focusNode,
                  obscureText: widget.obscureText,
                  textInputAction: widget.textInputAction,
                  keyboardType: widget.keyboardType,
                  autofocus: widget.autofocus,
                  onSubmitted: widget.onSubmitted,
                  onChanged: widget.onChanged,
                  cursorColor: AppTheme.primary,
                  cursorWidth: 1.5,
                  cursorHeight: 18,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    color: textColor,
                    height: 1.2,
                  ),
                  decoration: InputDecoration(
                    hintText: widget.hintText ?? widget.label,
                    hintStyle: TextStyle(
                      fontSize: 14.0,
                      fontWeight: FontWeight.w400,
                      color: hintColor,
                    ),
                    isDense: true,
                    filled: false,
                    fillColor: Colors.transparent,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                  ),
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 6),
                widget.trailing!,
              ],
            ],
          ),
        ),
      );
    }

    // FLAVOR: Floating label (default auth flavor)
    final effectiveHeight = widget.height ?? 58.0;
    final labelColor = widget.hasError
        ? const Color(0xFFED4956)
        : (isDark
            ? (isFloating ? const Color(0xFFA1A1AA) : const Color(0xFFA1A1AA))
            : (isFloating ? const Color(0xFF71717A) : const Color(0xFF71717A)));

    final double leftOffset = widget.leading != null ? 42.0 : 16.0;
    final double rightOffset = widget.trailing != null ? 46.0 : 16.0;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (!_focusNode.hasFocus) {
          _focusNode.requestFocus();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: effectiveHeight,
        decoration: BoxDecoration(
          color: effectiveBoxColor,
          borderRadius: effectiveRadius,
          border: Border.all(color: effectiveBorderColor, width: 1.0),
        ),
        child: Stack(
          children: [
            if (widget.leading != null)
              Positioned(
                left: 12,
                top: 0,
                bottom: 0,
                child: Center(child: widget.leading!),
              ),

            // Floating Label
            AnimatedPositioned(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              left: leftOffset,
              top: isFloating ? 8 : 18.5,
              right: rightOffset,
              child: IgnorePointer(
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOutCubic,
                  style: TextStyle(
                    fontSize: isFloating ? 11.0 : 16.0,
                    fontWeight: FontWeight.w400,
                    letterSpacing: isFloating ? 0.1 : 0.0,
                    color: labelColor,
                    height: 1.2,
                  ),
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),

            // User Input TextField
            Positioned(
              left: leftOffset,
              right: rightOffset,
              top: isFloating ? 24 : 17,
              height: 25,
              child: Opacity(
                opacity: isFloating ? 1.0 : 0.0,
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focusNode,
                  obscureText: widget.obscureText,
                  textInputAction: widget.textInputAction,
                  keyboardType: widget.keyboardType,
                  autofocus: widget.autofocus,
                  onSubmitted: widget.onSubmitted,
                  onChanged: widget.onChanged,
                  cursorColor: AppTheme.primary,
                  cursorWidth: 1.5,
                  cursorHeight: 18,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                    letterSpacing: -0.1,
                    height: 1.2,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    filled: false,
                    fillColor: Colors.transparent,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                  ),
                ),
              ),
            ),

            // Trailing widget (eye toggle, validation indicator, spinner)
            if (widget.trailing != null)
              Positioned(
                right: 6,
                top: 0,
                bottom: 0,
                child: Center(child: widget.trailing!),
              ),
          ],
        ),
      ),
    );
  }
}
