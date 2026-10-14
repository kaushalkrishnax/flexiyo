import 'package:flutter/foundation.dart';

/// Payload returned by `POST /api/update/check`.
@immutable
class AppUpdateInfo {
  const AppUpdateInfo({
    required this.updateAvailable,
    required this.apkUrl,
    this.latestVersion,
    this.releaseName,
    this.releaseUrl,
    this.forceUpdate = false,
    this.severity = 'low',
    this.publishedAt,
    this.changelog = const {},
  });

  final bool updateAvailable;
  final String? apkUrl;
  final String? latestVersion;
  final String? releaseName;
  final String? releaseUrl;
  final bool forceUpdate;

  /// 'high' for stable releases, 'low' for pre-releases (beta/rc).
  final String severity;
  final DateTime? publishedAt;
  final Map<String, List<String>> changelog;

  bool get isInstallable => apkUrl != null && apkUrl!.isNotEmpty;

  bool get isHighSeverity => severity == 'high';

  /// Changelog rendered as a single markdown-ish string for display.
  String get releaseNotes {
    if (changelog.isEmpty) return '';
    final buffer = StringBuffer();
    changelog.forEach((section, items) {
      buffer.writeln('**$section**');
      for (final item in items) {
        buffer.writeln('* $item');
      }
    });
    return buffer.toString().trim();
  }

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    final apk = json['apk'] is Map ? json['apk'] as Map : const {};

    final changelogRaw = json['changelog'];
    final changelog = <String, List<String>>{};
    if (changelogRaw is Map) {
      changelogRaw.forEach((key, value) {
        if (value is List) {
          changelog['$key'] = value.map((e) => '$e').toList();
        }
      });
    }

    return AppUpdateInfo(
      updateAvailable: json['updateAvailable'] == true,
      apkUrl: (json['apkUrl'] as String?) ?? (apk['url'] as String?),
      latestVersion:
          (json['latestVersion'] as String?) ?? (json['version'] as String?),
      releaseName: json['name'] as String?,
      releaseUrl: json['releaseUrl'] as String?,
      forceUpdate: json['forceUpdate'] == true,
      severity: (json['severity'] as String?) ?? 'low',
      publishedAt: _parseDate(json['publishedAt']),
      changelog: changelog,
    );
  }

  Map<String, dynamic> toJson() => {
        'updateAvailable': updateAvailable,
        'apkUrl': apkUrl,
        'latestVersion': latestVersion,
        'name': releaseName,
        'releaseUrl': releaseUrl,
        'forceUpdate': forceUpdate,
        'severity': severity,
        'publishedAt': publishedAt?.toIso8601String(),
        'changelog': changelog,
      };

  static DateTime? _parseDate(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }
}
