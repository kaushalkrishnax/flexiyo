import 'dart:io';

import 'package:flexiyo/providers/update_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// On Android it offers an in-app APK install; on iOS (and as a fallback) the
// primary action opens the release page in the browser.
class AppUpdateDialog extends ConsumerStatefulWidget {
  const AppUpdateDialog({super.key});

  @override
  ConsumerState<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends ConsumerState<AppUpdateDialog> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(updateControllerProvider);
    final controller = ref.read(updateControllerProvider.notifier);
    final theme = Theme.of(context);

    if (!state.visible) return const SizedBox.shrink();

    // Mark this version as seen so it is not auto-shown again.
    if (!state.isAlreadySeen) {
      controller.markSeen();
    }

    final isPermissionPrompt = state.isPermissionPrompt;
    final canInstall =
        Platform.isAndroid && state.apkUrl != null && state.apkUrl!.isNotEmpty;
    final isBusy = state.isBusy;

    final title =
        isPermissionPrompt ? 'Permission Required' : 'Update Available';

    final statusMessage = state.downloadState == UpdateDownloadState.installing
        ? 'Opening the Android installer...'
        : state.forceUpdate
            ? 'This update is required to continue.'
            : 'A newer version of Flexiyo is ready to install.';

    final bodyText = isPermissionPrompt
        ? (state.prompt == UpdatePrompt.installPermission
            ? 'To install this update, allow installs from this app in your '
                'Android settings. Tap Continue to proceed.'
            : 'Tap Continue to resume the update.')
        : statusMessage;

    final primaryLabel = isPermissionPrompt
        ? 'Continue'
        : !canInstall
            ? 'View Release'
            : state.downloadState == UpdateDownloadState.downloadFailed
                ? 'Retry'
                : 'Update';

    final dismissible = !state.forceUpdate && !isBusy;

    return Positioned.fill(
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            // Tap-outside barrier (only dismissable for optional updates).
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: dismissible
                    ? () {
                        controller.setPrompt(UpdatePrompt.none);
                        controller.hideUpdate();
                      }
                    : null,
                child: const ColoredBox(color: Colors.black54),
              ),
            ),
            Center(
              child: AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                title: Text(title),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _LabelValue(
                        label: 'Version',
                        value: state.latestVersion ?? 'Unknown',
                      ),
                      const SizedBox(height: 8),
                      Text(bodyText, style: theme.textTheme.bodyMedium),
                      if (state.releaseNotes.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "What's new",
                                style: theme.textTheme.labelLarge,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                state.releaseNotes,
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (state.downloadState ==
                              UpdateDownloadState.downloading ||
                          state.downloadState ==
                              UpdateDownloadState.installing) ...[
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: state.progress > 0 && state.progress < 1
                                ? state.progress
                                : null,
                            minHeight: 6,
                          ),
                        ),
                      ],
                      if (state.error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          state.error!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  if (!state.forceUpdate && !isBusy)
                    TextButton(
                      onPressed: () {
                        controller.setPrompt(UpdatePrompt.none);
                        controller.hideUpdate();
                      },
                      child: Text(isPermissionPrompt ? 'Cancel' : 'Later'),
                    ),
                  if (state.releaseUrl != null &&
                      !isBusy &&
                      !isPermissionPrompt)
                    TextButton(
                      onPressed: () =>
                          controller.openReleaseUrl(state.releaseUrl!),
                      child: const Text('View Notes'),
                    ),
                  FilledButton(
                    onPressed: isBusy
                        ? null
                        : () {
                            if (state.prompt ==
                                UpdatePrompt.installPermission) {
                              controller.setPrompt(
                                UpdatePrompt.installPermissionReturn,
                              );
                              controller.openInstallPermissionSettings();
                              return;
                            }
                            if (!canInstall) {
                              final url = state.releaseUrl;
                              controller.setPrompt(UpdatePrompt.none);
                              controller.hideUpdate();
                              if (url != null) controller.openReleaseUrl(url);
                              return;
                            }
                            controller.setPrompt(UpdatePrompt.none);
                            controller.startDownloadAndInstall();
                          },
                    child: Text(primaryLabel),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LabelValue extends StatelessWidget {
  const _LabelValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(text: value, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
