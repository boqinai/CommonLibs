import 'dart:async';

import 'package:app_update/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const update = AppUpdateInfo(
    versionName: '1.1.0',
    downloadUrl: 'https://example.com/app.apk',
    forceUpdate: false,
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
    expect(controller.state, UpdateDownloadState.installed);
    expect(service.wifiOnly, isTrue);
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
}

class _FakeUpdateService extends AppUpdateService {
  _FakeUpdateService({this.result = false, this.pending})
    : super(updateApiUrl: 'https://example.com/update');

  final bool result;
  final Completer<bool>? pending;
  bool? wifiOnly;
  int? cancelledId;

  @override
  Future<bool> downloadAndInstall(
    String downloadUrl, {
    required String version,
    Duration downloadTimeout = const Duration(minutes: 30),
    bool wifiOnly = false,
    void Function(double progress)? onProgress,
    void Function(int downloadId)? onStarted,
  }) async {
    this.wifiOnly = wifiOnly;
    onStarted?.call(7);
    onProgress?.call(0.5);
    return pending?.future ?? result;
  }

  @override
  Future<bool> cancelDownload(int downloadId) async {
    cancelledId = downloadId;
    return true;
  }
}
