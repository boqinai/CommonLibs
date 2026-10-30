import 'dart:async';
import 'package:carrier_auth/carrier_auth.dart';
import 'package:flutter/material.dart';

void main() => runApp(const CarrierExampleApp());

class CarrierExampleApp extends StatelessWidget {
  const CarrierExampleApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Carrier authorization example',
    theme: ThemeData(useMaterial3: true),
    home: const _AuthorizationPage(),
  );
}

class _AuthorizationPage extends StatefulWidget {
  const _AuthorizationPage();
  @override
  State<_AuthorizationPage> createState() => _AuthorizationPageState();
}

class _AuthorizationPageState extends State<_AuthorizationPage> {
  static const _sdkKey = String.fromEnvironment('CARRIER_SDK_KEY');
  static const _terms = String.fromEnvironment(
    'CARRIER_TERMS_URL',
    defaultValue: 'https://example.com/terms',
  );
  static const _privacy = String.fromEnvironment(
    'CARRIER_PRIVACY_URL',
    defaultValue: 'https://example.com/privacy',
  );
  final _carrier = const CarrierAuthClient();
  bool _busy = false;
  String _status = 'The example does not log in an account or display tokens.';

  Future<void> _authorize() async {
    setState(() => _busy = true);
    try {
      final result = await _carrier.authorize(
        CarrierOptions(
          sdkKey: _sdkKey,
          agreements: const [
            CarrierAgreement(title: 'Terms', url: _terms),
            CarrierAgreement(title: 'Privacy', url: _privacy),
          ],
        ),
      );
      if (!mounted) return;
      setState(
        () => _status = result.accepted
            ? 'Authorized. Send the token to your own server; it is not displayed here.'
            : 'Authorization ended: ${result.code}',
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _status = 'Check the SDK key and agreement configuration.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    if (_busy) unawaited(_carrier.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Carrier authorization example')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Configure CARRIER_SDK_KEY and your HTTPS agreement URLs before testing on a device.',
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _sdkKey.isEmpty || _busy ? null : _authorize,
            child: Text(
              _busy ? 'Opening authorization…' : 'Authorize this SIM',
            ),
          ),
          const SizedBox(height: 16),
          Text(_status),
        ],
      ),
    ),
  );
}
