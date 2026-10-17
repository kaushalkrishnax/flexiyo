import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flexiyo/models/message.dart';
import 'package:flexiyo/services/media_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hugeicons/hugeicons.dart';

/// Voice-note bubble with play/pause, waveform progress and duration.
class MediaVoiceBubble extends ConsumerStatefulWidget {
  const MediaVoiceBubble({
    super.key,
    required this.message,
    required this.isMine,
  });

  final Message message;
  final bool isMine;

  @override
  ConsumerState<MediaVoiceBubble> createState() => _MediaVoiceBubbleState();
}

class _MediaVoiceBubbleState extends ConsumerState<MediaVoiceBubble> {
  static const Color _outgoingPurple = Color(0xFF7C3AED);

  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<void>? _completeSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;

  bool _preparing = false;
  bool _playing = false;
  bool _expired = false;
  String? _error;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  MediaRef get _ref => widget.message.mediaRef!;

  @override
  void initState() {
    super.initState();
    _duration = Duration(milliseconds: _ref.durationMs ?? 0);
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _position = Duration.zero;
        });
      }
    });
    _posSub = _player.onPositionChanged.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    _durSub = _player.onDurationChanged.listen((dur) {
      if (mounted && dur > Duration.zero) setState(() => _duration = dur);
    });
  }

  @override
  void dispose() {
    _completeSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_expired) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This voice note is no longer available')),
      );
      return;
    }
    if (_playing) {
      await _player.pause();
      if (mounted) setState(() => _playing = false);
      return;
    }

    try {
      if (_player.state == PlayerState.paused && _player.source != null) {
        await _player.resume();
        if (mounted) setState(() => _playing = true);
        return;
      }

      if (mounted) setState(() => _preparing = true);

      final service = ref.read(mediaServiceProvider);
      final file = await service.ensureCachedFile(_ref);
      await _player.play(DeviceFileSource(file.path));
      if (mounted) {
        setState(() {
          _playing = true;
          _preparing = false;
        });
      }
    } on MediaExpiredException {
      if (mounted) {
        setState(() {
          _expired = true;
          _preparing = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Playback failed';
          _preparing = false;
        });
      }
    }
  }

  String _format(Duration d) {
    final mins = d.inMinutes;
    final secs = d.inSeconds % 60;
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }

  /// Stable bar pattern derived from the media id.
  List<double> _bars() {
    final seed = _ref.id.codeUnits.fold<int>(7, (a, b) => a * 31 + b);
    final rnd = math.Random(seed);
    return List.generate(30, (_) => 0.25 + rnd.nextDouble() * 0.75);
  }

  @override
  Widget build(BuildContext context) {
    final bubbleColor =
        widget.isMine ? _outgoingPurple : const Color(0xFF26282F);
    final bars = _bars();
    final progress = _duration.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);

    final label = _playing || _position > Duration.zero
        ? _format(_position)
        : _format(_duration);

    return GestureDetector(
      onTap: _toggle,
      child: Container(
        width: 240,
        padding: const EdgeInsets.fromLTRB(10, 12, 12, 12),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 40,
                  height: 40,
                  child: _preparing
                      ? const Padding(
                          padding: EdgeInsets.all(9),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : _expired
                          ? const HugeIcon(
                              icon: HugeIcons.strokeRoundedEyeOff,
                              color: Colors.white,
                              size: 24,
                            )
                          : HugeIcon(
                              icon: _playing
                                  ? HugeIcons.strokeRoundedPause
                                  : HugeIcons.strokeRoundedPlay,
                              color: Colors.white,
                              size: 28,
                            ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 30,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return Stack(
                          children: [
                            _waveform(
                                bars, Colors.white.withValues(alpha: 0.38)),
                            ClipRect(
                              clipper: _FractionClipper(progress),
                              child: _waveform(bars, Colors.white),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _expired ? '—' : label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(left: 40, top: 4),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 11,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _waveform(List<double> bars, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < bars.length; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 0.7),
              child: Container(
                height: 26 * bars[i],
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _FractionClipper extends CustomClipper<Rect> {
  _FractionClipper(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(covariant _FractionClipper old) => old.fraction != fraction;
}
