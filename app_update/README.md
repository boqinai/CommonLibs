# app_update

Boqinai Flutter 应用共用的 Android 应用内更新插件。它统一负责：

- 调用更新中心并解析 `update_available`、`version_name`、`download_url`、`force_update`
- 自动读取应用包名、`versionCode` 和 Android ID
- 使用 Android 前台服务后台下载，在单条通知中展示进度条和数字百分比
- 取消下载，并通过内置 `FileProvider` 打开系统 APK 安装器
- 安装前统一校验 APK 包名和签名证书链，覆盖应用内与通知栏两条安装入口

插件提供可直接使用的 Material 默认更新弹窗；各 App 仍可自定义文案、交互和自动检查频率。

## 引用

```yaml
dependencies:
  app_update:
    git:
      url: https://github.com/boqinai/CommonLibs.git
      ref: app_update-v0.10.1
      path: app_update
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
  await showDefaultUpdateDialog(
    context,
    service: updater,
    update: update,
    onDownloadStarted: (id) => print('download: $id'),
  );
}
```

默认弹窗展示版本号和 `release_notes`。普通更新包含“稍后再说”与“后台下载”；强制更新会隐藏稍后按钮并禁止点击遮罩或返回键关闭。开始后弹窗立即关闭，下载由 Android 前台服务继续，通知栏展示百分比。

接入现有项目时，删除原有 `app_update_service.dart` 及 `MainActivity` 中对应的更新 MethodChannel；各项目原有弹窗只需改为导入 `package:app_update/app_update.dart`。

## 生命周期与安装权限

`AppUpdateService` 持有 HTTP Client；不再使用时必须调用 `close()`（在 `StatefulWidget` 中放到 `dispose()`）。`downloadAndInstall` 默认最多等待 30 分钟，超时会取消前台下载任务，可通过 `downloadTimeout` 调整。Android 8.0+ 未授权安装未知应用时，插件会打开当前应用对应的系统设置页，用户授权后重试安装。

下载完成后可通过 `onDownloaded` 保存 APK 路径，授权返回后调用 `openApk(path)` 直接重试安装。`UpdateDownloadController` 会自动保存 `downloadedFilePath`，其 `retry()` 会优先重新打开已下载文件，不会重复下载。

更新协议可选返回 `sha256`（64 位十六进制）和 `file_size`（字节数）。响应里的 `md5` 会被忽略。缓存命中路径也会再跑一遍包名与签名校验。提供哈希或大小后，原生下载服务会校验 APK 完整性；无论是否提供完整性元数据，原生层都会在下载落盘以及打开安装器前核对 APK 包名与当前应用一致，并核对签名证书或合法的证书轮换链。插件同一时间只允许一个下载任务；重复启动会返回 `download_in_progress`。`downloadTimeout` 限制总下载时长，`inactivityTimeout` 限制两次进度事件之间允许的最长静默时间。事件流中断或迟迟没有事件时，会改用 `getDownloadProgress` 轮询。

下载失败时可通过 `onFailure` 获取结构化的 `UpdateFailure`；使用 `UpdateDownloadController` 时，可读取其 `failure` 字段展示具体错误原因。Android 15 对 `dataSync` 前台服务触发系统时限时，插件会持久化 `data_sync_timeout` 失败状态、停止服务并保留失败通知，Dart 侧映射为 `UpdateFailureCode.timedOut`。超时和下载线程用同一次 compare-and-set 抢终态，后到的一方不能再把结果写成成功，也不能移动 APK 或改通知。

发布前仍应在目标 ROM 真机验证未知来源授权返回、下载中进程重建，以及长时间弱网下载。普通 Dart 超时或失败提示不等同于 Android 15 系统前台服务超时处理。

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

调度模块只持久化最后检查时间；是否启用、频率选择和界面文案仍由 App 决定。`wifiOnly: true` 会在非 Wi-Fi 网络下保持等待，恢复 Wi-Fi 后自动开始下载。Android 13+ 首次下载时插件会请求通知权限。

远程更新接口和 APK 地址必须使用 HTTPS；仅 `localhost`、`127.0.0.1` 和 `::1` 可使用 HTTP。界面销毁时调用 `controller.dispose()`，控制器会取消仍在运行的下载。

如需自定义通知小图标，在 App 的 `<application>` 中配置单色 drawable：

```xml
<meta-data
    android:name="com.boqinai.app_update.notification_icon"
    android:resource="@drawable/ic_stat_update" />
```
