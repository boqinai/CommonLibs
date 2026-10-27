import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_auth/fusion_auth.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    FusionAuth.onTokenUpdate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FusionAuth.channel, (call) async {
          calls.add(call);
          if (call.method == 'start') {
            final args = call.arguments as Map;
            return args['token'] == 'good'
                ? {'verifyToken': 'verify', 'code': '', 'message': ''}
                : {'code': '700000', 'message': 'cancelled'};
          }
          return null;
        });
  });

  test('channel name is generic', () {
    expect(FusionAuth.channel.name, 'boqinai/fusion_auth');
  });

  test('start returns the verify token', () async {
    final r = await FusionAuth.start(
      token: 'good',
      schemeCode: 'S',
      templateId: '100001',
    );
    expect(r.ok, isTrue);
    expect(r.verifyToken, 'verify');
    expect(calls.single.arguments, {
      'token': 'good',
      'schemeCode': 'S',
      'templateId': '100001',
    });
  });

  test('start without token is not ok; finish and cancel forward', () async {
    final r = await FusionAuth.start(
      token: 'bad',
      schemeCode: 'S',
      templateId: '100001',
    );
    expect(r.ok, isFalse);
    expect(r.code, '700000');
    await FusionAuth.finish(true);
    await FusionAuth.cancel();
    expect(calls.map((c) => c.method), ['start', 'finish', 'cancel']);
    expect(calls[1].arguments, {'success': true});
  });

  test('onTokenUpdate can be set by the host', () async {
    FusionAuth.onTokenUpdate = () async => 'refreshed';
    expect(await FusionAuth.onTokenUpdate!(), 'refreshed');
    // start binds the method-call handler for native → Dart token refresh.
    await FusionAuth.start(
      token: 'good',
      schemeCode: 'S',
      templateId: '100001',
    );
  });
}
