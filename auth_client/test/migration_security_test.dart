import 'dart:io';

import 'package:auth_client/auth_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('migrates a legacy token once', () async {
    final temp = await Directory.systemTemp.createTemp('auth-migration-');
    addTearDown(() => temp.delete(recursive: true));
    final legacy = TokenStore(
      fileFactory: () async => File('${temp.path}/legacy'),
    );
    final primary = TokenStore(
      fileFactory: () async => File('${temp.path}/primary'),
    );
    await legacy.write('old-jwt');
    final migrating = MigratingTokenStorage(primary: primary, legacy: legacy);

    expect(await migrating.read(), 'old-jwt');
    expect(await primary.read(), 'old-jwt');
    expect(await legacy.read(), isNull);
  });

  test('rejects insecure remote authentication URLs', () {
    expect(
      () => AuthClient(baseUrl: 'http://example.com'),
      throwsArgumentError,
    );
    expect(() => AuthClient(baseUrl: 'http://localhost:8080'), returnsNormally);
  });
}
