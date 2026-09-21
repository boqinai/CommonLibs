import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

final _unsafeFileNameCharacters = RegExp(r'[^A-Za-z0-9._-]');
final _trailingSlashes = RegExp(r'/+$');

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
  String toString() =>
      'AuthException(code: $code, statusCode: $statusCode, message: $message)';
}

class UserProfile {
  const UserProfile({
    required this.id,
    required this.phone,
    this.nickname = '',
    this.avatar = '0',
  });

  final int id;
  final String phone;
  final String nickname;
  final String avatar;

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'];
    final id = rawId is int
        ? rawId
        : rawId is num && rawId.isFinite && rawId == rawId.toInt()
        ? rawId.toInt()
        : null;
    final phone = json['phone'];
    final nickname = json['nickname'];
    final avatar = json['avatar'];
    if (id == null ||
        id <= 0 ||
        phone is! String ||
        phone.isEmpty ||
        (nickname != null && nickname is! String) ||
        (avatar != null && avatar is! String)) {
      throw const AuthException(
        '用户资料响应格式错误',
        code: AuthErrorCode.invalidResponse,
      );
    }
    return UserProfile(
      id: id,
      phone: phone,
      nickname: nickname as String? ?? '',
      avatar: avatar as String? ?? '0',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'phone': phone,
    'nickname': nickname,
    'avatar': avatar,
  };

  UserProfile copyWith({
    int? id,
    String? phone,
    String? nickname,
    String? avatar,
  }) {
    return UserProfile(
      id: id ?? this.id,
      phone: phone ?? this.phone,
      nickname: nickname ?? this.nickname,
      avatar: avatar ?? this.avatar,
    );
  }

  @override
  String toString() =>
      'UserProfile(id: $id, phone: $phone, nickname: $nickname, avatar: $avatar)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserProfile &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          phone == other.phone &&
          nickname == other.nickname &&
          avatar == other.avatar;

  @override
  int get hashCode => Object.hash(id, phone, nickname, avatar);
}

typedef AuthHeaderProvider = FutureOr<Map<String, String>> Function();
typedef AuthTokenRefresher = Future<String?> Function();

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
    final safeName = name.replaceAll(_unsafeFileNameCharacters, '_');
    return File('${(await getApplicationSupportDirectory()).path}/$safeName');
  }
}

class AuthClient {
  AuthClient({
    required String baseUrl,
    String authPath = '/api/auth',
    http.Client? client,
    TokenStorage? tokenStore,
    this.headerProvider,
    this.onRefreshToken,
  }) : baseUrl = _normalizeBaseUrl(baseUrl),
       authPath = _normalizeAuthPath(authPath),
       _client = client ?? http.Client(),
       _tokenStore = tokenStore ?? SecureTokenStore();

  final String baseUrl;
  final String authPath;
  final http.Client _client;
  final TokenStorage _tokenStore;
  final AuthHeaderProvider? headerProvider;
  final AuthTokenRefresher? onRefreshToken;
  final StreamController<bool> _authStateController =
      StreamController<bool>.broadcast();
  Future<String?>? _activeRefresh;
  int _authGeneration = 0;
  String? _token;

  String? get token => _token;
  bool get isLoggedIn => _token?.isNotEmpty == true;
  Stream<bool> get onAuthStateChanged => _authStateController.stream;
  Map<String, String> get authorizationHeaders => isLoggedIn
      ? {'Authorization': 'Bearer $_token'}
      : const <String, String>{};

  Future<void> register(String phone, String password) async {
    await _request(
      'POST',
      '$authPath/register',
      body: {'phone': phone.trim(), 'password': password},
    );
  }

  Future<String> login(String phone, String password) async {
    final data = await _request(
      'POST',
      '$authPath/login',
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
    _authGeneration++;
    _token = token;
    _authStateController.add(true);
    return token;
  }

  Future<String?> restore({bool validate = false}) async {
    _authGeneration++;
    _token = await _tokenStore.read();
    _authStateController.add(isLoggedIn);
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
    final data = await _request('GET', '$authPath/me', authenticated: true);
    if (data is! Map<String, dynamic>) {
      throw const AuthException(
        '用户信息响应格式错误',
        code: AuthErrorCode.invalidResponse,
      );
    }
    return data;
  }

  Future<UserProfile> currentUserProfile() async {
    final data = await currentUser();
    return UserProfile.fromJson(data);
  }

  Future<UserProfile> updateProfile({String? nickname, String? avatar}) async {
    final body = <String, dynamic>{'nickname': ?nickname, 'avatar': ?avatar};
    final data = await _request(
      'PUT',
      '$authPath/profile',
      body: body,
      authenticated: true,
    );
    if (data is Map<String, dynamic> &&
        data['profile'] is Map<String, dynamic>) {
      return UserProfile.fromJson(data['profile'] as Map<String, dynamic>);
    }
    throw const AuthException(
      '更新用户资料响应格式错误',
      code: AuthErrorCode.invalidResponse,
    );
  }

  Future<dynamic> authenticatedRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) => authenticatedRequestAs<dynamic>(method, path, body: body);

  Future<T> authenticatedRequestAs<T>(
    String method,
    String path, {
    Map<String, dynamic>? body,
    T Function(dynamic data)? decoder,
  }) async {
    final data = await _request(
      method.toUpperCase(),
      path,
      body: body,
      authenticated: true,
    );
    return decoder == null ? data as T : decoder(data);
  }

  Future<void> logout() async {
    _authGeneration++;
    _token = null;
    await _tokenStore.clear();
    _authStateController.add(false);
  }

  void close() {
    _client.close();
    unawaited(_authStateController.close());
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool authenticated = false,
    bool allowRefresh = true,
  }) async {
    const supportedMethods = {'GET', 'POST', 'PUT', 'PATCH', 'DELETE'};
    if (!supportedMethods.contains(method)) {
      throw ArgumentError.value(method, 'method', 'unsupported HTTP method');
    }
    if (authenticated && !isLoggedIn) {
      throw const AuthException(
        '未登录',
        code: AuthErrorCode.unauthorized,
        statusCode: 401,
      );
    }
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      if (headerProvider != null) ...await headerProvider!(),
      if (authenticated) ...authorizationHeaders,
    };
    try {
      final normalizedPath = path.startsWith('/') ? path : '/$path';
      final uri = Uri.parse('$baseUrl$normalizedPath');
      final request = switch (method) {
        'GET' => _client.get(uri, headers: headers),
        'POST' => _client.post(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        ),
        'PUT' => _client.put(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        ),
        'PATCH' => _client.patch(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        ),
        'DELETE' => _client.delete(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        ),
        _ => throw ArgumentError.value(method, 'method'),
      };
      final response = await request.timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (authenticated &&
            response.statusCode == 401 &&
            allowRefresh &&
            onRefreshToken != null) {
          final generation = _authGeneration;
          final refresh = _activeRefresh ??= Future<String?>.sync(
            onRefreshToken!,
          );
          String? refreshed;
          try {
            refreshed = await refresh;
          } finally {
            if (identical(_activeRefresh, refresh)) _activeRefresh = null;
          }
          if (generation != _authGeneration) {
            throw const AuthException(
              '认证状态已发生变化',
              code: AuthErrorCode.unauthorized,
              statusCode: 401,
            );
          }
          if (refreshed != null && refreshed.isNotEmpty) {
            _token = refreshed;
            await _tokenStore.write(refreshed);
            _authStateController.add(true);
            return await _request(
              method,
              path,
              body: body,
              authenticated: true,
              allowRefresh: false,
            );
          }
        }
        if (authenticated && response.statusCode == 401) await logout();
        final responseBody = _decodeResponseBody(response);
        final error = _decodeError(responseBody);
        throw AuthException(
          error.message,
          code: error.code,
          statusCode: response.statusCode,
        );
      }
      final responseBody = _decodeResponseBody(response);
      if (responseBody.trim().isEmpty) return <String, dynamic>{};
      try {
        return jsonDecode(responseBody);
      } on FormatException catch (error) {
        throw AuthException(
          '认证响应格式错误: $error',
          code: AuthErrorCode.invalidResponse,
          statusCode: response.statusCode,
        );
      }
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
    final trimmed = value.trim().replaceFirst(_trailingSlashes, '');
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' && _isLoopback(uri.host)))) {
      throw ArgumentError.value(value, 'baseUrl', '必须是 HTTP(S) URL');
    }
    return trimmed;
  }

  static String _normalizeAuthPath(String value) {
    final path = value.trim().replaceFirst(_trailingSlashes, '');
    if (!path.startsWith('/') || path.contains('?') || path.contains('#')) {
      throw ArgumentError.value(value, 'authPath', '必须是绝对 URL 路径');
    }
    return path;
  }

  static bool _isLoopback(String host) =>
      host == 'localhost' || host == '127.0.0.1' || host == '::1';

  static String _decodeResponseBody(http.Response response) {
    try {
      return utf8.decode(response.bodyBytes);
    } on FormatException catch (error) {
      throw AuthException(
        '认证响应不是有效的 UTF-8: $error',
        code: AuthErrorCode.invalidResponse,
        statusCode: response.statusCode,
      );
    }
  }

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
