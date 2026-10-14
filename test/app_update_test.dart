import 'package:flexiyo/models/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a full update-available response', () {
    final info = AppUpdateInfo.fromJson(const {
      'updateAvailable': true,
      'latestVersion': '1.3.0',
      'version': '1.3.0',
      'name': 'Release 1.3.0',
      'releaseUrl':
          'https://github.com/kaushalkrishnax/flexiyo/releases/tag/v1.3.0',
      'apkUrl': 'https://example.com/app-arm64-v8a-release.apk',
      'forceUpdate': true,
      'changelog': {
        'Features': ['In-app updates', 'Faster sync'],
        'Fixes': ['Crash on launch'],
      },
    });

    expect(info.updateAvailable, isTrue);
    expect(info.forceUpdate, isTrue);
    expect(info.latestVersion, '1.3.0');
    expect(info.releaseName, 'Release 1.3.0');
    expect(info.isInstallable, isTrue);
    expect(info.changelog['Features'], ['In-app updates', 'Faster sync']);
    expect(info.changelog['Fixes'], ['Crash on launch']);
  });

  test('falls back to the nested apk.url when apkUrl is absent', () {
    final info = AppUpdateInfo.fromJson(const {
      'updateAvailable': true,
      'version': '2.0.0',
      'apk': {'url': 'https://example.com/app.apk', 'name': 'app.apk'},
    });

    expect(info.apkUrl, 'https://example.com/app.apk');
    expect(info.latestVersion, '2.0.0');
    expect(info.isInstallable, isTrue);
  });

  test('parses an up-to-date response', () {
    final info = AppUpdateInfo.fromJson(const {
      'updateAvailable': false,
      'latestVersion': '1.0.0',
      'apkUrl': 'https://example.com/app.apk',
    });

    expect(info.updateAvailable, isFalse);
    expect(info.forceUpdate, isFalse);
    expect(info.changelog, isEmpty);
  });

  test('is not installable without an apk url', () {
    final info = AppUpdateInfo.fromJson(const {
      'updateAvailable': true,
      'latestVersion': '1.1.0',
    });

    expect(info.isInstallable, isFalse);
  });

  test('parses severity and publishedAt', () {
    final high = AppUpdateInfo.fromJson(const {
      'updateAvailable': true,
      'latestVersion': '1.3.0',
      'severity': 'high',
      'publishedAt': '2026-01-02T03:04:05Z',
      'apkUrl': 'https://example.com/app.apk',
    });

    expect(high.severity, 'high');
    expect(high.isHighSeverity, isTrue);
    expect(high.publishedAt?.toUtc().year, 2026);

    final low = AppUpdateInfo.fromJson(const {
      'updateAvailable': true,
      'latestVersion': '1.4.0-beta.1',
      'severity': 'low',
      'apkUrl': 'https://example.com/app.apk',
    });

    expect(low.isHighSeverity, isFalse);
  });

  test('defaults severity to low when absent', () {
    final info = AppUpdateInfo.fromJson(const {
      'updateAvailable': true,
      'latestVersion': '1.2.0',
      'apkUrl': 'https://example.com/app.apk',
    });

    expect(info.severity, 'low');
    expect(info.isHighSeverity, isFalse);
  });

  test('renders release notes from the changelog', () {
    final info = AppUpdateInfo.fromJson(const {
      'updateAvailable': true,
      'latestVersion': '1.3.0',
      'apkUrl': 'https://example.com/app.apk',
      'changelog': {
        'Features': ['In-app updates'],
        'Fixes': ['Crash on launch'],
      },
    });

    expect(info.releaseNotes, contains('**Features**'));
    expect(info.releaseNotes, contains('* In-app updates'));
    expect(info.releaseNotes, contains('**Fixes**'));
    expect(info.releaseNotes, contains('* Crash on launch'));
  });

  test('release notes are empty without a changelog', () {
    final info = AppUpdateInfo.fromJson(const {
      'updateAvailable': true,
      'latestVersion': '1.3.0',
      'apkUrl': 'https://example.com/app.apk',
    });

    expect(info.releaseNotes, isEmpty);
  });
}
