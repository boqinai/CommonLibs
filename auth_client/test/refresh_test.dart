import 'dart:convert';
import 'dart:io';

import 'package:auth_client/auth_client.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory temp;
  late TokenStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('auth-refresh-');
    store = TokenStore(fileFactory: () async => File('${temp.path}/session'));
  });

  tearDown(() => temp.delete(recursive: true));

  test('error codes match the auth_server strings', () {
    expect(AuthErrorCode.invalidRequest, 'invalid_request');
    expect(
      AuthErrorCode.invalidCredentialsFormat,
      'invalid_credentials_format',
    );
    expect(AuthErrorCode.phoneAlreadyRegistered, 'phone_already_registered');
    expect(AuthErrorCode.invalidCredentials, 'invalid_credentials');
    expect(AuthErrorCode.unauthorized, 'unauthorized');
    expect(AuthErrorCode.userNotFound, 'user_not_found');
    expect(AuthErrorCode.methodNotAllowed, 'method_not_allowed');
    expect(AuthErrorCode.internalError, 'internal_error');
    expect(AuthErrorCode.profileNotSupported, 'profile_not_supported');
    expect(AuthErrorCode.invalidResponse, 'invalid_response');
    expect(AuthErrorCode.networkFailure, 'network_failure');
    expect(AuthErrorCode.invalidPhone, 'invalid_phone');
    expect(AuthErrorCode.verificationFailed, 'verification_failed');
    expect(AuthErrorCode.smsTooFrequent, 'sms_too_frequent');
    expect(AuthErrorCode.smsDailyLimit, 'sms_daily_limit');
    expect(AuthErrorCode.tooManyRequests, 'too_many_requests');
    expect(AuthErrorCode.smsUnavailable, 'sms_unavailable');
    expect(AuthErrorCode.verificationUnavailable, 'verification_unavailable');
    expect(AuthErrorCode.unsupportedPlatform, 'unsupported_platform');
    expect(AuthErrorCode.invalidRefreshToken, 'invalid_refresh_token');
  });

  test('login stores the refresh token and restores it', () async {
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient((request) async {
        expect(request.url.path, '/api/auth/login');
        return http.Response(
          '{"token":"access","refresh_token":"refresh","expires_in":7200,'
          '"user":{"id":1,"phone":"13800000000"}}',
          200,
        );
      }),
    );
    addTearDown(client.close);

    expect(await client.login('13800000000', '12345678'), 'access');
    expect(client.refreshToken, 'refresh');
    expect(await store.readRefresh(), 'refresh');

    final restored = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient((_) async => http.Response('{}', 500)),
    );
    addTearDown(restored.close);
    expect(await restored.restore(), 'access');
    expect(restored.refreshToken, 'refresh');
  });

  test('a 401 refreshes once and retries with the new access token', () async {
    await store.write('expired');
    await store.writeRefresh('refresh-1');
    var refreshes = 0;
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient((request) async {
        if (request.url.path == '/api/auth/refresh') {
          refreshes++;
          expect(jsonDecode(request.body), {'refresh_token': 'refresh-1'});
          return http.Response(
            '{"token":"access-2","refresh_token":"refresh-2","expires_in":7200}',
            200,
          );
        }
        if (request.headers['Authorization'] == 'Bearer access-2') {
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('{}', 401);
      }),
    );
    addTearDown(client.close);
    await client.restore();

    final results = await Future.wait([
      client.authenticatedRequest('GET', '/api/one'),
      client.authenticatedRequest('GET', '/api/two'),
    ]);

    expect(refreshes, 1);
    expect(results, everyElement({'ok': true}));
    expect(client.token, 'access-2');
    expect(client.refreshToken, 'refresh-2');
    expect(await store.read(), 'access-2');
    expect(await store.readRefresh(), 'refresh-2');
  });

  test('refresh rejection clears the session', () async {
    await store.write('expired');
    await store.writeRefresh('refresh-1');
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient((request) async {
        if (request.url.path == '/api/auth/refresh') {
          return http.Response(
            '{"code":"invalid_refresh_token","message":"invalid refresh token"}',
            401,
          );
        }
        if (request.url.path == '/api/auth/logout') {
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('{}', 401);
      }),
    );
    addTearDown(client.close);
    await client.restore();

    await expectLater(
      client.authenticatedRequest('GET', '/api/private'),
      throwsA(
        isA<AuthException>().having((error) => error.statusCode, 'status', 401),
      ),
    );
    expect(client.isLoggedIn, isFalse);
    expect(await store.read(), isNull);
    expect(await store.readRefresh(), isNull);
  });

  test('a refresh transport failure keeps the session', () async {
    await store.write('expired');
    await store.writeRefresh('refresh-1');
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient((request) async {
        if (request.url.path == '/api/auth/refresh') {
          throw const SocketException('offline');
        }
        return http.Response('{}', 401);
      }),
    );
    addTearDown(client.close);
    await client.restore();

    await expectLater(
      client.authenticatedRequest('GET', '/api/private'),
      throwsA(
        isA<AuthException>().having(
          (error) => error.isNetworkFailure,
          'network',
          isTrue,
        ),
      ),
    );
    expect(client.isLoggedIn, isTrue);
    expect(await store.read(), 'expired');
    expect(await store.readRefresh(), 'refresh-1');
  });

  test('onRefreshToken still wins over the stored refresh token', () async {
    await store.write('expired');
    await store.writeRefresh('refresh-1');
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      onRefreshToken: () async => 'hooked',
      client: MockClient((request) async {
        expect(request.url.path, isNot('/api/auth/refresh'));
        if (request.headers['Authorization'] == 'Bearer hooked') {
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('{}', 401);
      }),
    );
    addTearDown(client.close);
    await client.restore();

    expect(await client.authenticatedRequest('GET', '/api/private'), {
      'ok': true,
    });
    expect(client.refreshToken, 'refresh-1');
  });

  test('logout revokes on the server and clears both tokens', () async {
    final seen = <String>[];
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient((request) async {
        seen.add(request.url.path);
        if (request.url.path.endsWith('/login')) {
          return http.Response(
            '{"token":"access","refresh_token":"refresh"}',
            200,
          );
        }
        expect(request.url.path, '/api/auth/logout');
        expect(request.headers['Authorization'], 'Bearer access');
        expect(jsonDecode(request.body), {'refresh_token': 'refresh'});
        return http.Response('{"ok":true}', 200);
      }),
    );
    addTearDown(client.close);
    await client.login('13800000000', '12345678');

    await client.logout();

    expect(seen, ['/api/auth/login', '/api/auth/logout']);
    expect(client.isLoggedIn, isFalse);
    expect(client.refreshToken, isNull);
    expect(await store.read(), isNull);
    expect(await store.readRefresh(), isNull);
  });

  test('logout still clears locally when revoke fails', () async {
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) {
          return http.Response('{"token":"access"}', 200);
        }
        throw const SocketException('offline');
      }),
    );
    addTearDown(client.close);
    await client.login('13800000000', '12345678');

    await client.logout();

    expect(client.isLoggedIn, isFalse);
    expect(await store.read(), isNull);
  });

  test('revokeOnLogout false does not call the server', () async {
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      revokeOnLogout: false,
      client: MockClient((request) async {
        expect(request.url.path, '/api/auth/login');
        return http.Response(
          '{"token":"access","refresh_token":"refresh"}',
          200,
        );
      }),
    );
    addTearDown(client.close);
    await client.login('13800000000', '12345678');

    await client.logout();

    expect(await store.read(), isNull);
    expect(await store.readRefresh(), isNull);
  });

  test(
    'secure storage keeps the refresh token beside the access token',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final secure = SecureTokenStore(name: 'test_session');
      await secure.write('access');
      await secure.writeRefresh('refresh');
      expect(await secure.read(), 'access');
      expect(await secure.readRefresh(), 'refresh');
      await secure.clear();
      expect(await secure.read(), isNull);
      expect(await secure.readRefresh(), 'refresh');
      await secure.clearRefresh();
      expect(await secure.readRefresh(), isNull);
    },
  );
}
