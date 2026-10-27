import 'dart:async';

import 'package:app_update/app_update.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rejects insecure remote APK URLs', () {
    final result = AppUpdateService.parseResponse({
      'update_available': true,
      'version_name': '1.1.0',
      'download_url': 'http://example.com/app.apk',
    });
    expect(result.status, UpdateCheckStatus.failed);
  });

  test('download query failure cancels the native download task', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    var cancelled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app_update'), (
          call,
        ) async {
          if (call.method == 'startDownload') {
            return {'downloadId': 9, 'filePath': '/tmp/app.apk'};
          }
          if (call.method == 'cancelDownload') {
            cancelled = true;
            return true;
          }
          throw PlatformException(code: 'query_failed');
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app_update'), null),
    );

    final result = await AppUpdateService(
      updateApiUrl: 'https://example.com/update',
    ).downloadAndInstall('https://example.com/app.apk', version: '1.1.0');

    expect(result, isFalse);
    expect(cancelled, isTrue);
  });

  test('a cancelled run cannot overwrite a retry', () async {
    const update = AppUpdateInfo(
      versionName: '1.1.0',
      downloadUrl: 'https://example.com/app.apk',
      forceUpdate: false,
    );
    final first = Completer<bool>();
    final second = Completer<bool>();
    final service = _QueuedUpdateService([first, second]);
    addTearDown(service.close);
    final controller = UpdateDownloadController(
      service: service,
      update: update,
    );

    final firstRun = controller.start();
    await Future<void>.delayed(Duration.zero);
    await controller.cancel();
    final retry = controller.retry();
    first.complete(false);
    second.complete(true);
    await Future.wait([firstRun, retry]);

    expect(controller.state, UpdateDownloadState.installed);
  });
}

class _QueuedUpdateService extends AppUpdateService {
  _QueuedUpdateService(this.results)
    : super(updateApiUrl: 'https://example.com/update');

  final List<Completer<bool>> results;
  var calls = 0;

  @override
  Future<bool> downloadAndInstall(
    String downloadUrl, {
    required String version,
    Duration downloadTimeout = const Duration(minutes: 30),
    Duration inactivityTimeout = const Duration(seconds: 30),
    bool wifiOnly = false,
    String? expectedSha256,
    int? expectedSize,
    void Function(double progress)? onProgress,
    void Function(int downloadId)? onStarted,
    void Function(String filePath)? onDownloaded,
    void Function(UpdateFailure failure)? onFailure,
  }) {
    onStarted?.call(++calls);
    return results[calls - 1].future;
  }

  @override
  Future<bool> cancelDownload(int downloadId) async => true;
}
