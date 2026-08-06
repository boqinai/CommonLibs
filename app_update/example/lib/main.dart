import 'package:app_update/app_update.dart';
import 'package:flutter/material.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('App Update Example')),
      body: Center(
        child: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              final result = await AppUpdateService(
                updateApiUrl:
                    'https://api.boqinai.com/updatecenter/api/v1/update',
              ).checkForUpdate();
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(result.status.name)));
              }
            },
            child: const Text('检查更新'),
          ),
        ),
      ),
    ),
  );
}
