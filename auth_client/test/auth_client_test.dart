import 'dart:io';

import 'package:auth_client/auth_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory temp;
  late TokenStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('auth-client-');
    store = TokenStore(fileFactory: () async => File('${temp.path}/session'));
  });

  tearDown(() => temp.delete(recursive: true));

  test('login persists token and authenticated requests use it', () async {
    final client = AuthClient(
      baseUrl: 'https://example.test/product/',
      tokenStore: store,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) {
          expect(request.url.path, '/product/api/auth/login');
          expect(request.body, contains('13800000000'));
          return http.Response('{"token":"jwt"}', 200);
        }
        expect(request.headers['Authorization'], 'Bearer jwt');
        return http.Response('{"id":7,"phone":"13800000000"}', 200);
      }),
    );

    expect(await client.login(' 13800000000 ', '123456'), 'jwt');
    expect((await client.currentUser())['id'], 7);
    expect(await store.read(), 'jwt');
  });

  test('restore validates and clears a rejected session', () async {
    await store.write('expired');
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient((_) async => http.Response('unauthorized', 401)),
    );

    expect(await client.restore(validate: true), isNull);
    expect(await store.read(), isNull);
  });

  test('restore keeps a cached session while offline', () async {
    await store.write('cached');
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient((_) => throw const SocketException('offline')),
    );

    expect(await client.restore(validate: true), 'cached');
    expect(await store.read(), 'cached');
  });

  test('secure token store reads, writes, and clears tokens', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final secureStore = SecureTokenStore(name: 'test_session');

    await secureStore.write('jwt');
    expect(await secureStore.read(), 'jwt');
    await secureStore.clear();
    expect(await secureStore.read(), isNull);
  });

  test('registration exposes server status, code, and message', () async {
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient(
        (_) async => http.Response(
          '{"code":"phone_already_registered",'
          '"message":"phone already registered"}',
          409,
        ),
      ),
    );

    expect(
      () => client.register('13800000000', '123456'),
      throwsA(
        isA<AuthException>()
            .having((error) => error.statusCode, 'statusCode', 409)
            .having(
              (error) => error.code,
              'code',
              AuthErrorCode.phoneAlreadyRegistered,
            )
            .having(
              (error) => error.message,
              'message',
              'phone already registered',
            ),
      ),
    );
  });

  test('plain text errors from older servers remain supported', () async {
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient(
        (_) async => http.Response('invalid phone or password', 401),
      ),
    );

    expect(
      () => client.login('13800000000', 'bad-password'),
      throwsA(
        isA<AuthException>()
            .having((error) => error.code, 'code', isNull)
            .having(
              (error) => error.message,
              'message',
              'invalid phone or password',
            ),
      ),
    );
  });

  test('supports a service-specific authentication path', () async {
    final client = AuthClient(
      baseUrl: 'https://example.test/penny',
      authPath: '/auth',
      tokenStore: store,
      client: MockClient((request) async {
        expect(request.url.path, '/penny/auth/login');
        return http.Response('{"token":"jwt"}', 200);
      }),
    );

    expect(await client.login('13800000000', '123456'), 'jwt');
  });

  test('rejects an invalid authentication path', () {
    expect(
      () => AuthClient(baseUrl: 'https://example.test', authPath: 'auth'),
      throwsArgumentError,
    );
  });

  test('logout clears memory and disk', () async {
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient((_) async => http.Response('{"token":"jwt"}', 200)),
    );
    await client.login('13800000000', '123456');

    await client.logout();

    expect(client.isLoggedIn, isFalse);
    expect(await store.read(), isNull);
  });

  test('currentUserProfile and updateProfile manage user profile', () async {
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient((request) async {
        if (request.url.path == '/api/auth/me') {
          return http.Response(
            '{"id":8,"phone":"13811112222","nickname":"旧昵称","avatar":"1"}',
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.path == '/api/auth/profile' && request.method == 'PUT') {
          expect(request.body, contains('新昵称'));
          expect(request.body, contains('5'));
          return http.Response(
            '{"ok":true,"profile":{"id":8,"phone":"13811112222","nickname":"新昵称","avatar":"5"}}',
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{"token":"jwt"}', 200);
      }),
    );
    await client.login('13811112222', '123456');

    final profile = await client.currentUserProfile();
    expect(profile.id, 8);
    expect(profile.nickname, '旧昵称');
    expect(profile.avatar, '1');

    final updated = await client.updateProfile(nickname: '新昵称', avatar: '5');
    expect(updated.nickname, '新昵称');
    expect(updated.avatar, '5');
  });
}
