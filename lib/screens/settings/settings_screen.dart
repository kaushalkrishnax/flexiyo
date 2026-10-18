import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/providers/theme_provider.dart';
import 'package:flexiyo/providers/update_provider.dart';
import 'package:flexiyo/widgets/confirm_popup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hugeicons/hugeicons.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);
    final themeMode = ref.watch(themeModeProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const HugeIcon(icon: HugeIcons.strokeRoundedArrowLeft01),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/chats');
            }
          },
          tooltip: 'Back',
        ),
      ),
      body: SafeArea(
        child: ListView(
          children: [
            ListTile(
              leading: const HugeIcon(icon: HugeIcons.strokeRoundedUserCircle),
              title: const Text('Account'),
              subtitle: Text(authState.user?.username ?? 'Signed out'),
            ),
            const ListTile(
              leading: HugeIcon(icon: HugeIcons.strokeRoundedLock),
              title: Text('Privacy'),
              subtitle: Text('End-to-end encryption is enabled by the client.'),
            ),
            ListTile(
              leading: const HugeIcon(icon: HugeIcons.strokeRoundedMoon02),
              title: const Text('Appearance'),
              subtitle: Text(
                themeMode == ThemeMode.system
                    ? 'Follow system theme'
                    : (themeMode == ThemeMode.light
                        ? 'Light mode'
                        : 'Dark mode'),
              ),
              onTap: () => _showThemeDialog(context, ref, themeMode),
            ),
            const Divider(),
            ListTile(
              leading:
                  const HugeIcon(icon: HugeIcons.strokeRoundedSystemUpdate01),
              title: const Text('Check for updates'),
              subtitle: const Text('Download and install the latest release'),
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                final controller = ref.read(updateControllerProvider.notifier);
                await controller.checkManually();
                final state = ref.read(updateControllerProvider);
                if (!context.mounted) return;
                if (state.updateAvailable) {
                  controller.openUpdateDialog();
                } else {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Flexiyo is up to date')),
                  );
                }
              },
            ),
            const Divider(),
            ListTile(
              leading: const HugeIcon(
                  icon: HugeIcons.strokeRoundedLogOut, color: Colors.red),
              title: const Text('Log out'),
              onTap: () async {
                final confirmed = await _showLogoutDialog(context);
                if (!confirmed || !context.mounted) return;
                await ref.read(authProvider.notifier).logout();
                if (context.mounted) {
                  context.go('/login');
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showThemeDialog(
    BuildContext context,
    WidgetRef ref,
    ThemeMode currentMode,
  ) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Choose theme'),
          content: RadioGroup<ThemeMode>(
            groupValue: currentMode,
            onChanged: (mode) {
              if (mode != null) {
                ref.read(themeModeProvider.notifier).setThemeMode(mode);
                Navigator.of(context).pop();
              }
            },
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<ThemeMode>(
                  title: Text('System default'),
                  value: ThemeMode.system,
                ),
                RadioListTile<ThemeMode>(
                  title: Text('Light mode'),
                  value: ThemeMode.light,
                ),
                RadioListTile<ThemeMode>(
                  title: Text('Dark mode'),
                  value: ThemeMode.dark,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }

  /// Confirmation prompt shown before signing out.
  Future<bool> _showLogoutDialog(BuildContext context) {
    return ConfirmPopup.show(
      context,
      title: 'Log out?',
      message: 'You will need to sign in again to use Flexiyo.',
      confirmLabel: 'Log out',
      cancelLabel: 'Cancel',
    );
  }
}
