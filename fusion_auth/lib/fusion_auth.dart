/// Dart side of the Aliyun 融合认证 (fusion auth / 本机号码一键登录) bridge
/// for Android and iOS. Other platforms have no implementation: callers must
/// check the platform first and fall back to SMS-code login.
library;

import 'package:flutter/services.dart';

/// Outcome of one fusion scene.
class FusionVerifyResult {
  const FusionVerifyResult({
    this.verifyToken,
    this.code = '',
    this.message = '',
  });

  /// 统一认证Token for the server (VerifyWithFusionAuthToken); null when the
  /// user cancelled or the SDK failed.
  final String? verifyToken;
  final String code;
  final String message;
  bool get ok => verifyToken != null && verifyToken!.isNotEmpty;
}

class FusionAuth {
  FusionAuth._();
  static const channel = MethodChannel('boqinai/fusion_auth');

  /// Starts [templateId] with the server-issued SDK [token]. Resolves when
  /// the SDK yields a verify token, or the scene ends without one.
  static Future<FusionVerifyResult> start({
    required String token,
    required String schemeCode,
    required String templateId,
  }) async {
    final raw = await channel.invokeMapMethod<String, Object?>('start', {
      'token': token,
      'schemeCode': schemeCode,
      'templateId': templateId,
    });
    return FusionVerifyResult(
      verifyToken: raw?['verifyToken'] as String?,
      code: raw?['code'] as String? ?? '',
      message: raw?['message'] as String? ?? '',
    );
  }

  /// Reports the server verdict for the last verify token; the SDK closes
  /// its pages on success and may fall back (e.g. to SMS) on failure.
  static Future<void> finish(bool success) =>
      channel.invokeMethod<void>('finish', {'success': success});

  /// Closes any open fusion page and releases the SDK.
  static Future<void> cancel() => channel.invokeMethod<void>('cancel');
}
