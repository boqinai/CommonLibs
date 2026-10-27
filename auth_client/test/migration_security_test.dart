import 'package:auth_client/auth_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rejects insecure remote authentication URLs', () {
    expect(
      () => AuthClient(baseUrl: 'http://example.com'),
      throwsArgumentError,
    );
    expect(() => AuthClient(baseUrl: 'http://localhost:8080'), returnsNormally);
  });
}
