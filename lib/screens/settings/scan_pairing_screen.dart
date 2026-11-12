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
import 'package:mobile_scanner/mobile_scanner.dart';

enum _ScanPhase {
  checking,
  alreadyLinked,
  scanning,
  confirm,
  joining,
  awaitingApproval,
  accepting,
  done,
  error,
}

/// Links this installation by scanning the QR code shown on an existing
/// device. The payload never leaves the two devices; the Worker only relays
/// the opaque ECDH proof and, later, encrypted key envelopes.
class ScanPairingScreen extends ConsumerStatefulWidget {
  const ScanPairingScreen({super.key});

  @override
  ConsumerState<ScanPairingScreen> createState() => _ScanPairingScreenState();
}

class _ScanPairingScreenState extends ConsumerState<ScanPairingScreen> {
  late final DevicePairingService _pairing;
  late final MobileScannerController _scanner;
  final TextEditingController _pasteController = TextEditingController();

  _ScanPhase _phase = _ScanPhase.checking;
  Map<String, dynamic>? _payload;
  String? _sessionId;
  String? _message;
  DateTime? _expiresAt;
  Timer? _poller;
  bool _polling = false;
  bool _accepting = false;
  bool _serverApproved = false;
  bool _usingPaste = false;

  String? get _userId => ref.read(authProvider).user?.id;

  @override
  void initState() {
    super.initState();
    _pairing = ref.read(devicePairingProvider);
    _scanner = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkLinkState());
  }

  @override
  void dispose() {
    _poller?.cancel();
    _pasteController.dispose();
    _scanner.dispose();
    super.dispose();
  }

  Future<void> _checkLinkState() async {
    final userId = _userId;
    if (userId == null) {
      setState(() {
        _phase = _ScanPhase.error;
        _message = 'Sign in to link this device.';
      });
      return;
    }

    try {
      // Succeeds only for the account's first device or an installation that
      // was already upgraded; otherwise the server asks for pairing.
      await ref.read(conversationCryptoProvider).ensureDeviceRegistered(
            userId: userId,
          );
      if (!mounted) return;
      setState(() => _phase = _ScanPhase.alreadyLinked);
    } catch (_) {
      if (!mounted) return;
      setState(() => _phase = _ScanPhase.scanning);
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_phase != _ScanPhase.scanning && _phase != _ScanPhase.error) return;
    final raw = capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
    if (raw == null || raw.isEmpty) return;
    _useCode(raw);
  }

  void _useCode(String raw) {
    final PairingQrCode qr;
    try {
      qr = PairingQrCode.parse(raw);
    } on FormatException {
      if (!mounted) return;
      setState(() {
        _message = 'That code is not a Flexiyo pairing code. Try again.';
      });
      return;
    }

    if (qr.isExpiredAt(DateTime.now())) {
      setState(() => _message = 'That pairing code has expired.');
      return;
    }

    unawaited(_scanner.stop());
    setState(() {
      _payload = qr.toJson();
      _message = null;
      _expiresAt = qr.expiry;
      _phase = _ScanPhase.confirm;
    });
  }

  Future<void> _scanAgain() async {
    _pasteController.clear();
    setState(() {
      _payload = null;
      _sessionId = null;
      _message = null;
      _expiresAt = null;
      _usingPaste = false;
      _serverApproved = false;
      _phase = _ScanPhase.scanning;
    });
    try {
      await _scanner.start();
    } catch (_) {
      // Camera may be unavailable; the paste field remains usable.
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      if (!mounted) return;
      setState(() => _message = 'The clipboard does not contain a code.');
      return;
    }
    _pasteController.text = text.trim();
    _useCode(text.trim());
  }

  Future<void> _join() async {
    final payload = _payload;
    final userId = _userId;
    if (payload == null || userId == null) return;

    final sessionId = payload['sessionId'] as String;
    setState(() {
      _phase = _ScanPhase.joining;
      _message = null;
      _sessionId = sessionId;
      _serverApproved = false;
    });

    try {
      await _pairing.joinQrSession(payload, userId: userId);
      if (!mounted) return;
      setState(() => _phase = _ScanPhase.awaitingApproval);
      _poller = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_poll()),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _ScanPhase.error;
        _message = _describe(error);
      });
    }
  }

  Future<void> _poll() async {
    final sessionId = _sessionId;
    if (_polling || sessionId == null) return;
    _polling = true;
    try {
      final session = await _pairing.inspectPairingSession(sessionId);
      final status = session['status'];
      if (status == 'approved') {
        _serverApproved = true;
        await _accept();
      } else if (status == 'expired' || status == 'cancelled') {
        _poller?.cancel();
        if (!mounted) return;
        setState(() {
          _phase = _ScanPhase.error;
          _message = status == 'expired'
              ? 'The pairing code expired before it was approved.'
              : 'The pairing request was cancelled on the other device.';
        });
      }
    } catch (error) {
      if (error is NotFoundException) {
        _poller?.cancel();
        if (!mounted) return;
        setState(() {
          _phase = _ScanPhase.error;
          _message = 'The pairing session is no longer available.';
        });
      }
      // Transient failures retry on the next tick.
    } finally {
      _polling = false;
    }
  }

  Future<void> _accept() async {
    final sessionId = _sessionId;
    final userId = _userId;
    if (_accepting || sessionId == null || userId == null) return;
    _accepting = true;
    _poller?.cancel();
    if (mounted) {
      setState(() {
        _phase = _ScanPhase.accepting;
        _message = null;
      });
    }

    try {
      await _pairing.acceptApproval(sessionId, userId: userId);
      if (!mounted) return;
      setState(() => _phase = _ScanPhase.done);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _ScanPhase.error;
        _message =
            'The device was approved, but its local setup failed. '
            '${_describe(error)}';
      });
    } finally {
      _accepting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Link this device'),
        leading: IconButton(
          icon: const HugeIcon(icon: HugeIcons.strokeRoundedArrowLeft01),
          onPressed: () => context.canPop() ? context.pop() : context.go('/settings'),
          tooltip: 'Back',
        ),
      ),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    switch (_phase) {
      case _ScanPhase.checking:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 64),
          child: Column(
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Checking this installation…'),
            ],
          ),
        );
      case _ScanPhase.alreadyLinked:
        return _InfoPanel(
          icon: HugeIcons.strokeRoundedCheckmarkCircle02,
          color: const Color(0xFF2E7D32),
          title: 'This device is already linked',
          message:
              'It already holds conversation keys for this account. Opening a '
              'chat will fetch any missing keys automatically.',
          action: FilledButton(
            onPressed: () => context.pop(false),
            child: const Text('Back to settings'),
          ),
        );
      case _ScanPhase.done:
        return _InfoPanel(
          icon: HugeIcons.strokeRoundedCheckmarkCircle02,
          color: const Color(0xFF2E7D32),
          title: 'Device linked',
          message:
              'Conversation keys are now stored on this device. Messages you '
              'send from here will be encrypted to every linked device.',
          action: FilledButton(
            onPressed: () => context.pop(true),
            child: const Text('Done'),
          ),
        );
      case _ScanPhase.joining:
      case _ScanPhase.awaitingApproval:
      case _ScanPhase.accepting:
        return _ProgressPanel(
          label: _phase == _ScanPhase.joining
              ? 'Sending the pairing proof…'
              : (_phase == _ScanPhase.accepting
                  ? 'Saving conversation keys…'
                  : 'Waiting for approval on your other device…'),
          detail: _phase == _ScanPhase.awaitingApproval
              ? 'Keep the other device open. The request expires in a few minutes.'
              : null,
          onCancel: _cancelWaiting,
        );
      case _ScanPhase.error:
        return _ErrorPanel(
          message: _message ?? 'Pairing failed.',
          onRetry: _serverApproved
              ? _accept
              : (_payload == null ? _scanAgain : _join),
          retryLabel: _serverApproved
              ? 'Retry setup'
              : (_payload == null ? 'Scan again' : 'Try again'),
        );
      case _ScanPhase.confirm:
        return _confirmPanel(context);
      case _ScanPhase.scanning:
        return _scannerPanel(context);
    }
  }

  Widget _confirmPanel(BuildContext context) {
    final sessionId = _payload?['sessionId'] as String?;
    final expiresAt = _expiresAt;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      children: [
        const HugeIcon(
          icon: HugeIcons.strokeRoundedLinkSquare02,
          size: 56,
        ),
        const SizedBox(height: 20),
        Text(
          'Link this device?',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Text(
          'Only continue if you generated this code yourself on another '
          'device signed in to your account.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 20),
        if (sessionId != null)
          _DetailRow(
            label: 'Pairing session',
            value: sessionId.split('-').first.toUpperCase(),
          ),
        if (expiresAt != null)
          _DetailRow(
            label: 'Expires',
            value: TimeOfDay.fromDateTime(expiresAt).format(context),
          ),
        const SizedBox(height: 28),
        FilledButton.icon(
          onPressed: _join,
          icon: const HugeIcon(icon: HugeIcons.strokeRoundedLink01, size: 18),
          label: const Text('Link device'),
        ),
        const SizedBox(height: 8),
        TextButton(onPressed: _scanAgain, child: const Text('Scan a different code')),
      ],
    );
  }

  Widget _scannerPanel(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        Text(
          'Scan the pairing code',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          'On a linked device open Settings → Linked devices → Pair a new device.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 16),
        AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: MobileScanner(
              controller: _scanner,
              onDetect: _onDetect,
              fit: BoxFit.cover,
              errorBuilder: (context, error) => _CameraUnavailable(
                onUseCode: () => setState(() => _usingPaste = true),
              ),
            ),
          ),
        ),
        if (_message != null) ...[
          const SizedBox(height: 12),
          Text(
            _message!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 20),
        if (!_usingPaste)
          TextButton(
            onPressed: () => setState(() => _usingPaste = true),
            child: const Text('Enter a pairing code manually'),
          )
        else ...[
          TextField(
            controller: _pasteController,
            minLines: 1,
            maxLines: 3,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Pairing code',
              hintText: 'Paste the code copied from the linked device',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pasteFromClipboard,
                  icon: const HugeIcon(
                    icon: HugeIcons.strokeRoundedClipboardPaste,
                    size: 18,
                  ),
                  label: const Text('Paste'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    final text = _pasteController.text.trim();
                    if (text.isEmpty) {
                      setState(() => _message = 'Enter a pairing code first.');
                      return;
                    }
                    _useCode(text);
                  },
                  child: const Text('Continue'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _cancelWaiting() async {
    _poller?.cancel();
    final sessionId = _sessionId;
    if (sessionId != null) {
      unawaited(_pairing.cancelPairing(sessionId).catchError((_) {}));
    }
    await _scanAgain();
  }
}

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.onUseCode});

  final VoidCallback onUseCode;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const HugeIcon(
                icon: HugeIcons.strokeRoundedBarcodeScan,
                size: 40,
              ),
              const SizedBox(height: 12),
              const Text(
                'The camera is unavailable. Enter the pairing code instead.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              TextButton(onPressed: onUseCode, child: const Text('Enter code')),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
    required this.action,
  });

  final List<List<dynamic>> icon;
  final Color color;
  final String title;
  final String message;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 56, 28, 28),
      child: Column(
        children: [
          HugeIcon(icon: icon, size: 64, color: color),
          const SizedBox(height: 20),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(height: 1.4),
          ),
          const SizedBox(height: 28),
          action,
        ],
      ),
    );
  }
}

class _ProgressPanel extends StatelessWidget {
  const _ProgressPanel({
    required this.label,
    this.detail,
    this.onCancel,
  });

  final String label;
  final String? detail;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 72, 28, 28),
      child: Column(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (detail != null) ...[
            const SizedBox(height: 10),
            Text(
              detail!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
          if (onCancel != null) ...[
            const SizedBox(height: 28),
            TextButton(onPressed: onCancel, child: const Text('Cancel')),
          ],
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({
    required this.message,
    required this.onRetry,
    required this.retryLabel,
  });

  final String message;
  final VoidCallback onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 56, 28, 28),
      child: Column(
        children: [
          const HugeIcon(
            icon: HugeIcons.strokeRoundedAlert02,
            size: 48,
            color: Color(0xFFFF2E63),
          ),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton(onPressed: onRetry, child: Text(retryLabel)),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => context.go('/settings'),
            child: const Text('Back to settings'),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          Text(value, style: const TextStyle(fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

String _describe(Object error) {
  if (error is FlexiyoException) return error.message;
  final text = error.toString();
  for (final prefix in ['Exception: ', 'Bad state: ']) {
    if (text.startsWith(prefix)) return text.substring(prefix.length);
  }
  return text;
}
