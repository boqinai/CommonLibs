export 'update_check_schedule.dart';
export 'update_dialog.dart';
export 'update_download_controller.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

enum UpdateCheckStatus { updateAvailable, upToDate, failed, unsupported }

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.versionName,
    required this.downloadUrl,
    required this.forceUpdate,
    this.releaseNotes = '',
  });

  final String versionName;
  final String downloadUrl;
  final bool forceUpdate;
  final String releaseNotes;
}

class UpdateCheckResult {
  const UpdateCheckResult(this.status, {this.update});

  final UpdateCheckStatus status;
  final AppUpdateInfo? update;
}

class UpdateRequestContext {
  const UpdateRequestContext({
    required this.packageName,
    required this.versionCode,
    required this.deviceId,
  });

  final String packageName;
  final int versionCode;
  final String deviceId;
}

typedef UpdateRequestContextLoader = Future<UpdateRequestContext?> Function();

/// 更新中心客户端。检查协议和 Android 前台下载/安装逻辑均由此插件负责。
class AppUpdateService {
  AppUpdateService({
    required this.updateApiUrl,
    this.channel = 'stable',
    http.Client? client,
    UpdateRequestContextLoader? requestContextLoader,
  }) : _client = client ?? http.Client(),
       _requestContextLoader = requestContextLoader;

  static const _platform = MethodChannel('app_update');
  static const _events = EventChannel('app_update/events');

  final String updateApiUrl;
  final String channel;
  final http.Client _client;
  final UpdateRequestContextLoader? _requestContextLoader;

  static UpdateCheckResult parseResponse(Map<String, dynamic> data) {
    if (data['update_available'] != true) {
      return const UpdateCheckResult(UpdateCheckStatus.upToDate);
    }
    final versionName = data['version_name']?.toString() ?? '';
    final downloadUrl = data['download_url']?.toString() ?? '';
    if (versionName.isEmpty || !_isHttpUrl(downloadUrl)) {
      return const UpdateCheckResult(UpdateCheckStatus.failed);
    }
    return UpdateCheckResult(
      UpdateCheckStatus.updateAvailable,
      update: AppUpdateInfo(
        versionName: versionName,
        downloadUrl: downloadUrl,
        forceUpdate: data['force_update'] == true,
        releaseNotes: data['release_notes']?.toString() ?? '',
      ),
    );
  }

  Future<UpdateCheckResult> checkForUpdate() async {
    if (!_isHttpUrl(updateApiUrl)) {
      return const UpdateCheckResult(UpdateCheckStatus.failed);
    }
    try {
      final context = await (_requestContextLoader?.call() ?? _loadContext());
      if (context == null) {
        return const UpdateCheckResult(UpdateCheckStatus.unsupported);
      }
      final baseUri = Uri.parse(updateApiUrl);
      final response = await _client
          .get(
            baseUri.replace(
              queryParameters: {
                ...baseUri.queryParameters,
                'package_name': context.packageName,
                'channel': channel,
                'version_code': context.versionCode.toString(),
                'device_id': context.deviceId,
              },
            ),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        return const UpdateCheckResult(UpdateCheckStatus.failed);
      }
      final data = jsonDecode(response.body);
      return data is Map<String, dynamic>
          ? parseResponse(data)
          : const UpdateCheckResult(UpdateCheckStatus.failed);
    } catch (error) {
      debugPrint('检查更新失败: $error');
      return const UpdateCheckResult(UpdateCheckStatus.failed);
    }
  }

  /// 交给 Android 前台服务后台下载，完成后打开系统安装器。
  Future<bool> downloadAndInstall(
    String downloadUrl, {
    required String version,
    Duration downloadTimeout = const Duration(minutes: 30),
    bool wifiOnly = false,
    void Function(double progress)? onProgress,
    void Function(int downloadId)? onStarted,
    void Function(String filePath)? onDownloaded,
  }) async {
    if (!_supportsAndroid || !_isHttpUrl(downloadUrl) || version.isEmpty) {
      return false;
    }
    int? activeDownloadId;
    var completed = false;
    try {
      final source = Uri.parse(downloadUrl);
      final task = await _platform.invokeMapMethod<String, dynamic>(
        'startDownload',
        {
          'url': source
              .replace(
                queryParameters: {...source.queryParameters, 'v': version},
              )
              .toString(),
          'version': version,
          'wifiOnly': wifiOnly,
        },
      );
      activeDownloadId = task?['downloadId'] as int?;
      final filePath = task?['filePath'] as String?;
      if (activeDownloadId == null) return false;
      if (filePath == null) {
        await _cancelQuietly(activeDownloadId);
        return false;
      }
      onStarted?.call(activeDownloadId);

      Future<bool?> handleEvent(dynamic raw) async {
        if (raw is! Map || raw['downloadId'] != activeDownloadId) return null;
        final status = raw['status'] as int?;
        final downloaded = raw['bytesDownloaded'] as int? ?? 0;
        final total = raw['totalBytes'] as int? ?? 0;
        if (status == 8) {
          completed = true;
          onProgress?.call(1);
          onDownloaded?.call(filePath);
          return await openApk(filePath);
        }
        if (status == 16) return false;
        onProgress?.call(
          (total > 0 ? downloaded / total : 0.0).clamp(0.0, 1.0).toDouble(),
        );
        return null;
      }

      final probeTimeout = downloadTimeout < const Duration(seconds: 1)
          ? downloadTimeout
          : const Duration(seconds: 1);
      StreamIterator<dynamic>? events;
      var receivedFirstEvent = false;
      try {
        events = StreamIterator<dynamic>(_events.receiveBroadcastStream());
        final hasFirstEvent = await events.moveNext().timeout(probeTimeout);
        if (!hasFirstEvent) {
          await _cancelQuietly(activeDownloadId);
          return false;
        }
        receivedFirstEvent = true;
        final firstResult = await handleEvent(events.current);
        if (firstResult != null) return firstResult;
        while (await events.moveNext().timeout(downloadTimeout)) {
          final result = await handleEvent(events.current);
          if (result != null) return result;
        }
      } on MissingPluginException {
        return await _pollDownload(
          activeDownloadId,
          filePath,
          downloadTimeout,
          onProgress,
          onDownloaded,
        );
      } on TimeoutException {
        if (!receivedFirstEvent) {
          return await _pollDownload(
            activeDownloadId,
            filePath,
            downloadTimeout,
            onProgress,
            onDownloaded,
          );
        }
        await _cancelQuietly(activeDownloadId);
        return false;
      } finally {
        await events?.cancel();
      }
      await _cancelQuietly(activeDownloadId);
      return false;
    } catch (error) {
      if (activeDownloadId != null && !completed) {
        await _cancelQuietly(activeDownloadId);
      }
      debugPrint('下载或安装 APK 失败: $error');
      return false;
    }
  }

  Future<bool> _pollDownload(
    int downloadId,
    String filePath,
    Duration timeout,
    void Function(double progress)? onProgress,
    void Function(String filePath)? onDownloaded,
  ) async {
    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < timeout) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final progress = await _platform.invokeMapMethod<String, dynamic>(
        'getDownloadProgress',
        {'downloadId': downloadId},
      );
      if (progress == null) {
        await _cancelQuietly(downloadId);
        return false;
      }
      final status = progress['status'] as int?;
      final downloaded = progress['bytesDownloaded'] as int? ?? 0;
      final total = progress['totalBytes'] as int? ?? 0;
      if (status == 8) {
        onProgress?.call(1);
        onDownloaded?.call(filePath);
        return openApk(filePath);
      }
      if (status == 16) {
        await _cancelQuietly(downloadId);
        return false;
      }
      onProgress?.call(
        (total > 0 ? downloaded / total : 0.0).clamp(0.0, 1.0).toDouble(),
      );
    }
    await _cancelQuietly(downloadId);
    return false;
  }

  /// 打开已下载的 APK。可在用户授予“安装未知应用”权限后直接重试安装。
  Future<bool> openApk(String filePath) async {
    if (!_supportsAndroid || filePath.isEmpty) return false;
    try {
      return await _platform.invokeMethod<bool>('openApk', {
            'path': filePath,
          }) ??
          false;
    } catch (error) {
      debugPrint('打开 APK 失败: $error');
      return false;
    }
  }

  Future<bool> cancelDownload(int downloadId) async {
    if (!_supportsAndroid) return false;
    try {
      return await _platform.invokeMethod<bool>('cancelDownload', {
            'downloadId': downloadId,
          }) ??
          false;
    } catch (error) {
      debugPrint('取消 APK 下载失败: $error');
      return false;
    }
  }

  Future<void> _cancelQuietly(int downloadId) async {
    await cancelDownload(downloadId);
  }

  void close() => _client.close();

  Future<UpdateRequestContext?> _loadContext() async {
    if (!_supportsAndroid) return null;
    final data = await _platform.invokeMapMethod<String, dynamic>(
      'getUpdateContext',
    );
    final packageName = data?['packageName']?.toString() ?? '';
    final versionCode = data?['versionCode'];
    final deviceId = data?['deviceId']?.toString() ?? '';
    if (packageName.isEmpty || versionCode is! int || deviceId.isEmpty) {
      return null;
    }
    return UpdateRequestContext(
      packageName: packageName,
      versionCode: versionCode,
      deviceId: deviceId,
    );
  }

  static bool get _supportsAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool _isHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.host.isNotEmpty &&
        (uri.scheme == 'https' ||
            (uri.scheme == 'http' && _isLoopback(uri.host)));
  }

  static bool _isLoopback(String host) =>
      host == 'localhost' || host == '127.0.0.1' || host == '::1';
}
