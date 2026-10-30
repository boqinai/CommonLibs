library;

import 'dart:async';
import 'package:flutter/services.dart';

/// A carrier login token is usable only after explicit SDK-page authorization.
class CarrierResult {
  const CarrierResult({this.token, this.code = ''});
  final String? token;
  final String code;
  bool get accepted => code == '600000' && token?.isNotEmpty == true;
  bool get cancelled => code == 'cancelled';
  bool get requestsSms => code == 'switch_sms';
  bool get busy => code == 'busy';

  factory CarrierResult.fromMap(Map<String, Object?>? raw) {
    final code = raw?['code'] is String
        ? raw!['code'] as String
        : 'invalid_result';
    final value = raw?['token'];
    final token = code == '600000' && value is String && value.isNotEmpty
        ? value
        : null;
    return CarrierResult(
      token: token,
      code: code == '600000' && token == null ? 'invalid_result' : code,
    );
  }
}

class CarrierAgreement {
  const CarrierAgreement({required this.title, required this.url});
  final String title;
  final String url;
  Map<String, Object?> toMap() => {'title': title, 'url': url};
}

/// ARGB colors and shared typography, supplied by the host design system.
class CarrierAppearance {
  const CarrierAppearance({
    this.surfaceColor = 0xFFFFFFFF,
    this.textColor = 0xFF202020,
    this.secondaryTextColor = 0xFF666666,
    this.primaryColor = 0xFF2563EB,
    this.pressedColor = 0xFF1D4ED8,
    this.onPrimaryColor = 0xFFFFFFFF,
    this.linkColor = 0xFF1D4ED8,
    this.numberTextSize = 28,
    this.buttonTextSize = 16,
    this.cornerRadius = 12,
  });
  final int surfaceColor, textColor, secondaryTextColor, primaryColor;
  final int pressedColor, onPrimaryColor, linkColor;
  final int numberTextSize, buttonTextSize;
  final double cornerRadius;
  Map<String, Object?> toMap() => {
    'surfaceColor': surfaceColor,
    'textColor': textColor,
    'secondaryTextColor': secondaryTextColor,
    'primaryColor': primaryColor,
    'pressedColor': pressedColor,
    'onPrimaryColor': onPrimaryColor,
    'linkColor': linkColor,
    'numberTextSize': numberTextSize,
    'buttonTextSize': buttonTextSize,
    'cornerRadius': cornerRadius,
  };
}

class CarrierOptions {
  const CarrierOptions({
    required this.sdkKey,
    required this.agreements,
    this.appearance = const CarrierAppearance(),
    this.title = '本机号码登录',
    this.loginButtonText = '本机号码一键登录',
    this.smsButtonText = '使用短信验证码登录',
    this.sdkTimeout = const Duration(seconds: 10),
    this.authorizationTimeout = const Duration(minutes: 3),
  });
  final String sdkKey;
  final List<CarrierAgreement> agreements;
  final CarrierAppearance appearance;
  final String title, loginButtonText, smsButtonText;
  final Duration sdkTimeout, authorizationTimeout;

  void validate() {
    if (sdkKey.trim().isEmpty) {
      throw ArgumentError('An app-bound SDK key is required');
    }
    if (agreements.isEmpty || agreements.length > 3) {
      throw ArgumentError('Provide one to three host agreements');
    }
    for (final agreement in agreements) {
      final uri = Uri.tryParse(agreement.url);
      if (agreement.title.trim().isEmpty ||
          uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw ArgumentError('Agreements require a title and an HTTPS URL');
      }
    }
    if (sdkTimeout.inMilliseconds <= 0 ||
        sdkTimeout > const Duration(minutes: 1) ||
        authorizationTimeout.inMilliseconds <= 0 ||
        authorizationTimeout > const Duration(minutes: 30)) {
      throw ArgumentError('Invalid authentication timeout');
    }
    if (appearance.numberTextSize < 16 ||
        appearance.buttonTextSize < 12 ||
        !appearance.cornerRadius.isFinite ||
        appearance.cornerRadius < 0) {
      throw ArgumentError('Invalid authentication appearance');
    }
  }

  Map<String, Object?> toMap() => {
    'sdkKey': sdkKey,
    'agreements': agreements.map((a) => a.toMap()).toList(),
    'appearance': appearance.toMap(),
    'title': title,
    'loginButtonText': loginButtonText,
    'smsButtonText': smsButtonText,
    'sdkTimeoutMs': sdkTimeout.inMilliseconds,
    'authorizationTimeoutMs': authorizationTimeout.inMilliseconds,
  };
}

/// No backend, SMS sender, routing, state manager or app-specific UI dependency.
/// Apps exchange accepted tokens through their own server's GetMobile endpoint.
class CarrierAuthClient {
  const CarrierAuthClient();
  static const channel = MethodChannel('boqinai/carrier_auth');
  static Object? _owner;

  Future<CarrierResult> authorize(CarrierOptions options) async {
    options.validate();
    if (_owner != null) return const CarrierResult(code: 'busy');
    final owner = Object();
    _owner = owner;
    try {
      final raw = await channel
          .invokeMapMethod<String, Object?>('start', options.toMap())
          .timeout(options.authorizationTimeout);
      return CarrierResult.fromMap(raw);
    } on TimeoutException {
      await cancel();
      return const CarrierResult(code: '600015');
    } on MissingPluginException {
      return const CarrierResult(code: 'unavailable');
    } on PlatformException catch (error) {
      return CarrierResult(
        code: error.code == 'busy' ? 'busy' : 'start_failed',
      );
    } finally {
      if (identical(_owner, owner)) _owner = null;
    }
  }

  Future<void> cancel() async {
    try {
      await channel
          .invokeMethod<void>('cancel')
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      /* Cleanup cannot obscure the original authorization outcome. */
    }
  }
}
