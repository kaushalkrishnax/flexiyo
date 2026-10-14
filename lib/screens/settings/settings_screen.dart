import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/providers/update_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
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
              leading: const Icon(Icons.person_outline_rounded),
              title: const Text('Account'),
              subtitle: Text(authState.user?.username ?? 'Signed out'),
            ),
            const ListTile(
              leading: Icon(Icons.lock_outline_rounded),
              title: Text('Privacy'),
              subtitle: Text('End-to-end encryption is enabled by the client.'),
            ),
            const ListTile(
              leading: Icon(Icons.dark_mode_outlined),
              title: Text('Appearance'),
              subtitle: Text('Follow system theme'),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.system_update_alt_rounded),
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
              leading: const Icon(Icons.logout_rounded, color: Colors.red),
              title: const Text('Log out'),
              onTap: () async {
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
}
