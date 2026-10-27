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

/// Machine-readable error codes. Values shared with auth_server `codes.go`
/// must stay byte-for-byte identical. [invalidResponse] and [networkFailure]
/// are produced only by this client.
abstract final class AuthErrorCode {
  static const invalidRequest = 'invalid_request';
  static const invalidCredentialsFormat = 'invalid_credentials_format';
  static const phoneAlreadyRegistered = 'phone_already_registered';
  static const invalidCredentials = 'invalid_credentials';
  static const unauthorized = 'unauthorized';
  static const userNotFound = 'user_not_found';
  static const methodNotAllowed = 'method_not_allowed';
  static const internalError = 'internal_error';
  static const profileNotSupported = 'profile_not_supported';
  static const invalidResponse = 'invalid_response';
  static const networkFailure = 'network_failure';
  static const invalidPhone = 'invalid_phone';
  static const verificationFailed = 'verification_failed';
  static const smsTooFrequent = 'sms_too_frequent';
  static const smsDailyLimit = 'sms_daily_limit';
  static const tooManyRequests = 'too_many_requests';
  static const smsUnavailable = 'sms_unavailable';
  static const verificationUnavailable = 'verification_unavailable';
  static const unsupportedPlatform = 'unsupported_platform';
  static const invalidRefreshToken = 'invalid_refresh_token';
}

abstract interface class TokenStorage {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> clear();
}

/// Optional persistence for the refresh token. Built-in stores implement it.
/// A custom [TokenStorage] that does not will keep the refresh token in
/// memory for the life of [AuthClient] only.
abstract interface class RefreshTokenStorage {
  Future<String?> readRefresh();
  Future<void> writeRefresh(String token);
  Future<void> clearRefresh();
}

class SecureTokenStore implements TokenStorage, RefreshTokenStorage {
  SecureTokenStore({this.name = 'auth_session', FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final String name;
  final FlutterSecureStorage _storage;

  String get _refreshKey => '$name.refresh';

  @override
  Future<String?> read() => _storage.read(key: name);

  @override
  Future<void> write(String token) => _storage.write(key: name, value: token);

  @override
  Future<void> clear() => _storage.delete(key: name);

  @override
  Future<String?> readRefresh() => _storage.read(key: _refreshKey);

  @override
  Future<void> writeRefresh(String token) =>
      _storage.write(key: _refreshKey, value: token);

  @override
  Future<void> clearRefresh() => _storage.delete(key: _refreshKey);
}

class MigratingTokenStorage implements TokenStorage, RefreshTokenStorage {
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

  @override
  Future<String?> readRefresh() async {
    final currentStore = _refreshStore(primary);
    if (currentStore == null) return null;
    final current = await currentStore.readRefresh();
    if (current != null && current.isNotEmpty) return current;
    final oldStore = _refreshStore(legacy);
    if (oldStore == null) return null;
    final token = await oldStore.readRefresh();
    if (token == null || token.isEmpty) return null;
    await currentStore.writeRefresh(token);
    await oldStore.clearRefresh();
    return token;
  }

  @override
  Future<void> writeRefresh(String token) async {
    final currentStore = _refreshStore(primary);
    if (currentStore != null) await currentStore.writeRefresh(token);
    final oldStore = _refreshStore(legacy);
    if (oldStore != null) await oldStore.clearRefresh();
  }

  @override
  Future<void> clearRefresh() async {
    final currentStore = _refreshStore(primary);
    final oldStore = _refreshStore(legacy);
    if (currentStore != null) await currentStore.clearRefresh();
    if (oldStore != null) await oldStore.clearRefresh();
  }
}

RefreshTokenStorage? _refreshStore(TokenStorage storage) =>
    storage is RefreshTokenStorage ? storage as RefreshTokenStorage : null;

/// Plaintext file token store. Prefer [SecureTokenStore] in production; keep
/// this for tests or one-shot migration via [MigratingTokenStorage].
class TokenStore implements TokenStorage, RefreshTokenStorage {
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

  @override
  Future<String?> readRefresh() async {
    final file = await _refreshFile();
    if (!await file.exists()) return null;
    final token = (await file.readAsString()).trim();
    return token.isEmpty ? null : token;
  }

  @override
  Future<void> writeRefresh(String token) async {
    final file = await _refreshFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(token, flush: true);
  }

  @override
  Future<void> clearRefresh() async {
    final file = await _refreshFile();
    if (await file.exists()) await file.delete();
  }

  Future<File> _refreshFile() async {
    final file = await _file();
    return File('${file.path}.refresh');
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
    this.revokeOnLogout = true,
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

  /// When true (the default), [logout] POSTs `/logout` so the server can
  /// revoke the access token and refresh token. Failures are ignored and
  /// the local session is still cleared. Set false for a client-only logout
  /// (auth_server older than 0.11.0, or tests).
  final bool revokeOnLogout;
  final StreamController<bool> _authStateController =
      StreamController<bool>.broadcast();
  Future<_Refreshed?>? _activeRefresh;
  int _authGeneration = 0;
  String? _token;
  String? _refreshToken;
  UserProfile? _profile;
  bool? _lastLoginCreated;

  String? get token => _token;

  /// Refresh token from the latest login or refresh, when the server sent one.
  String? get refreshToken => _refreshToken;
  UserProfile? get profile => _profile;

  /// Whether the last verified-phone login created a new user.
  /// Null after password login / restore / logout.
  bool? get lastLoginCreated => _lastLoginCreated;
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
    return _acceptLogin(data);
  }

  /// Requests an SMS code (auth_server >= 0.9.0); returns the resend
  /// cooldown in seconds.
  Future<int> sendSmsCode(String phone) async {
    final data = await _request(
      'POST',
      '$authPath/sms/send',
      body: {'phone': phone.trim()},
    );
    final cooldown = data is Map<String, dynamic> ? data['cooldown'] : null;
    return cooldown is int && cooldown > 0 ? cooldown : 60;
  }

  /// Logs in (registering if needed) with an SMS code.
  Future<String> loginWithSmsCode(String phone, String code) async {
    final data = await _request(
      'POST',
      '$authPath/sms/login',
      body: {'phone': phone.trim(), 'code': code.trim()},
    );
    return _acceptLogin(data);
  }

  /// Fetches the fusion-auth SDK init payload for `android` or `ios`.
  Future<Map<String, dynamic>> fusionAuthToken(String platform) async {
    final data = await _request(
      'POST',
      '$authPath/fusion/token',
      body: {'platform': platform},
    );
    if (data is! Map<String, dynamic>) {
      throw const AuthException(
        '一键登录配置格式错误',
        code: AuthErrorCode.invalidResponse,
      );
    }
    return data;
  }

  /// Logs in (registering if needed) with the fusion SDK's verify token.
  Future<String> loginWithFusionToken(String verifyToken) async {
    final data = await _request(
      'POST',
      '$authPath/fusion/login',
      body: {'token': verifyToken},
    );
    return _acceptLogin(data);
  }

  Future<String> _acceptLogin(dynamic data) async {
    final token = data is Map<String, dynamic> ? data['token'] : null;
    if (token is! String || token.isEmpty) {
      throw const AuthException(
        '登录响应缺少 token',
        code: AuthErrorCode.invalidResponse,
      );
    }
    UserProfile? profile;
    final rawUser = data['user'];
    if (rawUser != null) {
      if (rawUser is! Map<String, dynamic>) {
        throw const AuthException(
          '登录响应中的用户资料格式错误',
          code: AuthErrorCode.invalidResponse,
        );
      }
      profile = UserProfile.fromJson(rawUser);
    }
    bool? created;
    if (data is Map<String, dynamic> && data.containsKey('created')) {
      final raw = data['created'];
      if (raw is! bool) {
        throw const AuthException(
          '登录响应中的 created 字段格式错误',
          code: AuthErrorCode.invalidResponse,
        );
      }
      created = raw;
    }
    String? refresh;
    if (data is Map<String, dynamic> && data.containsKey('refresh_token')) {
      final rawRefresh = data['refresh_token'];
      if (rawRefresh is! String || rawRefresh.isEmpty) {
        throw const AuthException(
          '登录响应中的 refresh_token 格式错误',
          code: AuthErrorCode.invalidResponse,
        );
      }
      refresh = rawRefresh;
    }
    final storage = _tokenStore;
    await storage.write(token);
    final refreshStore = _refreshStore(storage);
    if (refreshStore != null) {
      if (refresh != null) {
        await refreshStore.writeRefresh(refresh);
      } else {
        await refreshStore.clearRefresh();
      }
    }
    _authGeneration++;
    _token = token;
    _refreshToken = refresh;
    _profile = profile;
    _lastLoginCreated = created;
    _authStateController.add(true);
    return token;
  }

  Future<String?> restore({bool validate = false}) async {
    _authGeneration++;
    final storage = _tokenStore;
    _token = await storage.read();
    _refreshToken = null;
    final refreshStore = _refreshStore(storage);
    if (_token != null && refreshStore != null) {
      final refresh = await refreshStore.readRefresh();
      _refreshToken = (refresh != null && refresh.isNotEmpty) ? refresh : null;
    }
    _profile = null;
    _lastLoginCreated = null;
    _authStateController.add(isLoggedIn);
    if (!isLoggedIn || !validate) return _token;
    try {
      await currentUserProfile(forceRefresh: true);
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

  Future<UserProfile> currentUserProfile({bool forceRefresh = false}) async {
    if (!forceRefresh && _profile != null) return _profile!;
    final data = await currentUser();
    final profile = UserProfile.fromJson(data);
    _profile = profile;
    return profile;
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
      final profile = UserProfile.fromJson(
        data['profile'] as Map<String, dynamic>,
      );
      _profile = profile;
      return profile;
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
    final access = _token;
    final refresh = _refreshToken;
    _authGeneration++;
    _token = null;
    _refreshToken = null;
    _profile = null;
    _lastLoginCreated = null;
    final storage = _tokenStore;
    await storage.clear();
    await _refreshStore(storage)?.clearRefresh();
    _authStateController.add(false);
    final hasToken =
        (access != null && access.isNotEmpty) ||
        (refresh != null && refresh.isNotEmpty);
    if (revokeOnLogout && hasToken) {
      await _revokeRemote(access, refresh);
    }
  }

  bool get _canRefresh =>
      onRefreshToken != null || (_refreshToken?.isNotEmpty ?? false);

  Future<_Refreshed?> _performRefresh() async {
    if (onRefreshToken != null) {
      final access = await onRefreshToken!();
      if (access == null || access.isEmpty) return null;
      return _Refreshed(access, _refreshToken);
    }
    final refreshToken = _refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) return null;
    final dynamic data;
    try {
      data = await _request(
        'POST',
        '$authPath/refresh',
        body: {'refresh_token': refreshToken},
        allowRefresh: false,
      );
    } on AuthException catch (error) {
      if (error.statusCode == 401 ||
          error.code == AuthErrorCode.invalidRefreshToken) {
        return null;
      }
      rethrow;
    }
    if (data is! Map<String, dynamic>) {
      throw const AuthException(
        '刷新响应格式错误',
        code: AuthErrorCode.invalidResponse,
      );
    }
    final access = data['token'];
    if (access is! String || access.isEmpty) {
      throw const AuthException(
        '刷新响应缺少 token',
        code: AuthErrorCode.invalidResponse,
      );
    }
    final rawNext = data['refresh_token'];
    if (rawNext == null) return _Refreshed(access, refreshToken);
    if (rawNext is! String || rawNext.isEmpty) {
      throw const AuthException(
        '刷新响应中的 refresh_token 格式错误',
        code: AuthErrorCode.invalidResponse,
      );
    }
    return _Refreshed(access, rawNext);
  }

  Future<void> _persistRefreshed(_Refreshed refreshed) async {
    final storage = _tokenStore;
    await storage.write(refreshed.access);
    final next = refreshed.refresh;
    final refreshStore = _refreshStore(storage);
    if (next != null && next.isNotEmpty && refreshStore != null) {
      await refreshStore.writeRefresh(next);
      _refreshToken = next;
    }
    _token = refreshed.access;
  }

  Future<void> _revokeRemote(String? access, String? refresh) async {
    try {
      final headers = <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
        if (headerProvider != null) ...await headerProvider!(),
        if (access != null && access.isNotEmpty)
          'Authorization': 'Bearer $access',
      };
      await _client
          .post(
            Uri.parse('$baseUrl$authPath/logout'),
            headers: headers,
            body: jsonEncode({
              if (refresh != null && refresh.isNotEmpty)
                'refresh_token': refresh,
            }),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      // Local session is already cleared. Revocation is best-effort.
    }
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
            _canRefresh) {
          final generation = _authGeneration;
          final refresh = _activeRefresh ??= _performRefresh();
          _Refreshed? refreshed;
          try {
            refreshed = await refresh;
          } on AuthException {
            if (generation != _authGeneration) {
              throw const AuthException(
                '认证状态已发生变化',
                code: AuthErrorCode.unauthorized,
                statusCode: 401,
              );
            }
            rethrow;
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
          if (refreshed != null && refreshed.access.isNotEmpty) {
            await _persistRefreshed(refreshed);
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

class _Refreshed {
  const _Refreshed(this.access, this.refresh);

  final String access;
  final String? refresh;
}
