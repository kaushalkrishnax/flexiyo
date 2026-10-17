import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Composer replacement for recording a voice note: live waveform, timer,
/// pause/resume, discard and send. Recording starts on mount.
class VoiceRecorderBar extends StatefulWidget {
  const VoiceRecorderBar({
    super.key,
    required this.onCancel,
    required this.onSend,
  });

  final VoidCallback onCancel;

  /// Hands the finished recording to the parent for upload and sending.
  final Future<void> Function(Uint8List bytes, int durationMs) onSend;

  @override
  State<VoiceRecorderBar> createState() => _VoiceRecorderBarState();
}

enum _RecPhase { recording, paused, stopped }

class _VoiceRecorderBarState extends State<VoiceRecorderBar>
    with SingleTickerProviderStateMixin {
  static const Color _indigo = Color(0xFF5E5CE6);
  static const int _maxBars = 42;

  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _previewPlayer = AudioPlayer();
  final Stopwatch _stopwatch = Stopwatch();
  final math.Random _rng = math.Random();
  Timer? _ticker;
  StreamSubscription<void>? _previewCompleteSub;

  /// Blinks the waveform between full and low opacity while paused.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
    lowerBound: 0.35,
    upperBound: 1.0,
    value: 1.0,
  );

  _RecPhase _phase = _RecPhase.recording;
  final List<double> _levels = [];
  String? _filePath;
  bool _sending = false;

  /// True while the stopped take is being previewed through [_previewPlayer].
  bool _previewing = false;

  @override
  void initState() {
    super.initState();
    _previewCompleteSub = _previewPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _previewing = false);
    });
    _start();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _previewCompleteSub?.cancel();
    _previewPlayer.dispose();
    _pulse.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final allowed = await _recorder.hasPermission();
      if (!allowed) {
        _fail('Microphone permission is required for voice notes');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = p.join(
        dir.path,
        'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
        ),
        path: path,
      );
      _filePath = path;
      _stopwatch
        ..reset()
        ..start();
      _ticker?.cancel();
      _ticker = Timer.periodic(
        const Duration(milliseconds: 110),
        (_) => _onTick(),
      );
      if (mounted) setState(() => _phase = _RecPhase.recording);
    } catch (_) {
      _fail('Could not start recording');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
    widget.onCancel();
  }

  Future<void> _onTick() async {
    if (!mounted || _phase == _RecPhase.stopped) return;
    // While paused the waveform freezes (it blinks instead of moving).
    if (_phase == _RecPhase.paused) return;
    double level = 0.25;
    try {
      final amp = await _recorder.getAmplitude();
      // dBFS ≈ -50 (silence) .. 0 (max) → 0..1
      if (amp.current < 0) {
        level = ((amp.current + 50) / 50).clamp(0.12, 1.0);
      }
    } catch (_) {
      level = 0.2 + _rng.nextDouble() * 0.5;
    }
    if (!mounted) return;
    setState(() {
      _levels.add(level);
      while (_levels.length > _maxBars) {
        _levels.removeAt(0);
      }
    });
  }

  Future<void> _togglePause() async {
    try {
      if (_phase == _RecPhase.recording) {
        await _recorder.pause();
        _stopwatch.stop();
        if (mounted) {
          setState(() => _phase = _RecPhase.paused);
          _pulse.repeat(reverse: true);
        }
      } else if (_phase == _RecPhase.paused) {
        await _recorder.resume();
        _stopwatch.start();
        if (mounted) {
          _pulse
            ..stop()
            ..value = 1.0;
          setState(() => _phase = _RecPhase.recording);
        }
      }
    } catch (_) {
      // Keep the current phase.
    }
  }

  /// Play / pause the stopped take so it can be checked before sending.
  Future<void> _togglePreview() async {
    final path = _filePath;
    if (path == null) return;
    try {
      if (_previewing) {
        await _previewPlayer.pause();
        if (mounted) setState(() => _previewing = false);
        return;
      }
      if (_previewPlayer.state == PlayerState.paused &&
          _previewPlayer.source != null) {
        await _previewPlayer.resume();
      } else {
        await _previewPlayer.play(DeviceFileSource(path));
      }
      if (mounted) setState(() => _previewing = true);
    } catch (_) {}
  }

  /// Stop the take but keep the file for sending.
  Future<void> _stopTake() async {
    try {
      final path = await _recorder.stop();
      _stopwatch.stop();
      _ticker?.cancel();
      _pulse
        ..stop()
        ..value = 1.0;
      if (path != null && path.isNotEmpty) _filePath = path;
      if (mounted) setState(() => _phase = _RecPhase.stopped);
    } catch (_) {
      if (mounted) setState(() => _phase = _RecPhase.stopped);
    }
  }

  Future<void> _rerecord() async {
    try {
      await _previewPlayer.stop();
    } catch (_) {}
    _previewing = false;
    await _deleteCurrentFile();
    _levels.clear();
    await _start();
  }

  Future<void> _deleteCurrentFile() async {
    final path = _filePath;
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    _filePath = null;
  }

  Future<void> _discard() async {
    try {
      if (_phase != _RecPhase.stopped) await _recorder.cancel();
    } catch (_) {}
    try {
      await _previewPlayer.stop();
    } catch (_) {}
    _ticker?.cancel();
    _stopwatch.stop();
    await _deleteCurrentFile();
    widget.onCancel();
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);

    try {
      await _previewPlayer.stop();
    } catch (_) {}

    if (_phase != _RecPhase.stopped) {
      await _stopTake();
    }
    final path = _filePath;
    if (path == null) {
      await _discard();
      return;
    }
    try {
      final bytes = await File(path).readAsBytes();
      if (bytes.isEmpty) {
        await _discard();
        return;
      }
      await widget.onSend(bytes, _stopwatch.elapsed.inMilliseconds);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send voice note: $e')),
        );
      }
    } finally {
      try {
        await File(path).delete();
      } catch (_) {}
      if (mounted) setState(() => _sending = false);
    }
  }

  String _format(Duration d) {
    final mins = d.inMinutes.toString().padLeft(2, '0');
    final secs = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant.withAlpha(50),
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 54,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: _indigo,
                  borderRadius: BorderRadius.circular(27),
                ),
                child: Row(
                  children: [
                    _CapsuleButton(
                      onTap: _phase == _RecPhase.stopped
                          ? _togglePreview
                          : _stopTake,
                      child: _phase == _RecPhase.stopped
                          ? HugeIcon(
                              icon: _previewing
                                  ? HugeIcons.strokeRoundedPause
                                  : HugeIcons.strokeRoundedPlay,
                              color: Colors.white,
                              size: 22,
                            )
                          : Container(
                              width: 16,
                              height: 16,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _Waveform(
                        levels: _levels,
                        paused: _phase == _RecPhase.paused,
                        pulse: _pulse,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _format(_stopwatch.elapsed),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  IconButton(
                    onPressed: _sending ? null : _discard,
                    icon: HugeIcon(
                      icon: HugeIcons.strokeRoundedTrash,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                    tooltip: 'Discard',
                  ),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Paused takes wear a translucent amber halo so the
                        // hold is obvious; the mic returns on resume.
                        Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _phase == _RecPhase.paused
                                ? const Color(0xFFFFC400)
                                    .withValues(alpha: 0.22)
                                : Colors.transparent,
                          ),
                          child: IconButton(
                            onPressed: _phase == _RecPhase.stopped
                                ? null
                                : _togglePause,
                            icon: HugeIcon(
                              icon: _phase == _RecPhase.paused
                                  ? HugeIcons.strokeRoundedMic01
                                  : HugeIcons.strokeRoundedMicOff01,
                              color: _phase == _RecPhase.stopped
                                  ? Colors.grey
                                  : (isDark ? Colors.white : Colors.black87),
                              size: 28,
                            ),
                            tooltip: _phase == _RecPhase.paused
                                ? 'Resume listening'
                                : 'Pause listening',
                          ),
                        ),
                        const SizedBox(width: 6),
                        InkWell(
                          onTap: _phase == _RecPhase.stopped ? _rerecord : null,
                          borderRadius: BorderRadius.circular(12),
                          child: Opacity(
                            opacity: _phase == _RecPhase.stopped ? 1.0 : 0.45,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: _indigo.withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Text(
                                'New',
                                style: TextStyle(
                                  color: _indigo,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 46,
                    height: 46,
                    child: Material(
                      color: _indigo,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _sending ? null : _send,
                        child: Center(
                          child: _sending
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: Colors.white,
                                  ),
                                )
                              : const HugeIcon(
                                  icon: HugeIcons.strokeRoundedSend,
                                  color: Colors.white,
                                  size: 22,
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CapsuleButton extends StatelessWidget {
  const _CapsuleButton({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: SizedBox(
        width: 40,
        height: 44,
        child: Center(child: child),
      ),
    );
  }
}

/// Metered mic amplitude; newest bars on the right. While paused the bars
/// hold still and blink between full and low opacity instead.
class _Waveform extends StatelessWidget {
  const _Waveform({
    required this.levels,
    required this.paused,
    required this.pulse,
  });

  final List<double> levels;
  final bool paused;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    final bars = List<double>.from(levels);
    while (bars.length < 42) {
      bars.insert(0, 0.12);
    }
    final shown = bars.sublist(bars.length - 42);

    return SizedBox(
      height: 30,
      child: FadeTransition(
        opacity: paused ? pulse : const AlwaysStoppedAnimation<double>(1),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (final level in shown)
              Container(
                width: 2.4,
                height: 26 * level.clamp(0.12, 1.0),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(1.6),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
