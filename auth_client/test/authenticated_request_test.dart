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
          return http.Response('{"token":"jwt"}', 200);
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
