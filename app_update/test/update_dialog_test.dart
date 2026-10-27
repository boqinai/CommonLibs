import 'package:app_update/app_update.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const update = AppUpdateInfo(
    versionName: '2.0.0',
    downloadUrl: 'https://example.com/app.apk',
    forceUpdate: false,
    releaseNotes: '提升稳定性和下载体验。',
  );

  testWidgets('starts a background download and closes the dialog', (
    tester,
  ) async {
    final service = _FakeUpdateService();
    addTearDown(service.close);
    UpdateDialogAction? action;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              action = await showDefaultUpdateDialog(
                context,
                service: service,
                update: update,
              );
            },
            child: const Text('show'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('提升稳定性和下载体验。'), findsOneWidget);

    await tester.tap(find.text('后台下载'));
    await tester.pumpAndSettle();

    expect(action, UpdateDialogAction.backgroundDownload);
    expect(service.downloadCalls, 1);
    expect(find.text('发现新版本'), findsNothing);
  });

  testWidgets('hides the later action for a forced update', (tester) async {
    final service = _FakeUpdateService();
    addTearDown(service.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDefaultUpdateDialog(
              context,
              service: service,
              update: const AppUpdateInfo(
                versionName: '2.0.0',
                downloadUrl: 'https://example.com/app.apk',
                forceUpdate: true,
              ),
            ),
            child: const Text('show'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    expect(find.text('稍后再说'), findsNothing);
    expect(find.text('此版本需要更新后使用'), findsOneWidget);

    await tester.tap(find.text('后台下载'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsNothing);
    expect(service.downloadCalls, 1);
  });
  testWidgets('long release notes remain scrollable on a small screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _FakeUpdateService();
    addTearDown(service.close);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDefaultUpdateDialog(
              context,
              service: service,
              update: AppUpdateInfo(
                versionName: '2.0.0',
                downloadUrl: 'https://example.com/app.apk',
                forceUpdate: false,
                releaseNotes: List.filled(30, '一项很长的更新说明').join('\n'),
              ),
            ),
            child: const Text('show'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

class _FakeUpdateService extends AppUpdateService {
  _FakeUpdateService() : super(updateApiUrl: 'https://example.com/update');

  int downloadCalls = 0;

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
  }) async {
    downloadCalls++;
    onStarted?.call(42);
    return true;
  }
}
