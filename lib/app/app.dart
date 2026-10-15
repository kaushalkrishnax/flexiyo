import 'package:flexiyo/app/router.dart';
import 'package:flexiyo/core/theme.dart';
import 'package:flexiyo/providers/theme_provider.dart';
import 'package:flexiyo/providers/update_provider.dart';
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
    // Fire the in-app update check once on launch (Android + iOS).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(updateControllerProvider.notifier).checkForUpdates();
    });
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
