/// Application-wide constants for Flexiyo.
class AppConstants {
  AppConstants._();

  static const String productionApiUrl =
      'https://flexiyo.kaushalkrishnax.workers.dev';

  /// Override via --dart-define=API_BASE_URL=http://localhost:8787 for local dev.
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: productionApiUrl,
  );

  static const String appName = 'Flexiyo';

  static const int maxMessageLength = 4000;

  /// Disappearing timer options in seconds. -1 means immediately after read.
  static const List<int> disappearingTimerOptions = [
    -1,
    3600,
    21600,
    86400,
    604800,
  ];

  static const int signalPreKeyCount = 100;
  static const int defaultDeviceId = 1;

  /// SQLite DB name.
  static const String dbName = 'flexiyo.db';
  static const int dbVersion = 1;
}
