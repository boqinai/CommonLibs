import 'dart:async';

import 'package:app_update/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const update = AppUpdateInfo(
    versionName: '1.1.0',
    downloadUrl: 'https://example.com/app.apk',
    forceUpdate: false,
    sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    fileSize: 1024,
  );

  test('tracks progress and installed state', () async {
    final service = _FakeUpdateService(result: true);
    addTearDown(service.close);
    final controller = UpdateDownloadController(
      service: service,
      update: update,
      wifiOnly: true,
    );

    await controller.start();

    expect(controller.downloadId, 7);
    expect(controller.progress, 0.5);
    expect(controller.downloadedFilePath, '/tmp/app.apk');
    expect(controller.state, UpdateDownloadState.installed);
    expect(service.wifiOnly, isTrue);
    expect(service.expectedSha256, update.sha256);
    expect(service.expectedSize, update.fileSize);
  });

  test('retry opens the downloaded APK without downloading again', () async {
    final service = _FakeUpdateService(result: false, installResult: true);
    addTearDown(service.close);
    final controller = UpdateDownloadController(
      service: service,
      update: update,
    );

    await controller.start();
    await controller.retry();

    expect(service.downloadCalls, 1);
    expect(service.openedPath, '/tmp/app.apk');
    expect(controller.state, UpdateDownloadState.installed);
  });

  test('cancellation wins over a pending download result', () async {
    final pending = Completer<bool>();
    final service = _FakeUpdateService(pending: pending);
    addTearDown(service.close);
    final controller = UpdateDownloadController(
      service: service,
      update: update,
    );

    final started = controller.start();
    await Future<void>.delayed(Duration.zero);
    await controller.cancel();
    pending.complete(false);
    await started;

    expect(service.cancelledId, 7);
    expect(controller.state, UpdateDownloadState.cancelled);
  });

  test('dispose cancels download by default', () async {
    final pending = Completer<bool>();
    final service = _FakeUpdateService(pending: pending);
    addTearDown(service.close);
    final controller = UpdateDownloadController(
      service: service,
      update: update,
    );

    final started = controller.start();
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    pending.complete(false);
    await started;

    expect(service.cancelledId, 7);
  });

  test('dispose does not cancel download when keepDownloadingOnDispose is true', () async {
    final pending = Completer<bool>();
    final service = _FakeUpdateService(pending: pending);
    addTearDown(service.close);
    final controller = UpdateDownloadController(
      service: service,
      update: update,
    );

    final started = controller.start();
    await Future<void>.delayed(Duration.zero);
    controller.keepDownloadingOnDispose = true;
    controller.dispose();
    pending.complete(true);
    await started;

    expect(service.cancelledId, isNull);
  });
}

class _FakeUpdateService extends AppUpdateService {
  _FakeUpdateService({
    this.result = false,
    this.pending,
    this.installResult = false,
  }) : super(updateApiUrl: 'https://example.com/update');

  final bool result;
  final Completer<bool>? pending;
  final bool installResult;
  bool? wifiOnly;
  int? cancelledId;
  int downloadCalls = 0;
  String? openedPath;
  String? expectedSha256;
  String? expectedMd5;
  int? expectedSize;

  @override
  Future<bool> downloadAndInstall(
    String downloadUrl, {
    required String version,
    Duration downloadTimeout = const Duration(minutes: 30),
    Duration inactivityTimeout = const Duration(seconds: 30),
    bool wifiOnly = false,
    String? expectedSha256,
    String? expectedMd5,
    int? expectedSize,
    void Function(double progress)? onProgress,
    void Function(int downloadId)? onStarted,
    void Function(String filePath)? onDownloaded,
    void Function(UpdateFailure failure)? onFailure,
  }) async {
    downloadCalls++;
    this.wifiOnly = wifiOnly;
    this.expectedSha256 = expectedSha256;
    this.expectedMd5 = expectedMd5;
    this.expectedSize = expectedSize;
    onStarted?.call(7);
    onProgress?.call(0.5);
    onDownloaded?.call('/tmp/app.apk');
    return pending?.future ?? result;
  }

  @override
  Future<bool> openApk(String filePath) async {
    openedPath = filePath;
    return installResult;
  }

  @override
  Future<bool> cancelDownload(int downloadId) async {
    cancelledId = downloadId;
    return true;
  }
}
