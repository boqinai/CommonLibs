import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class AuthException implements Exception {
  const AuthException(
    this.message, {
    this.code,
    this.statusCode,
    this.isNetworkFailure = false,
  });

  final String message;
  final String? code;
  final int? statusCode;
  final bool isNetworkFailure;

  @override
  String toString() => message;
}

abstract final class AuthErrorCode {
  static const invalidRequest = 'invalid_request';
  static const invalidCredentialsFormat = 'invalid_credentials_format';
  static const phoneAlreadyRegistered = 'phone_already_registered';
  static const invalidCredentials = 'invalid_credentials';
  static const unauthorized = 'unauthorized';
  static const userNotFound = 'user_not_found';
  static const methodNotAllowed = 'method_not_allowed';
  static const internalError = 'internal_error';
  static const invalidResponse = 'invalid_response';
  static const networkFailure = 'network_failure';
}

abstract interface class TokenStorage {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> clear();
}

class SecureTokenStore implements TokenStorage {
  SecureTokenStore({this.name = 'auth_session', FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final String name;
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: name);

  @override
  Future<void> write(String token) => _storage.write(key: name, value: token);

  @override
  Future<void> clear() => _storage.delete(key: name);
}

class MigratingTokenStorage implements TokenStorage {
  MigratingTokenStorage({required this.primary, required this.legacy});

  final TokenStorage primary;
  final TokenStorage legacy;

  @override
  Future<String?> read() async {
    final current = await primary.read();
    if (current != null) return current;
    final token = await legacy.read();
    if (token == null) return null;
    await primary.write(token);
    await legacy.clear();
    return token;
  }

  @override
  Future<void> write(String token) async {
    await primary.write(token);
    await legacy.clear();
  }

  @override
  Future<void> clear() async {
    await primary.clear();
    await legacy.clear();
  }
}

class TokenStore implements TokenStorage {
  TokenStore({this.name = 'auth_session', Future<File> Function()? fileFactory})
    : _fileFactory = fileFactory;

  final String name;
  final Future<File> Function()? _fileFactory;

  @override
  Future<String?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    final token = (await file.readAsString()).trim();
    return token.isEmpty ? null : token;
  }

  @override
  Future<void> write(String token) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(token, flush: true);
  }

  @override
  Future<void> clear() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }

  Future<File> _file() async {
    if (_fileFactory != null) return _fileFactory();
    final safeName = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return File('${(await getApplicationSupportDirectory()).path}/$safeName');
  }
}

class AuthClient {
  AuthClient({
    required String baseUrl,
    http.Client? client,
    TokenStorage? tokenStore,
  }) : baseUrl = _normalizeBaseUrl(baseUrl),
       _client = client ?? http.Client(),
       _tokenStore = tokenStore ?? SecureTokenStore();

  final String baseUrl;
  final http.Client _client;
  final TokenStorage _tokenStore;
  String? _token;

  String? get token => _token;
  bool get isLoggedIn => _token?.isNotEmpty == true;
  Map<String, String> get authorizationHeaders => isLoggedIn
      ? {'Authorization': 'Bearer $_token'}
      : const <String, String>{};

  Future<void> register(String phone, String password) async {
    await _request(
      'POST',
      '/api/auth/register',
      body: {'phone': phone.trim(), 'password': password},
    );
  }

  Future<String> login(String phone, String password) async {
    final data = await _request(
      'POST',
      '/api/auth/login',
      body: {'phone': phone.trim(), 'password': password},
    );
    final token = data is Map<String, dynamic> ? data['token'] : null;
    if (token is! String || token.isEmpty) {
      throw const AuthException(
        '登录响应缺少 token',
        code: AuthErrorCode.invalidResponse,
      );
    }
    await _tokenStore.write(token);
    _token = token;
    return token;
  }

  Future<String?> restore({bool validate = false}) async {
    _token = await _tokenStore.read();
    if (!isLoggedIn || !validate) return _token;
    try {
      await currentUser();
      return _token;
    } on AuthException catch (error) {
      if (error.isNetworkFailure) return _token;
      if (error.statusCode != 401) rethrow;
      await logout();
      return null;
    }
  }

  Future<Map<String, dynamic>> currentUser() async {
    final data = await _request('GET', '/api/auth/me', authenticated: true);
    if (data is! Map<String, dynamic>) {
      throw const AuthException(
        '用户信息响应格式错误',
        code: AuthErrorCode.invalidResponse,
      );
    }
    return data;
  }

  Future<dynamic> authenticatedRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) => _request(method.toUpperCase(), path, body: body, authenticated: true);
  Future<void> logout() async {
    _token = null;
    await _tokenStore.clear();
  }

  void close() => _client.close();

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool authenticated = false,
  }) async {
    if (authenticated && !isLoggedIn) {
      throw const AuthException(
        '未登录',
        code: AuthErrorCode.unauthorized,
        statusCode: 401,
      );
    }
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      if (authenticated) ...authorizationHeaders,
    };
    try {
      final uri = Uri.parse('$baseUrl$path');
      final request = switch (method) {
        'GET' => _client.get(uri, headers: headers),
        'POST' => _client.post(uri, headers: headers, body: jsonEncode(body)),
        'PUT' => _client.put(uri, headers: headers, body: jsonEncode(body)),
        'DELETE' => _client.delete(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        ),
        _ => throw ArgumentError.value(method, 'method'),
      };
      final response = await request.timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (authenticated && response.statusCode == 401) await logout();
        final error = _decodeError(response.body);
        throw AuthException(
          error.message,
          code: error.code,
          statusCode: response.statusCode,
        );
      }
      return response.body.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body);
    } on AuthException {
      rethrow;
    } catch (error) {
      throw AuthException(
        '认证请求失败: $error',
        code: AuthErrorCode.networkFailure,
        isNetworkFailure:
            error is TimeoutException ||
            error is SocketException ||
            error is http.ClientException,
      );
    }
  }

  static String _normalizeBaseUrl(String value) {
    final trimmed = value.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' && _isLoopback(uri.host)))) {
      throw ArgumentError.value(value, 'baseUrl', '必须是 HTTP(S) URL');
    }
    return trimmed;
  }

  static bool _isLoopback(String host) =>
      host == 'localhost' || host == '127.0.0.1' || host == '::1';

  static ({String message, String? code}) _decodeError(String body) {
    final text = body.trim();
    if (text.isEmpty) return (message: '认证请求失败', code: null);
    try {
      final data = jsonDecode(text);
      if (data is Map<String, dynamic>) {
        final message = data['message'];
        final code = data['code'];
        if (message is String && message.isNotEmpty) {
          return (message: message, code: code is String ? code : null);
        }
      }
    } catch (_) {
      // 兼容旧服务端的纯文本错误响应。
    }
    return (message: text, code: null);
  }
}
