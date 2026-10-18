import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flexiyo/models/message.dart';
import 'package:flexiyo/screens/media/media_viewer_screen.dart';
import 'package:flexiyo/services/media_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hugeicons/hugeicons.dart';

/// Chat image bubble; view-limited recipient media stays locked until tapped.
class MediaImageBubble extends ConsumerStatefulWidget {
  const MediaImageBubble({
    super.key,
    required this.message,
    required this.isMine,
  });

  final Message message;
  final bool isMine;

  @override
  ConsumerState<MediaImageBubble> createState() => _MediaImageBubbleState();
}

class _MediaImageBubbleState extends ConsumerState<MediaImageBubble> {
  Uint8List? _bytes;
  bool _loading = false;
  bool _expired = false;

  MediaRef get _ref => widget.message.mediaRef!;
  bool get _locked => !widget.isMine && _ref.policy != ViewPolicy.unlimited;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    if (_loading) return;

    // View-limited recipient media stays locked until tapped.
    if (_locked && !force) return;

    final service = ref.read(mediaServiceProvider);

    // A cache hit renders without consuming a view.
    final cached = await service.cachedBytes(_ref);
    if (cached != null && mounted) {
      setState(() {
        _bytes = cached;
        _expired = false;
      });
      return;
    }

    if (mounted) setState(() => _loading = true);
    try {
      final bytes = await service.fetchAndDecrypt(_ref);
      if (mounted) {
        setState(() {
          _bytes = bytes;
          _expired = false;
        });
      }
    } on MediaExpiredException {
      if (mounted) setState(() => _expired = true);
    } catch (e) {
      // ignore: avoid_print
      print('media image load failed: $e');
      // Fall through to the retry tile.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open() async {
    if (_expired) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This media is no longer available')),
      );
      return;
    }
    // A locked tap costs a view: only fetch inside the viewer.
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MediaViewerScreen(message: widget.message),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_expired) {
      return _tile(
        child: _message(
          icon: HugeIcons.strokeRoundedEyeOff,
          text: 'Media expired',
        ),
      );
    }

    if (_bytes != null) {
      return GestureDetector(
        onTap: _open,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 250,
              maxHeight: 330,
              minWidth: 120,
              minHeight: 90,
            ),
            child: Image.memory(
              _bytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
          ),
        ),
      );
    }

    if (_loading) {
      return _tile(
        child: const SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(
              strokeWidth: 2.2, color: Colors.white70),
        ),
      );
    }

    if (_locked) {
      return GestureDetector(
        onTap: _open,
        child: _tile(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const HugeIcon(
                icon: HugeIcons.strokeRoundedCamera01,
                color: Colors.white70,
                size: 30,
              ),
              const SizedBox(height: 8),
              Text(
                'Tap to view',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.92),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              ViewPolicyChip(policy: _ref.policy, compact: true),
            ],
          ),
        ),
      );
    }

    // Auto-load failed — the tile offers a manual retry.
    return GestureDetector(
      onTap: () => _load(force: true),
      child: _tile(
        child: _message(
          icon: HugeIcons.strokeRoundedRefresh,
          text: 'Tap to retry',
        ),
      ),
    );
  }

  Widget _tile({required Widget child}) {
    return Container(
      width: 200,
      height: 140,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Center(child: child),
    );
  }

  Widget _message({
    required List<List<dynamic>> icon,
    required String text,
  }) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        HugeIcon(icon: icon, size: 26, color: Colors.white70),
        const SizedBox(height: 6),
        Text(
          text,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontSize: 12.5,
          ),
        ),
      ],
    );
  }
}

/// "View once / View twice / Unlimited views" pill (dotted-circle numeral + label).
class ViewPolicyChip extends StatelessWidget {
  const ViewPolicyChip({
    super.key,
    required this.policy,
    this.compact = false,
    this.onTap,
    this.dark = false,
  });

  final ViewPolicy policy;
  final bool compact;
  final VoidCallback? onTap;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    const fg = Colors.white;
    final child = Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 14,
        vertical: compact ? 5 : 9,
      ),
      decoration: BoxDecoration(
        color: dark ? Colors.black.withValues(alpha: 0.55) : Colors.white24,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ViewPolicyGlyph(policy: policy, size: compact ? 16 : 20, color: fg),
          SizedBox(width: compact ? 6 : 8),
          Text(
            policy.label,
            style: TextStyle(
              color: fg,
              fontSize: compact ? 11.5 : 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            HugeIcon(
              icon: HugeIcons.strokeRoundedChevronUp,
              size: compact ? 14 : 18,
              color: fg,
            ),
          ],
        ],
      ),
    );
    return onTap == null ? child : GestureDetector(onTap: onTap, child: child);
  }
}

/// Dotted-circle numeral ("1", "2") or checked circle for unlimited views.
class ViewPolicyGlyph extends StatelessWidget {
  const ViewPolicyGlyph({
    super.key,
    required this.policy,
    required this.size,
    this.color = Colors.white,
  });

  final ViewPolicy policy;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (policy == ViewPolicy.unlimited) {
      return HugeIcon(
        icon: HugeIcons.strokeRoundedCheckmarkCircle01,
        size: size,
        color: color,
      );
    }
    return CustomPaint(
      size: Size.square(size),
      painter: _DottedCirclePainter(
        color: color,
        number: policy == ViewPolicy.once ? '1' : '2',
      ),
    );
  }
}

class _DottedCirclePainter extends CustomPainter {
  _DottedCirclePainter({required this.color, required this.number});

  final Color color;
  final String number;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 1.5;
    final dotPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    const dotCount = 14;
    for (var i = 0; i < dotCount; i++) {
      final angle = (i / dotCount) * 6.28318530718;
      final dot = Offset(
        center.dx + radius * math.cos(angle),
        center.dy + radius * math.sin(angle),
      );
      canvas.drawCircle(dot, 1.1, dotPaint);
    }

    final textPainter = TextPainter(
      text: TextSpan(
        text: number,
        style: TextStyle(
          color: color,
          fontSize: size.width * 0.52,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      center - Offset(textPainter.width / 2, textPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _DottedCirclePainter old) =>
      old.color != color || old.number != number;
}
