import 'package:flexiyo/app/app.dart';
import 'package:flexiyo/storage/local_db.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalDb.instance.initialize();
  runApp(const ProviderScope(child: FlexiyoApp()));
}
