import 'dart:convert';
import 'dart:io';

import 'package:auth_client/auth_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory temp;
  late TokenStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('auth-phone-');
    store = TokenStore(fileFactory: () async => File('${temp.path}/session'));
  });

  tearDown(() => temp.delete(recursive: true));

  test('sms code and fusion token login', () async {
    final paths = <String>[];
    final client = AuthClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      client: MockClient((request) async {
        paths.add(request.url.path);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        switch (request.url.path) {
          case '/api/auth/sms/send':
            expect(body, {'phone': '13800138000'});
            return http.Response('{"ok":true,"cooldown":45}', 200);
          case '/api/auth/sms/login':
            if (body['code'] != '123456') {
              return http.Response(
                '{"code":"verification_failed","message":"x"}',
                401,
              );
            }
            return http.Response(
              '{"token":"sms-jwt","user":{"id":1,"phone":"13800138000"},'
              '"created":true}',
              200,
            );
          case '/api/auth/fusion/token':
            expect(body, {'platform': 'android'});
            return http.Response('{"token":"init","schemeCode":"S"}', 200);
          case '/api/auth/fusion/login':
            expect(body, {'token': 'verify'});
            return http.Response(
              '{"token":"fusion-jwt","user":{"id":2,"phone":"13900139000"},"created":false}',
              200,
            );
        }
        return http.Response('', 404);
      }),
    );

    expect(await client.sendSmsCode(' 13800138000 '), 45);
    await expectLater(
      client.loginWithSmsCode('13800138000', '000000'),
      throwsA(
        isA<AuthException>().having(
          (e) => e.code,
          'code',
          AuthErrorCode.verificationFailed,
        ),
      ),
    );
    expect(client.isLoggedIn, isFalse);
    expect(await client.loginWithSmsCode('13800138000', '123456'), 'sms-jwt');
    expect(client.lastLoginCreated, isTrue);
    expect(client.profile?.phone, '13800138000');
    expect((await client.fusionAuthToken('android'))['schemeCode'], 'S');
    expect(await client.loginWithFusionToken('verify'), 'fusion-jwt');
    expect(client.lastLoginCreated, isFalse);
    expect(await store.read(), 'fusion-jwt');
    expect(paths, hasLength(5));
  });
}
