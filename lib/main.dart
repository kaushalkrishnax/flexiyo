import 'package:flexiyo/app/app.dart';
import 'package:flexiyo/app/router.dart';
import 'package:flexiyo/storage/local_db.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  await LocalDb.instance.initialize();
  final prefs = await SharedPreferences.getInstance();
  final hasSession = prefs.getBool('flexiyo.has_session') ?? false;

  runApp(
    ProviderScope(
      overrides: [
        initialSessionProvider.overrideWithValue(hasSession),
      ],
      child: const FlexiyoApp(),
    ),
  );
}
