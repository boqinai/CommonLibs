import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_update.dart';

enum UpdateDownloadState { idle, downloading, installed, failed, cancelled }

class UpdateDownloadController extends ChangeNotifier {
  UpdateDownloadController({
    required this.service,
    required this.update,
    this.downloadTimeout = const Duration(minutes: 30),
    this.inactivityTimeout = const Duration(seconds: 30),
    this.wifiOnly = false,
  });

  final AppUpdateService service;
  final AppUpdateInfo update;
  final Duration downloadTimeout;
  final Duration inactivityTimeout;
  final bool wifiOnly;

  UpdateDownloadState state = UpdateDownloadState.idle;
  double? progress;
  int? downloadId;
  String? downloadedFilePath;
  UpdateFailure? failure;
  int _generation = 0;
  bool _disposed = false;

  Future<void> start() async {
    if (state == UpdateDownloadState.downloading) return;
    final generation = ++_generation;
    state = UpdateDownloadState.downloading;
    progress = null;
    downloadId = null;
    downloadedFilePath = null;
    failure = null;
    _notify();

    bool installed;
    try {
      installed = await service.downloadAndInstall(
        update.downloadUrl,
        version: update.versionName,
        downloadTimeout: downloadTimeout,
        inactivityTimeout: inactivityTimeout,
        wifiOnly: wifiOnly,
        expectedSha256: update.sha256,
        expectedMd5: update.md5,
        expectedSize: update.fileSize,
        onStarted: (id) {
          if (generation != _generation || _disposed) {
            unawaited(service.cancelDownload(id));
            return;
          }
          downloadId = id;
          _notify();
        },
        onProgress: (value) {
          if (generation != _generation || _disposed) return;
          progress = value;
          _notify();
        },
        onDownloaded: (path) {
          if (generation != _generation || _disposed) return;
          downloadedFilePath = path;
          _notify();
        },
        onFailure: (value) {
          if (generation != _generation || _disposed) return;
          failure = value;
          _notify();
        },
      );
    } catch (_) {
      installed = false;
    }
    if (generation != _generation || _disposed) return;
    if (!installed && failure == null) {
      failure = const UpdateFailure(
        UpdateFailureCode.platform,
        '系统未能打开 APK 安装器',
      );
    }
    state = installed
        ? UpdateDownloadState.installed
        : UpdateDownloadState.failed;
    _notify();
  }

  Future<void> retry() => downloadedFilePath == null ? start() : install();

  /// 重新打开已经下载完成的 APK，不会再次发起下载。
  Future<void> install() async {
    if (state == UpdateDownloadState.downloading ||
        downloadedFilePath == null) {
      return;
    }
    final generation = ++_generation;
    failure = null;
    final installed = await service.openApk(downloadedFilePath!);
    if (generation != _generation || _disposed) return;
    if (!installed) {
      failure = const UpdateFailure(
        UpdateFailureCode.platform,
        '系统未能打开 APK 安装器',
      );
    }
    state = installed
        ? UpdateDownloadState.installed
        : UpdateDownloadState.failed;
    _notify();
  }

  Future<void> cancel() async {
    if (state != UpdateDownloadState.downloading) return;
    final id = downloadId;
    ++_generation;
    state = UpdateDownloadState.cancelled;
    _notify();
    if (id != null) await service.cancelDownload(id);
  }

  @override
  void dispose() {
    final id = state == UpdateDownloadState.downloading ? downloadId : null;
    _disposed = true;
    ++_generation;
    if (id != null) unawaited(service.cancelDownload(id));
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
