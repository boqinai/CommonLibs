import 'dart:async';

import 'package:flutter/material.dart';

import 'app_update.dart';

enum UpdateDialogAction { later, backgroundDownload }

/// Displays the shared Material update prompt.
///
/// Selecting background download closes the dialog immediately while the
/// native foreground service continues the download and reports progress in
/// the Android notification shade.
Future<UpdateDialogAction?> showDefaultUpdateDialog(
  BuildContext context, {
  required AppUpdateService service,
  required AppUpdateInfo update,
  bool wifiOnly = false,
  Duration downloadTimeout = const Duration(minutes: 30),
  void Function(int downloadId)? onDownloadStarted,
  void Function(bool installerOpened)? onDownloadFinished,
}) {
  return showDialog<UpdateDialogAction>(
    context: context,
    barrierDismissible: !update.forceUpdate,
    builder: (context) => _DefaultUpdateDialog(
      service: service,
      update: update,
      wifiOnly: wifiOnly,
      downloadTimeout: downloadTimeout,
      onDownloadStarted: onDownloadStarted,
      onDownloadFinished: onDownloadFinished,
    ),
  );
}

class _DefaultUpdateDialog extends StatefulWidget {
  const _DefaultUpdateDialog({
    required this.service,
    required this.update,
    required this.wifiOnly,
    required this.downloadTimeout,
    this.onDownloadStarted,
    this.onDownloadFinished,
  });

  final AppUpdateService service;
  final AppUpdateInfo update;
  final bool wifiOnly;
  final Duration downloadTimeout;
  final void Function(int downloadId)? onDownloadStarted;
  final void Function(bool installerOpened)? onDownloadFinished;

  @override
  State<_DefaultUpdateDialog> createState() => _DefaultUpdateDialogState();
}

class _DefaultUpdateDialogState extends State<_DefaultUpdateDialog> {
  bool _allowPop = false;

  void _close(UpdateDialogAction action) {
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(action);
    });
  }

  void _startBackgroundDownload() {
    final download = widget.service.downloadAndInstall(
      widget.update.downloadUrl,
      version: widget.update.versionName,
      wifiOnly: widget.wifiOnly,
      downloadTimeout: widget.downloadTimeout,
      onStarted: widget.onDownloadStarted,
    );
    unawaited(
      download.then((opened) => widget.onDownloadFinished?.call(opened)),
    );
    _close(UpdateDialogAction.backgroundDownload);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final notes = widget.update.releaseNotes.trim();

    return PopScope(
      canPop: _allowPop || !widget.update.forceUpdate,
      child: AlertDialog(
        icon: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(
              Icons.system_update_alt,
              color: colors.onPrimaryContainer,
            ),
          ),
        ),
        title: const Text('发现新版本', textAlign: TextAlign.center),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Chip(
                  avatar: const Icon(Icons.new_releases_outlined, size: 18),
                  label: Text('v${widget.update.versionName}'),
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                notes.isEmpty ? '新版本已准备就绪，建议更新后继续使用。' : notes,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.notifications_outlined, size: 20),
                      SizedBox(width: 10),
                      Expanded(child: Text('下载将在后台继续，可在通知栏查看实时进度。')),
                    ],
                  ),
                ),
              ),
              if (widget.update.forceUpdate) ...[
                const SizedBox(height: 12),
                Text(
                  '此版本需要更新后使用',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.error,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (!widget.update.forceUpdate)
            TextButton(
              onPressed: () => _close(UpdateDialogAction.later),
              child: const Text('稍后再说'),
            ),
          FilledButton.icon(
            onPressed: _startBackgroundDownload,
            icon: const Icon(Icons.download_outlined),
            label: const Text('后台下载'),
          ),
        ],
      ),
    );
  }
}
