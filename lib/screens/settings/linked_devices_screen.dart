import 'package:flexiyo/core/exceptions.dart';
import 'package:flexiyo/models/paired_device.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/providers/conversation_crypto_provider.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/widgets/confirm_popup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hugeicons/hugeicons.dart';

/// Lists every installation registered to the account and exposes the
/// pairing entry points. Keys are provisioned per device, so a device that is
/// not listed here cannot read conversation-key messages.
class LinkedDevicesScreen extends ConsumerStatefulWidget {
  const LinkedDevicesScreen({super.key});

  @override
  ConsumerState<LinkedDevicesScreen> createState() =>
      _LinkedDevicesScreenState();
}

class _LinkedDevicesScreenState extends ConsumerState<LinkedDevicesScreen> {
  bool _loading = true;
  String? _error;
  List<PairedDevice> _devices = const [];
  int? _currentDeviceId;
  bool _revoking = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final user = ref.read(authProvider).user;
    if (user == null) {
      setState(() {
        _loading = false;
        _error = 'Sign in to manage linked devices.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final store = ref.read(localConversationKeyStoreProvider);
      // Resolve/register this installation so its row can be labelled. On an
      // unpaired installation this throws pairing_required, which is expected.
      try {
        await ref
            .read(conversationCryptoProvider)
            .ensureDeviceRegistered(userId: user.id);
      } catch (_) {}
      final currentDeviceId = await store.readDeviceId(user.id);
      final api = ref.read(apiServiceProvider);
      final rows = await api.fetchDevices();
      final devices = rows.map(PairedDevice.fromJson).toList()
        ..sort((a, b) {
          if (a.id == currentDeviceId) return -1;
          if (b.id == currentDeviceId) return 1;
          if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
          return a.id.compareTo(b.id);
        });

      if (!mounted) return;
      setState(() {
        _devices = devices;
        _currentDeviceId = currentDeviceId;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _describe(error);
      });
    }
  }

  Future<void> _pairNewDevice() async {
    final paired = await context.push<bool>('/settings/devices/pair');
    if (paired == true) await _load();
  }

  Future<void> _linkThisDevice() async {
    final linked = await context.push<bool>('/settings/devices/scan');
    if (linked == true) await _load();
  }

  Future<void> _revoke(PairedDevice device) async {
    final confirmed = await ConfirmPopup.show(
      context,
      title: 'Revoke device?',
      message:
          'The device is signed out immediately. Every conversation rotates '
          'to a new key that the revoked device cannot read.',
      confirmLabel: 'Revoke',
      cancelLabel: 'Cancel',
    );
    if (!confirmed || !mounted) return;

    setState(() => _revoking = true);
    try {
      await ref.read(apiServiceProvider).revokeDevice(device.id);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device revoked')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not revoke device: ${_describe(error)}')),
      );
    } finally {
      if (mounted) setState(() => _revoking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final username = ref.watch(authProvider).user?.username;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Linked devices'),
        leading: IconButton(
          icon: const HugeIcon(icon: HugeIcons.strokeRoundedArrowLeft01),
          onPressed: () => context.canPop() ? context.pop() : context.go('/settings'),
          tooltip: 'Back',
        ),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Text(
                  username == null
                      ? 'Each linked device holds its own copy of your '
                          'conversation keys.'
                      : 'Devices linked to $username each hold their own copy '
                          'of your conversation keys.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.add_link),
                title: const Text('Pair a new device'),
                subtitle: const Text('Show a QR code from this device'),
                trailing: const HugeIcon(
                  icon: HugeIcons.strokeRoundedArrowRight01,
                  size: 20,
                ),
                onTap: _pairNewDevice,
              ),
              ListTile(
                leading: const Icon(Icons.qr_code_scanner),
                title: const Text('Link this device'),
                subtitle: const Text('Scan a QR code from a linked device'),
                trailing: const HugeIcon(
                  icon: HugeIcons.strokeRoundedArrowRight01,
                  size: 20,
                ),
                onTap: _linkThisDevice,
              ),
              const Divider(height: 24),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'THIS ACCOUNT',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                _ErrorPanel(message: _error!, onRetry: _load)
              else if (_devices.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Text('No devices are linked to this account yet.'),
                )
              else
                ..._devices.map(
                  (device) => _DeviceTile(
                    device: device,
                    current: device.id == _currentDeviceId,
                    busy: _revoking,
                    onRevoke: () => _revoke(device),
                  ),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: HugeIcon(
                        icon: HugeIcons.strokeRoundedShieldKey,
                        size: 16,
                      ),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Pairing is approved on a device you already trust. '
                        'Flexiyo never sends plaintext conversation keys to '
                        'the server.',
                        style: TextStyle(fontSize: 12, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.current,
    required this.busy,
    required this.onRevoke,
  });

  final PairedDevice device;
  final bool current;
  final bool busy;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = <String>[
      current ? 'This device' : _statusLabel(device),
      'Conversation key',
      if (device.lastSeenAt != null) _relativeTime(device.lastSeenAt!),
    ].join(' • ');

    return ListTile(
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: current
            ? theme.colorScheme.primary.withValues(alpha: 0.14)
            : theme.colorScheme.surfaceContainerHighest,
        child: HugeIcon(
          icon: current
              ? HugeIcons.strokeRoundedPhone
              : HugeIcons.strokeRoundedComputerPhoneSync,
          size: 20,
          color: current ? theme.colorScheme.primary : null,
        ),
      ),
      title: Text(
        current ? 'This device' : 'Linked device',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(subtitle),
      trailing: device.isActive && !current
          ? IconButton(
              tooltip: 'Revoke device',
              onPressed: busy ? null : onRevoke,
              icon: const HugeIcon(
                icon: HugeIcons.strokeRoundedDelete02,
                size: 20,
                color: Color(0xFFFF2E63),
              ),
            )
          : null,
    );
  }

  String _statusLabel(PairedDevice device) {
    if (device.wasRevoked) return 'Revoked';
    switch (device.status) {
      case 'active':
        return 'Active';
      case 'pending':
        return 'Awaiting approval';
      default:
        return device.status;
    }
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        children: [
          const HugeIcon(
            icon: HugeIcons.strokeRoundedAlert02,
            size: 32,
            color: Color(0xFFFF2E63),
          ),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: onRetry,
            icon: const HugeIcon(icon: HugeIcons.strokeRoundedRefresh, size: 18),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

String _relativeTime(int unixSeconds) {
  final when = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
  final diff = DateTime.now().difference(when);
  if (diff.inSeconds < 60) return 'seen just now';
  if (diff.inMinutes < 60) return 'seen ${diff.inMinutes}m ago';
  if (diff.inHours < 24) return 'seen ${diff.inHours}h ago';
  if (diff.inDays < 7) return 'seen ${diff.inDays}d ago';
  final month = when.month.toString().padLeft(2, '0');
  final day = when.day.toString().padLeft(2, '0');
  return 'seen ${when.year}-$month-$day';
}

String _describe(Object error) {
  if (error is FlexiyoException) return error.message;
  final text = error.toString();
  for (final prefix in ['Exception: ', 'Bad state: ']) {
    if (text.startsWith(prefix)) return text.substring(prefix.length);
  }
  return text;
}
