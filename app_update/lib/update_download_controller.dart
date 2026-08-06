import 'package:flutter/foundation.dart';

import 'app_update.dart';

enum UpdateDownloadState { idle, downloading, installed, failed, cancelled }

class UpdateDownloadController extends ChangeNotifier {
  UpdateDownloadController({
    required this.service,
    required this.update,
    this.downloadTimeout = const Duration(minutes: 30),
    this.wifiOnly = false,
  });

  final AppUpdateService service;
  final AppUpdateInfo update;
  final Duration downloadTimeout;
  final bool wifiOnly;

  UpdateDownloadState state = UpdateDownloadState.idle;
  double? progress;
  int? downloadId;

  Future<void> start() async {
    if (state == UpdateDownloadState.downloading) return;
    state = UpdateDownloadState.downloading;
    progress = null;
    downloadId = null;
    notifyListeners();

    final installed = await service.downloadAndInstall(
      update.downloadUrl,
      version: update.versionName,
      downloadTimeout: downloadTimeout,
      wifiOnly: wifiOnly,
      onStarted: (id) {
        downloadId = id;
        notifyListeners();
      },
      onProgress: (value) {
        progress = value;
        notifyListeners();
      },
    );
    if (state == UpdateDownloadState.cancelled) return;
    state = installed
        ? UpdateDownloadState.installed
        : UpdateDownloadState.failed;
    notifyListeners();
  }

  Future<void> retry() => start();

  Future<void> cancel() async {
    final id = downloadId;
    if (id == null || state != UpdateDownloadState.downloading) return;
    state = UpdateDownloadState.cancelled;
    notifyListeners();
    await service.cancelDownload(id);
  }
}
