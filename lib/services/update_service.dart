import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory;

import 'package:dio/dio.dart';
import 'package:flexiyo/core/exceptions.dart';
import 'package:flexiyo/models/app_update.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Native bridge implemented by MainActivity.kt on Android.
const MethodChannel _appUpdateChannel = MethodChannel(
  'com.flexiyo.flexiyo/app_update',
);

const String _updateCheckCacheKey = 'flexiyo.update_check_cache';
const String _updateApkPathKey = 'flexiyo.update_apk_path';
const String _lastCheckedKey = 'flexiyo.update_last_checked';
const String _seenVersionKey = 'flexiyo.update_seen_version';

/// Minimum time between automatic update checks (24h).
const Duration _checkInterval = Duration(hours: 24);

bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

class UpdateService {
  UpdateService(this._api);

  final ApiService _api;

  Future<AppUpdateInfo?> checkForUpdates({bool ignoreThrottle = false}) async {
    if (!_isAndroid && !_isIOS) return null;

    if (!ignoreThrottle && !await _shouldCheckNow()) return null;

    try {
      final version = await getCurrentVersion();
      final arch = _isAndroid ? await getDeviceArchitecture() : '';
      final platform = _isIOS ? 'ios' : 'android';

      final data = await _api.checkForUpdate(
        version: version,
        arch: arch,
        platform: platform,
      );
      final info = AppUpdateInfo.fromJson(data);

      await _markCheckedNow();
      await _cacheResponse(info);
      return info;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _shouldCheckNow() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_lastCheckedKey) ?? 0;
    if (last == 0) return true;
    final elapsed = DateTime.now().millisecondsSinceEpoch - last;
    return elapsed >= _checkInterval.inMilliseconds;
  }

  Future<void> _markCheckedNow() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _lastCheckedKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<String?> getSeenVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_seenVersionKey);
  }

  Future<void> markVersionSeen(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_seenVersionKey, version);
  }

  Future<void> _cacheResponse(AppUpdateInfo info) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _updateCheckCacheKey,
      jsonEncode({
        'checkedAt': DateTime.now().millisecondsSinceEpoch,
        'response': info.toJson(),
      }),
    );
  }

  /// Downloads the APK, reports progress in `[0, 1]`, then opens the installer.
  Future<String> downloadAndInstall({
    required String apkUrl,
    void Function(double progress)? onProgress,
  }) async {
    if (!_isAndroid) {
      throw const FlexiyoException('Updates are only supported on Android');
    }

    final hasPermission = await canInstallPackages();
    if (!hasPermission) {
      throw const InstallPermissionRequiredException();
    }

    final apkPath = await _downloadApk(apkUrl, onProgress);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_updateApkPathKey, apkPath);

    await installApk(apkPath);
    return apkPath;
  }

  Future<String> _downloadApk(
    String apkUrl,
    void Function(double progress)? onProgress,
  ) async {
    final dir = await getTemporaryDirectory();
    final updatesDir = Directory('${dir.path}/updates');
    if (!await updatesDir.exists()) {
      await updatesDir.create(recursive: true);
    }
    final savePath = '${updatesDir.path}/app-update.apk';

    try {
      final dio = Dio();
      await dio.download(
        apkUrl,
        savePath,
        onReceiveProgress: (received, total) {
          if (onProgress == null) return;
          if (total > 0) {
            onProgress((received / total).clamp(0, 1).toDouble());
          }
        },
      );
      return savePath;
    } on DioException catch (e) {
      throw FlexiyoException(e.message ?? 'Could not download update.');
    }
  }

  Future<bool> canInstallPackages() async {
    if (!_isAndroid) return false;
    try {
      return await _appUpdateChannel.invokeMethod<bool>(
            'canInstallPackages',
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> openInstallPermissionSettings() async {
    try {
      await _appUpdateChannel.invokeMethod<void>('openInstallSettings');
    } on PlatformException {
      // Dialog stays visible so the user can retry.
    } on MissingPluginException {
      // No native channel (e.g. tests).
    }
  }

  Future<void> openUrl(String url) async {
    try {
      await _appUpdateChannel.invokeMethod<void>('openUrl', {'url': url});
    } on PlatformException {
      // Best-effort.
    } on MissingPluginException {
      // No-op outside Android.
    }
  }

  Future<void> installApk(String path) async {
    try {
      await _appUpdateChannel.invokeMethod<void>('installApk', {'path': path});
    } on PlatformException catch (e) {
      throw FlexiyoException(e.message ?? 'Could not start the installer.');
    } on MissingPluginException {
      throw const FlexiyoException(
          'Installer is unavailable on this platform.');
    }
  }

  Future<String> getCurrentVersion() async {
    if (!_isAndroid && !_isIOS) return '0.0.0';
    try {
      return await _appUpdateChannel.invokeMethod<String>('getVersion') ??
          '0.0.0';
    } on PlatformException {
      return '0.0.0';
    } on MissingPluginException {
      return '0.0.0';
    }
  }

  Future<String> getDeviceArchitecture() async {
    if (!_isAndroid) return 'arm64-v8a';
    try {
      return await _appUpdateChannel.invokeMethod<String>('getArchitecture') ??
          'arm64-v8a';
    } on PlatformException {
      return 'arm64-v8a';
    } on MissingPluginException {
      return 'arm64-v8a';
    }
  }
}

/// Thrown when the user has not granted "install unknown apps" permission.
class InstallPermissionRequiredException extends FlexiyoException {
  const InstallPermissionRequiredException()
      : super('Install permission required');
}
