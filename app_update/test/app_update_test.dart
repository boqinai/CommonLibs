import 'package:app_update/app_update.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const context = UpdateRequestContext(
    packageName: 'com.boqinai.example',
    versionCode: 1000000,
    deviceId: 'device-123',
  );

  test('checks the shared update protocol', () async {
    final service = AppUpdateService(
      updateApiUrl: 'https://api.example.com/update?token=abc',
      requestContextLoader: () async => context,
      client: MockClient((request) async {
        expect(request.url.queryParameters['token'], 'abc');
        expect(
          request.url.queryParameters['package_name'],
          context.packageName,
        );
        expect(request.url.queryParameters['version_code'], '1000000');
        expect(request.url.queryParameters['device_id'], context.deviceId);
        expect(request.url.queryParameters['channel'], 'stable');
        return http.Response(
          '{"update_available":true,"version_name":"1.1.0",'
          '"download_url":"https://example.com/app.apk","force_update":true}',
          200,
        );
      }),
    );

    final result = await service.checkForUpdate();

    expect(result.status, UpdateCheckStatus.updateAvailable);
    expect(result.update?.versionName, '1.1.0');
    expect(result.update?.forceUpdate, isTrue);
  });

  test('parses optional APK integrity metadata', () {
    final digest = List.filled(64, 'a').join();
    final md5Digest = List.filled(32, 'b').join();
    final result = AppUpdateService.parseResponse({
      'update_available': true,
      'version_name': '1.1.0',
      'download_url': 'https://example.com/app.apk',
      'sha256': digest,
      'md5': md5Digest,
      'file_size': 1024,
    });

    expect(result.status, UpdateCheckStatus.updateAvailable);
    expect(result.update?.sha256, digest);
    expect(result.update?.md5, md5Digest);
    expect(result.update?.fileSize, 1024);
  });

  test('rejects malformed APK integrity metadata', () {
    expect(
      AppUpdateService.parseResponse({
        'update_available': true,
        'version_name': '1.1.0',
        'download_url': 'https://example.com/app.apk',
        'sha256': 'not-a-digest',
      }).status,
      UpdateCheckStatus.failed,
    );
    expect(
      AppUpdateService.parseResponse({
        'update_available': true,
        'version_name': '1.1.0',
        'download_url': 'https://example.com/app.apk',
        'md5': 'short-md5',
      }).status,
      UpdateCheckStatus.failed,
    );
  });

  test('uses the native downloader and opens the downloaded APK', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    var progressQueries = 0;
    var opened = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app_update'), (
          call,
        ) async {
          switch (call.method) {
            case 'startDownload':
              expect(call.arguments['url'], contains('v=1.1.0'));
              return {'downloadId': 7, 'filePath': '/tmp/app.apk'};
            case 'getDownloadProgress':
              progressQueries++;
              return progressQueries == 1
                  ? {'status': 2, 'bytesDownloaded': 5, 'totalBytes': 10}
                  : {'status': 8, 'bytesDownloaded': 10, 'totalBytes': 10};
            case 'openApk':
              opened = true;
              return true;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app_update'), null),
    );
    int? downloadId;
    final progress = <double>[];

    final installed =
        await AppUpdateService(
          updateApiUrl: 'https://api.example.com/update',
          requestContextLoader: () async => context,
        ).downloadAndInstall(
          'https://example.com/app.apk?token=abc',
          version: '1.1.0',
          onStarted: (id) => downloadId = id,
          onProgress: progress.add,
        );

    expect(installed, isTrue);
    expect(downloadId, 7);
    expect(progress, [0.5, 1]);
    expect(opened, isTrue);
  });

  test('rejects incomplete or unsafe server data', () {
    expect(
      AppUpdateService.parseResponse({
        'update_available': true,
        'version_name': '1.1.0',
        'download_url': 'file:///tmp/app.apk',
      }).status,
      UpdateCheckStatus.failed,
    );
  });

  test('close releases the HTTP client', () {
    final client = _TrackingClient();
    final service = AppUpdateService(
      updateApiUrl: 'https://api.example.com/update',
      client: client,
    );

    service.close();

    expect(client.closed, isTrue);
  });

  test('download timeout cancels the native download task', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    var cancelled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app_update'), (
          call,
        ) async {
          if (call.method == 'startDownload') {
            return {'downloadId': 7, 'filePath': '/tmp/app.apk'};
          }
          if (call.method == 'cancelDownload') {
            cancelled = true;
            return true;
          }
          return {'status': 4, 'bytesDownloaded': 5, 'totalBytes': 10};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app_update'), null),
    );

    final installed =
        await AppUpdateService(
          updateApiUrl: 'https://api.example.com/update',
        ).downloadAndInstall(
          'https://example.com/app.apk',
          version: '1.1.0',
          downloadTimeout: Duration.zero,
        );

    expect(installed, isFalse);
    expect(cancelled, isTrue);
  });

  test('preserves native dataSync timeout as a timed-out failure', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    var cancelled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app_update'), (
          call,
        ) async {
          if (call.method == 'startDownload') {
            return {'downloadId': 8, 'filePath': '/tmp/app.apk'};
          }
          if (call.method == 'cancelDownload') {
            cancelled = true;
            return true;
          }
          return {
            'status': 16,
            'bytesDownloaded': 5,
            'totalBytes': 10,
            'errorCode': 'data_sync_timeout',
            'errorMessage': 'Android dataSync limit reached',
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app_update'), null),
    );
    UpdateFailure? failure;

    final installed =
        await AppUpdateService(
          updateApiUrl: 'https://api.example.com/update',
        ).downloadAndInstall(
          'https://example.com/app.apk',
          version: '1.1.0',
          downloadTimeout: const Duration(seconds: 2),
          onFailure: (value) => failure = value,
        );

    expect(installed, isFalse);
    expect(failure?.code, UpdateFailureCode.timedOut);
    expect(failure?.message, 'Android dataSync limit reached');
    expect(cancelled, isFalse);
  });
}

class _TrackingClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(const Stream<List<int>>.empty(), 200);

  @override
  void close() => closed = true;
}
