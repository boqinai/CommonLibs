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
  });

  final String versionName;
  final String downloadUrl;
  final bool forceUpdate;
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

/// 更新中心客户端。检查协议和 Android DownloadManager/安装逻辑均由此插件负责。
class AppUpdateService {
  AppUpdateService({
    required this.updateApiUrl,
    this.channel = 'stable',
    http.Client? client,
    UpdateRequestContextLoader? requestContextLoader,
  }) : _client = client ?? http.Client(),
       _requestContextLoader = requestContextLoader;

  static const _platform = MethodChannel('app_update');

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

  /// 交给 Android DownloadManager 后台下载，完成后打开系统安装器。
  Future<bool> downloadAndInstall(
    String downloadUrl, {
    required String version,
    void Function(double progress)? onProgress,
    void Function(int downloadId)? onStarted,
  }) async {
    if (!_supportsAndroid || !_isHttpUrl(downloadUrl) || version.isEmpty) {
      return false;
    }
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
        },
      );
      final downloadId = task?['downloadId'] as int?;
      final filePath = task?['filePath'] as String?;
      if (downloadId == null || filePath == null) return false;
      onStarted?.call(downloadId);

      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final progress = await _platform.invokeMapMethod<String, dynamic>(
          'getDownloadProgress',
          {'downloadId': downloadId},
        );
        if (progress == null) return false;
        final status = progress['status'] as int?;
        final downloaded = progress['bytesDownloaded'] as int? ?? 0;
        final total = progress['totalBytes'] as int? ?? 0;
        if (status == 8) {
          onProgress?.call(1);
          return await _platform.invokeMethod<bool>('openApk', {
                'path': filePath,
              }) ??
              false;
        }
        if (status == 16) return false;
        onProgress?.call(total > 0 ? downloaded / total : 0);
      }
    } catch (error) {
      debugPrint('下载或安装 APK 失败: $error');
      return false;
    }
  }

  Future<bool> cancelDownload(int downloadId) async {
    if (!_supportsAndroid) return false;
    return await _platform.invokeMethod<bool>('cancelDownload', {
          'downloadId': downloadId,
        }) ??
        false;
  }

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
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty;
  }
}
