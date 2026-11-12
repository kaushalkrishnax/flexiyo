import 'dart:async';

import 'package:flexiyo/core/exceptions.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/providers/conversation_crypto_provider.dart';
import 'package:flexiyo/services/device_pairing_service.dart';
import 'package:flexiyo/services/pairing_qr_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:qr_flutter/qr_flutter.dart';

enum _PairingPhase { creating, waiting, verifying, approved, expired, failed }

/// Shows a one-time QR code that an already-linked device can scan.
class PairDeviceScreen extends ConsumerStatefulWidget {
  const PairDeviceScreen({super.key});

  @override
  ConsumerState<PairDeviceScreen> createState() => _PairDeviceScreenState();
}

class _PairDeviceScreenState extends ConsumerState<PairDeviceScreen> {
  late final DevicePairingService _pairing;
  _PairingPhase _phase = _PairingPhase.creating;
  PairingQrCode? _qr;
  String? _sessionId;
  String? _error;
  DateTime? _expiresAt;
  Duration _remaining = Duration.zero;
  Timer? _ticker;
  Timer? _poller;
  bool _polling = false;
  bool _approving = false;

  String? get _userId => ref.read(authProvider).user?.id;

  @override
  void initState() {
    super.initState();
    _pairing = ref.read(devicePairingProvider);
    _startOrReuse();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _poller?.cancel();
    // Don't cancel an unexpired session on leave; it is reused on return.
    super.dispose();
  }

  Future<void> _startOrReuse() async {
    final userId = _userId;
    if (userId == null) {
      if (!mounted) return;
      setState(() {
        _phase = _PairingPhase.failed;
        _error = 'Sign in to pair a device.';
      });
      return;
    }

    try {
      final reused = await _pairing.reusableSession(userId: userId);
      if (!mounted) return;
      if (reused != null) {
        _adoptQr(reused);
        return;
      }
    } catch (_) {
      // Fall through to issuing a fresh session.
    }
    await _start();
  }

  void _adoptQr(PairingQrCode qr) {
    final expiry = qr.expiry!;
    setState(() {
      _qr = qr;
      _sessionId = qr.sessionId;
      _phase = _PairingPhase.waiting;
      _expiresAt = expiry;
      _remaining = expiry.difference(DateTime.now());
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _poller = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_poll()),
    );
  }

  Future<void> _start() async {
    _ticker?.cancel();
    _poller?.cancel();
    final previous = _sessionId;
    if (previous != null) {
      unawaited(_pairing.cancelPairing(previous).catchError((_) {}));
    }

    setState(() {
      _phase = _PairingPhase.creating;
      _qr = null;
      _sessionId = null;
      _error = null;
      _expiresAt = null;
      _remaining = Duration.zero;
    });

    final userId = _userId;
    if (userId == null) {
      setState(() {
        _phase = _PairingPhase.failed;
        _error = 'Sign in to pair a device.';
      });
      return;
    }

    try {
      final payload = await _pairing.createQrSession(userId: userId);
      final qr = PairingQrCode.fromPayload(payload);
      if (qr.expiresAt == null) {
        throw StateError('The server returned an incomplete pairing session');
      }

      if (!mounted) return;
      final expiry = qr.expiry!;
      setState(() {
        _qr = qr;
        _sessionId = qr.sessionId;
        _phase = _PairingPhase.waiting;
        _expiresAt = expiry;
        _remaining = expiry.difference(DateTime.now());
      });
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      _poller = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_poll()),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _PairingPhase.failed;
        _error = _describe(error);
      });
    }
  }

  void _tick() {
    final expiresAt = _expiresAt;
    if (expiresAt == null) return;
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining <= Duration.zero &&
        _phase != _PairingPhase.approved &&
        _phase != _PairingPhase.verifying) {
      _ticker?.cancel();
      _poller?.cancel();
      setState(() {
        _phase = _PairingPhase.expired;
        _remaining = Duration.zero;
      });
      return;
    }
    if (mounted) setState(() => _remaining = remaining);
  }

  Future<void> _poll() async {
    final sessionId = _sessionId;
    if (_polling || sessionId == null) return;
    if (_phase != _PairingPhase.waiting) return;
    _polling = true;
    try {
      final session = await _pairing.inspectPairingSession(sessionId);
      final status = session['status'];
      if (status == 'joined') {
        await _approve();
      } else if (status == 'approved') {
        // The server approved a previous attempt but provisioning failed.
        await _approve();
      } else if (status == 'expired' || status == 'cancelled') {
        _ticker?.cancel();
        _poller?.cancel();
        if (!mounted) return;
        setState(() {
          _phase = _PairingPhase.expired;
          _remaining = Duration.zero;
        });
      }
    } catch (error) {
      // Expired sessions surface as 404; other failures are transient and the
      // next poll retries.
      if (error is NotFoundException) {
        _ticker?.cancel();
        _poller?.cancel();
        if (!mounted) return;
        setState(() {
          _phase = _PairingPhase.expired;
          _remaining = Duration.zero;
        });
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _approve() async {
    final sessionId = _sessionId;
    final userId = _userId;
    if (_approving || sessionId == null || userId == null) return;
    _approving = true;
    if (mounted) {
      setState(() {
        _phase = _PairingPhase.verifying;
        _error = null;
      });
    }

    try {
      await _pairing.approveJoinedDevice(sessionId, myUserId: userId);
      _ticker?.cancel();
      _poller?.cancel();
      if (!mounted) return;
      setState(() => _phase = _PairingPhase.approved);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _PairingPhase.waiting;
        _error =
            'The device answered but its keys could not be provisioned yet. '
            '${_describe(error)}';
      });
    } finally {
      _approving = false;
    }
  }

  Future<void> _copyCode() async {
    final qr = _qr;
    if (qr == null) return;
    await Clipboard.setData(ClipboardData(text: qr.shortCode));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Pairing code copied. Treat it like a password and share it only '
          'with a device you control.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair a device'),
        leading: IconButton(
          icon: const HugeIcon(icon: HugeIcons.strokeRoundedArrowLeft01),
          onPressed: () => context.canPop() ? context.pop() : context.go('/settings'),
          tooltip: 'Back',
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_phase == _PairingPhase.approved)
                _ApprovedPanel(onDone: () => context.pop(true))
              else if (_phase == _PairingPhase.creating)
                const _CenteredProgress(label: 'Creating a pairing code…')
              else if (_qr == null)
                _FailurePanel(
                  message: _error ?? 'Could not create a pairing code.',
                  onRetry: _start,
                  onScanInstead: () => context.pushReplacement(
                    '/settings/devices/scan',
                  ),
                )
              else ...[
                Text(
                  'Scan this code on the device you want to link',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: QrImageView(
                      data: _qr!.encode(),
                      version: QrVersions.auto,
                      size: 248,
                      gapless: true,
                      backgroundColor: Colors.white,
                      eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: Colors.black,
                      ),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (_phase == _PairingPhase.verifying)
                  const _CenteredProgress(
                    label: 'Verifying the device and provisioning keys…',
                  )
                else if (_phase == _PairingPhase.expired)
                  const _StatusLine(
                    icon: HugeIcons.strokeRoundedAlert02,
                    text: 'This code expired. Generate a new one to continue.',
                    tone: _Tone.warning,
                  )
                else
                  _StatusLine(
                    icon: HugeIcons.strokeRoundedBarcodeScan,
                    text: _remaining > Duration.zero
                        ? 'Waiting for the other device… ${_formatDuration(_remaining)} left'
                        : 'Waiting for the other device…',
                    tone: _Tone.info,
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      height: 1.35,
                    ),
                  ),
                  if (_phase == _PairingPhase.waiting)
                    TextButton.icon(
                      onPressed: _approving ? null : _approve,
                      icon: const HugeIcon(
                        icon: HugeIcons.strokeRoundedRefresh,
                        size: 18,
                      ),
                      label: const Text('Retry key provisioning'),
                    ),
                ],
                const SizedBox(height: 20),
                if (_phase != _PairingPhase.verifying) ...[
                  const SizedBox(height: 16),
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          width: 1,
                        ),
                      ),
                      child: Text(
                        _qr!.shortCode,
                        style: const TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _copyCode,
                    icon: const HugeIcon(
                      icon: HugeIcons.strokeRoundedCopy01,
                      size: 18,
                    ),
                    label: const Text('Copy pairing code'),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _start,
                    icon: const HugeIcon(
                      icon: HugeIcons.strokeRoundedRefresh,
                      size: 18,
                    ),
                    label: const Text('Generate a new code'),
                  ),
                ],
                const SizedBox(height: 24),
                const _Instructions(),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Instructions extends StatelessWidget {
  const _Instructions();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'On the new device',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '1. Sign in to the same Flexiyo account.\n'
            '2. Open Settings → Linked devices → Link this device.\n'
            '3. Scan the QR code above.\n'
            '4. Confirm the approval here.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted, height: 1.5),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: HugeIcon(icon: HugeIcons.strokeRoundedShieldKey, size: 16),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'The code contains a one-time secret and expires shortly. '
                  'Never send it to anyone, and never scan codes you did not '
                  'generate.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted, height: 1.4),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ApprovedPanel extends StatelessWidget {
  const _ApprovedPanel({required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 48),
        const HugeIcon(
          icon: HugeIcons.strokeRoundedCheckmarkCircle02,
          size: 64,
          color: Color(0xFF2E7D32),
        ),
        const SizedBox(height: 16),
        Text(
          'Device linked',
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text(
          'The new device has its own copy of every conversation key. '
          'Future messages will be encrypted to it automatically.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 28),
        FilledButton(onPressed: onDone, child: const Text('Done')),
      ],
    );
  }
}

class _FailurePanel extends StatelessWidget {
  const _FailurePanel({
    required this.message,
    required this.onRetry,
    required this.onScanInstead,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onScanInstead;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 48),
        const HugeIcon(
          icon: HugeIcons.strokeRoundedAlert02,
          size: 48,
          color: Color(0xFFFF2E63),
        ),
        const SizedBox(height: 16),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 20),
        FilledButton(onPressed: onRetry, child: const Text('Try again')),
        const SizedBox(height: 8),
        TextButton(
          onPressed: onScanInstead,
          child: const Text('Scan a code from another device instead'),
        ),
      ],
    );
  }
}

class _CenteredProgress extends StatelessWidget {
  const _CenteredProgress({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(label, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

enum _Tone { info, warning }

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.icon,
    required this.text,
    required this.tone,
  });

  final List<List<dynamic>> icon;
  final String text;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final color = tone == _Tone.warning
        ? const Color(0xFFE65100)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: HugeIcon(icon: icon, size: 16, color: color),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            style: TextStyle(color: color, height: 1.35),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

String _formatDuration(Duration duration) {
  final clamped = duration.isNegative ? Duration.zero : duration;
  final minutes = clamped.inMinutes;
  final seconds = clamped.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String _describe(Object error) {
  if (error is FlexiyoException) return error.message;
  final text = error.toString();
  for (final prefix in ['Exception: ', 'Bad state: ']) {
    if (text.startsWith(prefix)) return text.substring(prefix.length);
  }
  return text;
}
