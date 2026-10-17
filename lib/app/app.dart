import 'package:flexiyo/app/router.dart';
import 'package:flexiyo/core/theme.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/providers/theme_provider.dart';
import 'package:flexiyo/providers/update_provider.dart';
import 'package:flexiyo/services/push_service.dart';
import 'package:flexiyo/widgets/app_update_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class FlexiyoApp extends ConsumerStatefulWidget {
  const FlexiyoApp({super.key});

  @override
  ConsumerState<FlexiyoApp> createState() => _FlexiyoAppState();
}

class _FlexiyoAppState extends ConsumerState<FlexiyoApp> {
  @override
  void initState() {
    super.initState();
    // Notification taps open the conversation the message belongs to.
    PushService.onConversationOpened = _openConversationFromPush;
    // Fire the in-app update check once on launch (Android + iOS).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(updateControllerProvider.notifier).checkForUpdates();
    });
  }

  void _openConversationFromPush(String conversationId) {
    final path = '/chats/$conversationId';
    if (!ref.read(authProvider).isAuthenticated) {
      // Session not ready yet (cold start): let the redirect pick it up.
      ref.read(routerNotifierProvider).queueDeepLink(path);
      return;
    }
    ref.read(routerProvider).go(path);
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'Flexiyo',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      routerConfig: router,
      builder: (context, child) {
        return Stack(
          children: [
            if (child != null) child,
            const AppUpdateDialog(),
          ],
        );
      },
    );
  }
}
