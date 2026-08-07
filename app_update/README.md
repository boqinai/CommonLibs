# app_update

Boqinai Flutter 应用共用的 Android 应用内更新插件。它统一负责：

- 调用更新中心并解析 `update_available`、`version_name`、`download_url`、`force_update`
- 自动读取应用包名、`versionCode` 和 Android ID
- 使用 Android `DownloadManager` 后台下载、通知栏展示和进度查询
- 取消下载，并通过内置 `FileProvider` 打开系统 APK 安装器

弹窗、文案、强制升级交互和自动检查频率由各 App 保留，因为这些是产品策略而不是更新协议。

## 引用

```yaml
dependencies:
  app_update:
    path: ../CommonLibs/app_update
```

业务项目无需再修改 `MainActivity`、声明安装权限或配置 `FileProvider`。

## 使用

```dart
final updater = AppUpdateService(
  updateApiUrl: 'https://api.boqinai.com/updatecenter/api/v1/update',
);

final result = await updater.checkForUpdate();
if (result.status == UpdateCheckStatus.updateAvailable) {
  final update = result.update!;
  int? downloadId;
  final installed = await updater.downloadAndInstall(
    update.downloadUrl,
    version: update.versionName,
    onStarted: (id) => downloadId = id,
    onProgress: (progress) => print('${(progress * 100).round()}%'),
  );

  // 用户取消时：await updater.cancelDownload(downloadId!);
}
```

接入现有项目时，删除原有 `app_update_service.dart` 及 `MainActivity` 中对应的更新 MethodChannel；各项目原有弹窗只需改为导入 `package:app_update/app_update.dart`。

## 生命周期与安装权限

`AppUpdateService` 持有 HTTP Client；不再使用时必须调用 `close()`（在 `StatefulWidget` 中放到 `dispose()`）。`downloadAndInstall` 默认最多等待 30 分钟，超时会取消 DownloadManager 任务，可通过 `downloadTimeout` 调整。Android 8.0+ 未授权安装未知应用时，插件会打开当前应用对应的系统设置页，用户授权后重试安装。

## 自动检查与下载控制器

```dart
final schedule = UpdateCheckSchedule();
if (await schedule.isDue(frequency: UpdateCheckFrequency.daily)) {
  final result = await updater.checkForUpdate();
  await schedule.markChecked();
}

final controller = UpdateDownloadController(
  service: updater,
  update: result.update!,
  wifiOnly: true,
);
controller.addListener(() {
  print('${controller.state}: ${controller.progress}');
});
await controller.start(); // retry() / cancel()
```

调度模块只持久化最后检查时间；是否启用、频率选择和界面文案仍由 App 决定。`wifiOnly: true` 会直接使用 DownloadManager 的 Wi-Fi 网络约束。

远程更新接口和 APK 地址必须使用 HTTPS；仅 `localhost`、`127.0.0.1` 和 `::1` 可使用 HTTP。界面销毁时调用 `controller.dispose()`，控制器会取消仍在运行的下载。
