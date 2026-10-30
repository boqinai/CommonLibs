import 'dart:async';
import 'package:carrier_auth/carrier_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

CarrierOptions options({Duration timeout = const Duration(minutes: 3)}) =>
    CarrierOptions(
      sdkKey: 'synthetic-app-key',
      authorizationTimeout: timeout,
      agreements: const [
        CarrierAgreement(title: 'Terms', url: 'https://example.test/terms'),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const client = CarrierAuthClient();
  tearDown(
    () => messenger.setMockMethodCallHandler(CarrierAuthClient.channel, null),
  );

  test(
    'passes host configuration without backend or app identifiers',
    () async {
      messenger.setMockMethodCallHandler(CarrierAuthClient.channel, (
        call,
      ) async {
        expect(call.method, 'start');
        expect(call.arguments['sdkKey'], 'synthetic-app-key');
        expect(call.arguments['agreements'], [
          {'title': 'Terms', 'url': 'https://example.test/terms'},
        ]);
        expect(call.arguments['appearance']['primaryColor'], 0xFF2563EB);
        expect(call.arguments['sdkTimeoutMs'], 10000);
        return {'code': '600000', 'token': 'consented-token'};
      });
      final result = await client.authorize(options());
      expect(result.accepted, true);
      expect(result.token, 'consented-token');
    },
  );

  for (final code in ['cancelled', 'switch_sms', 'busy', '600012', '600001']) {
    test('$code cannot carry an accepted token', () async {
      messenger.setMockMethodCallHandler(
        CarrierAuthClient.channel,
        (_) async => {'code': code, 'token': 'must-not-leak'},
      );
      final result = await client.authorize(options());
      expect(result.accepted, false);
      expect(result.token, null);
      expect(result.code, code);
    });
  }
  test('empty and malformed success responses fail closed', () {
    for (final value in [
      null,
      <String, Object?>{},
      {'code': '600000'},
      {'code': '600000', 'token': 42},
    ]) {
      expect(CarrierResult.fromMap(value).accepted, false);
    }
  });
  test(
    'concurrent callers share the global native owner without cancelling it',
    () async {
      final reply = Completer<Map<String, Object?>>();
      final methods = <String>[];
      messenger.setMockMethodCallHandler(CarrierAuthClient.channel, (
        call,
      ) async {
        methods.add(call.method);
        return reply.future;
      });
      final first = client.authorize(options());
      expect((await const CarrierAuthClient().authorize(options())).busy, true);
      expect(methods, ['start']);
      reply.complete({'code': '600000', 'token': 'authorized'});
      expect((await first).accepted, true);
    },
  );
  test('timeout releases native UI and allows a subsequent request', () async {
    final reply = Completer<Map<String, Object?>>();
    final methods = <String>[];
    messenger.setMockMethodCallHandler(CarrierAuthClient.channel, (call) async {
      methods.add(call.method);
      if (call.method == 'start') return reply.future;
      reply.complete({'code': 'cancelled'});
      return null;
    });
    expect(
      (await client.authorize(
        options(timeout: const Duration(milliseconds: 5)),
      )).code,
      '600015',
    );
    expect(methods, ['start', 'cancel']);
    messenger.setMockMethodCallHandler(
      CarrierAuthClient.channel,
      (_) async => {'code': 'cancelled'},
    );
    expect((await client.authorize(options())).cancelled, true);
  });
  test('manual cancellation resolves the owning request', () async {
    final reply = Completer<Map<String, Object?>>();
    messenger.setMockMethodCallHandler(CarrierAuthClient.channel, (call) async {
      if (call.method == 'start') return reply.future;
      reply.complete({'code': 'cancelled'});
      return null;
    });
    final request = client.authorize(options());
    await client.cancel();
    expect((await request).cancelled, true);
  });
  test('platform failures do not reveal provider messages', () async {
    messenger.setMockMethodCallHandler(
      CarrierAuthClient.channel,
      (_) async => throw PlatformException(
        code: 'bad_vendor_payload',
        message: 'sensitive-provider-value',
      ),
    );
    final result = await client.authorize(options());
    expect(result.code, 'start_failed');
    expect(result.token, null);
  });
  test('platform busy preserves the existing session', () async {
    messenger.setMockMethodCallHandler(
      CarrierAuthClient.channel,
      (_) async => throw PlatformException(code: 'busy'),
    );
    expect((await client.authorize(options())).busy, true);
  });
  test('unsupported platforms return unavailable', () async {
    messenger.setMockMethodCallHandler(
      CarrierAuthClient.channel,
      (_) async => throw MissingPluginException(),
    );
    expect((await client.authorize(options())).code, 'unavailable');
  });
  test('validates configuration before invoking native SDK', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(CarrierAuthClient.channel, (_) async {
      calls++;
      return null;
    });
    for (final invalid in [
      const CarrierOptions(sdkKey: '', agreements: []),
      const CarrierOptions(sdkKey: 'key', agreements: []),
      const CarrierOptions(
        sdkKey: 'key',
        agreements: [CarrierAgreement(title: 'x', url: 'http://example.test')],
      ),
      const CarrierOptions(
        sdkKey: 'key',
        agreements: [
          CarrierAgreement(title: 'x', url: 'https://user:pass@example.test'),
        ],
      ),
    ]) {
      await expectLater(client.authorize(invalid), throwsArgumentError);
    }
    expect(calls, 0);
  });
  test(
    'honors host labels and theme instead of embedding product styling',
    () async {
      messenger.setMockMethodCallHandler(CarrierAuthClient.channel, (
        call,
      ) async {
        expect(call.arguments['title'], 'Host title');
        expect(call.arguments['loginButtonText'], 'Continue');
        expect(call.arguments['smsButtonText'], 'Use SMS');
        expect(call.arguments['appearance']['primaryColor'], 0xFF101010);
        return {'code': 'cancelled'};
      });
      await client.authorize(
        CarrierOptions(
          sdkKey: 'key',
          agreements: options().agreements,
          title: 'Host title',
          loginButtonText: 'Continue',
          smsButtonText: 'Use SMS',
          appearance: const CarrierAppearance(primaryColor: 0xFF101010),
        ),
      );
    },
  );
}
