import 'package:flexiyo/core/exceptions.dart';
import 'package:flexiyo/models/app_update.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/services/update_service.dart';
import 'package:flutter_riverpod/legacy.dart';

enum UpdateDownloadState { idle, downloading, downloadFailed, installing }

enum UpdatePrompt { none, installPermission, installPermissionReturn }

/// Immutable state for the in-app updater
class UpdateState {
  const UpdateState({
    this.visible = false,
    this.updateAvailable = false,
    this.forceUpdate = false,
    this.severity = 'low',
    this.prompt = UpdatePrompt.none,
    this.latestVersion,
    this.apkUrl,
    this.releaseName,
    this.releaseUrl,
    this.releaseNotes = '',
    this.seenVersion,
    this.downloadState = UpdateDownloadState.idle,
    this.progress = 0,
    this.error,
  });

  final bool visible;
  final bool updateAvailable;
  final bool forceUpdate;

  /// 'high' for stable releases, 'low' for pre-releases.
  final String severity;
  final UpdatePrompt prompt;
  final String? latestVersion;
  final String? apkUrl;
  final String? releaseName;
  final String? releaseUrl;

  /// Formatted release notes for display.
  final String releaseNotes;

  /// Last version the user has already been shown.
  final String? seenVersion;
  final UpdateDownloadState downloadState;
  final double progress;
  final String? error;

  bool get isBusy =>
      downloadState == UpdateDownloadState.downloading ||
      downloadState == UpdateDownloadState.installing;

  bool get isPermissionPrompt =>
      prompt == UpdatePrompt.installPermission ||
      prompt == UpdatePrompt.installPermissionReturn;

  /// Whether this version has already been shown to the user.
  bool get isAlreadySeen =>
      latestVersion != null && latestVersion == seenVersion;

  UpdateState copyWith({
    bool? visible,
    bool? updateAvailable,
    bool? forceUpdate,
    String? severity,
    UpdatePrompt? prompt,
    String? latestVersion,
    String? apkUrl,
    String? releaseName,
    String? releaseUrl,
    String? releaseNotes,
    String? seenVersion,
    UpdateDownloadState? downloadState,
    double? progress,
    String? error,
    bool clearError = false,
  }) {
    return UpdateState(
      visible: visible ?? this.visible,
      updateAvailable: updateAvailable ?? this.updateAvailable,
      forceUpdate: forceUpdate ?? this.forceUpdate,
      severity: severity ?? this.severity,
      prompt: prompt ?? this.prompt,
      latestVersion: latestVersion ?? this.latestVersion,
      apkUrl: apkUrl ?? this.apkUrl,
      releaseName: releaseName ?? this.releaseName,
      releaseUrl: releaseUrl ?? this.releaseUrl,
      releaseNotes: releaseNotes ?? this.releaseNotes,
      seenVersion: seenVersion ?? this.seenVersion,
      downloadState: downloadState ?? this.downloadState,
      progress: progress ?? this.progress,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Owns the updater flow and exposes it to the UI via Riverpod.
class UpdateController extends StateNotifier<UpdateState> {
  UpdateController(this._service) : super(const UpdateState());

  final UpdateService _service;
  String? _seenVersion;

  /// Performs the (throttled) launch check and routes the result.
  Future<void> checkForUpdates() async {
    final info = await _service.checkForUpdates();
    if (info == null) return;
    _handleCheckResponse(info);
  }

  /// Manual check (e.g. from Settings); ignores the 24h throttle.
  Future<void> checkManually() async {
    final info = await _service.checkForUpdates(ignoreThrottle: true);
    if (info == null) return;
    _handleCheckResponse(info);
  }

  /// Loads the persisted seen-version so the dialog never re-nags.
  Future<void> loadSeenVersion() async {
    _seenVersion = await _service.getSeenVersion();
    state = state.copyWith(seenVersion: _seenVersion);
  }

  void _handleCheckResponse(AppUpdateInfo info) {
    if (!info.updateAvailable) return;

    setUpdateAvailable(info);

    // Show every unseen release, including beta and release-candidate builds.
    final unseen =
        info.latestVersion != null && info.latestVersion != _seenVersion;
    if (info.isHighSeverity && unseen) {
      openUpdateDialog();
    }
  }

  void setUpdateAvailable(AppUpdateInfo info) {
    state = UpdateState(
      updateAvailable: true,
      forceUpdate: info.forceUpdate,
      severity: info.severity,
      prompt: UpdatePrompt.none,
      latestVersion: info.latestVersion,
      apkUrl: info.apkUrl,
      releaseName: info.releaseName,
      releaseUrl: info.releaseUrl,
      releaseNotes: info.releaseNotes,
      seenVersion: _seenVersion,
      downloadState: UpdateDownloadState.idle,
      progress: 0,
    );
  }

  /// Opens the dialog when an update is available.
  void openUpdateDialog() {
    if (state.updateAvailable) {
      state = state.copyWith(visible: true);
    }
  }

  /// Marks the current version as seen so it is not auto-shown again.
  Future<void> markSeen() async {
    final version = state.latestVersion;
    if (version == null) return;
    await _service.markVersionSeen(version);
    _seenVersion = version;
    state = state.copyWith(seenVersion: version);
  }

  void clearUpdateAvailable() {
    state = const UpdateState();
  }

  /// Dismisses the dialog unless it is a forced update.
  void hideUpdate() {
    if (state.forceUpdate) return;
    state = state.copyWith(
      visible: false,
      prompt: UpdatePrompt.none,
      clearError: true,
    );
  }

  void setPrompt(UpdatePrompt prompt) {
    state = state.copyWith(prompt: prompt);
  }

  void setDownloadState(UpdateDownloadState downloadState) {
    state = state.copyWith(downloadState: downloadState);
  }

  void setProgress(double progress) {
    state = state.copyWith(progress: progress);
  }

  void resetFlow() {
    state = state.copyWith(
      prompt: UpdatePrompt.none,
      downloadState: UpdateDownloadState.idle,
      progress: 0,
      clearError: true,
    );
  }

  void completeFlow() {
    state = const UpdateState();
  }

  Future<void> openInstallPermissionSettings() =>
      _service.openInstallPermissionSettings();

  Future<void> openReleaseUrl(String url) => _service.openUrl(url);

  /// Runs the permission-gated download/install flow.
  Future<void> startDownloadAndInstall() async {
    final apkUrl = state.apkUrl;
    if (apkUrl == null || apkUrl.isEmpty) return;

    final hasPermission = await _service.canInstallPackages();
    if (!hasPermission) {
      _requestInstallPermission();
      return;
    }

    state = state.copyWith(
      clearError: true,
      progress: 0,
      downloadState: UpdateDownloadState.downloading,
    );

    try {
      await _service.downloadAndInstall(
        apkUrl: apkUrl,
        onProgress: setProgress,
      );
      state = state.copyWith(downloadState: UpdateDownloadState.installing);
      completeFlow();
    } on InstallPermissionRequiredException {
      _requestInstallPermission();
    } on FlexiyoException catch (e) {
      state = state.copyWith(
        downloadState: UpdateDownloadState.downloadFailed,
        error: e.message,
        prompt: UpdatePrompt.none,
      );
    } catch (_) {
      state = state.copyWith(
        downloadState: UpdateDownloadState.downloadFailed,
        error: 'Could not download update.',
        prompt: UpdatePrompt.none,
      );
    }
  }

  void _requestInstallPermission() {
    state = state.copyWith(
      prompt: UpdatePrompt.installPermission,
      clearError: true,
      downloadState: UpdateDownloadState.idle,
    );
    openUpdateDialog();
  }
}

final updateControllerProvider =
    StateNotifierProvider<UpdateController, UpdateState>((ref) {
  final api = ref.watch(apiServiceProvider);
  final controller = UpdateController(UpdateService(api));
  controller.loadSeenVersion();
  return controller;
});
