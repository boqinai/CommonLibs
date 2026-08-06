import 'dart:io';

import 'package:auth_client/auth_client.dart';
import 'package:flutter_test/flutter_test.dart';
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

  test('registration exposes server status and message', () async {
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient(
        (_) async => http.Response('phone already registered', 409),
      ),
    );

    expect(
      () => client.register('13800000000', '123456'),
      throwsA(
        isA<AuthException>()
            .having((error) => error.statusCode, 'statusCode', 409)
            .having(
              (error) => error.message,
              'message',
              'phone already registered',
            ),
      ),
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
}
