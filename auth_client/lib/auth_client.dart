import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class AuthException implements Exception {
  const AuthException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class TokenStore {
  TokenStore({this.name = 'auth_session', Future<File> Function()? fileFactory})
    : _fileFactory = fileFactory;

  final String name;
  final Future<File> Function()? _fileFactory;

  Future<String?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    final token = (await file.readAsString()).trim();
    return token.isEmpty ? null : token;
  }

  Future<void> write(String token) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(token, flush: true);
  }

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
    TokenStore? tokenStore,
  }) : baseUrl = _normalizeBaseUrl(baseUrl),
       _client = client ?? http.Client(),
       _tokenStore = tokenStore ?? TokenStore();

  final String baseUrl;
  final http.Client _client;
  final TokenStore _tokenStore;
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
      throw const AuthException('登录响应缺少 token');
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
      if (error.statusCode != 401) rethrow;
      await logout();
      return null;
    }
  }

  Future<Map<String, dynamic>> currentUser() async {
    final data = await _request('GET', '/api/auth/me', authenticated: true);
    if (data is! Map<String, dynamic>) {
      throw const AuthException('用户信息响应格式错误');
    }
    return data;
  }

  Future<void> logout() async {
    _token = null;
    await _tokenStore.clear();
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool authenticated = false,
  }) async {
    if (authenticated && !isLoggedIn) {
      throw const AuthException('未登录', statusCode: 401);
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
        _ => throw ArgumentError.value(method, 'method'),
      };
      final response = await request.timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AuthException(
          response.body.trim().isEmpty ? '认证请求失败' : response.body.trim(),
          statusCode: response.statusCode,
        );
      }
      return response.body.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body);
    } on AuthException {
      rethrow;
    } catch (error) {
      throw AuthException('认证请求失败: $error');
    }
  }

  static String _normalizeBaseUrl(String value) {
    final trimmed = value.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw ArgumentError.value(value, 'baseUrl', '必须是 HTTP(S) URL');
    }
    return trimmed;
  }
}
