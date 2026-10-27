import 'dart:async';
import 'dart:io';

import 'package:auth_client/auth_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory temp;
  late TokenStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('auth-request-');
    store = TokenStore(fileFactory: () async => File('${temp.path}/session'));
  });

  tearDown(() => temp.delete(recursive: true));

  test('sends authenticated JSON business requests', () async {
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) {
          return http.Response(
            '{"token":"jwt","refresh_token":"refresh",'
            '"user":{"id":1,"phone":"13800000000","nickname":"","avatar":"0"}}',
            200,
          );
        }
        expect(request.method, 'PUT');
        expect(request.headers['Authorization'], 'Bearer jwt');
        expect(request.body, '{"value":7}');
        return http.Response('{"ok":true}', 200);
      }),
    );
    addTearDown(client.close);
    await client.login('13800000000', '123456');

    final result = await client.authenticatedRequest(
      'put',
      '/api/document',
      body: {'value': 7},
    );

    expect(result, {'ok': true});
  });

  test('a 401 clears the rejected token', () async {
    await store.write('expired');
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient((_) async => http.Response('unauthorized', 401)),
    );
    addTearDown(client.close);
    await client.restore();

    await expectLater(
      client.authenticatedRequest('GET', '/api/private'),
      throwsA(
        isA<AuthException>().having(
          (error) => error.statusCode,
          'statusCode',
          401,
        ),
      ),
    );

    expect(client.isLoggedIn, isFalse);
    expect(await store.read(), isNull);
  });

  test('supports PATCH and normalizes a relative request path', () async {
    await store.write('jwt');
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient((request) async {
        expect(request.method, 'PATCH');
        expect(request.url.toString(), 'https://example.test/api/user');
        expect(request.body, isEmpty);
        return http.Response('{}', 200);
      }),
    );
    addTearDown(client.close);
    await client.restore();

    await client.authenticatedRequest('patch', 'api/user');
  });

  test(
    'classifies a successful non-JSON response as invalid response',
    () async {
      await store.write('jwt');
      final client = AuthClient(
        baseUrl: 'https://example.test',
        tokenStore: store,
        client: MockClient((_) async => http.Response('not-json', 200)),
      );
      addTearDown(client.close);
      await client.restore();

      await expectLater(
        client.authenticatedRequest('GET', '/api/user'),
        throwsA(
          isA<AuthException>()
              .having(
                (error) => error.code,
                'code',
                AuthErrorCode.invalidResponse,
              )
              .having(
                (error) => error.isNetworkFailure,
                'isNetworkFailure',
                isFalse,
              ),
        ),
      );
    },
  );

  test('classifies invalid UTF-8 as an invalid response', () async {
    await store.write('jwt');
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient((_) async => http.Response.bytes([0xff, 0xfe], 200)),
    );
    addTearDown(client.close);
    await client.restore();

    await expectLater(
      client.authenticatedRequest('GET', '/api/user'),
      throwsA(
        isA<AuthException>()
            .having(
              (error) => error.code,
              'code',
              AuthErrorCode.invalidResponse,
            )
            .having(
              (error) => error.isNetworkFailure,
              'isNetworkFailure',
              isFalse,
            ),
      ),
    );
  });

  test('concurrent 401 responses share one token refresh', () async {
    await store.write('expired');
    var refreshCalls = 0;
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      onRefreshToken: () async {
        refreshCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return 'fresh';
      },
      client: MockClient(
        (request) async => request.headers['Authorization'] == 'Bearer fresh'
            ? http.Response('{"ok":true}', 200)
            : http.Response('{}', 401),
      ),
    );
    addTearDown(client.close);
    await client.restore();

    final results = await Future.wait([
      client.authenticatedRequest('GET', '/api/one'),
      client.authenticatedRequest('GET', '/api/two'),
      client.authenticatedRequest('GET', '/api/three'),
    ]);

    expect(refreshCalls, 1);
    expect(results, everyElement({'ok': true}));
    expect(await store.read(), 'fresh');
  });

  test('logout wins over an in-flight token refresh', () async {
    await store.write('expired');
    final refreshStarted = Completer<void>();
    final refreshResult = Completer<String?>();
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      onRefreshToken: () {
        refreshStarted.complete();
        return refreshResult.future;
      },
      client: MockClient((_) async => http.Response('{}', 401)),
    );
    addTearDown(client.close);
    await client.restore();

    final request = client.authenticatedRequest('GET', '/api/private');
    await refreshStarted.future;
    await client.logout();
    refreshResult.complete('stale-token');

    await expectLater(request, throwsA(isA<AuthException>()));
    expect(client.isLoggedIn, isFalse);
    expect(await store.read(), isNull);
  });

  test('unsupported methods remain argument errors', () async {
    await store.write('jwt');
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    addTearDown(client.close);
    await client.restore();

    await expectLater(
      client.authenticatedRequest('TRACE', '/api/private'),
      throwsArgumentError,
    );
  });

  test('close releases the HTTP client', () {
    final transport = _TrackingClient();
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: transport,
    );

    client.close();

    expect(transport.closed, isTrue);
  });
}

class _TrackingClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(const Stream<List<int>>.empty(), 200);

  @override
  void close() => closed = true;
}
