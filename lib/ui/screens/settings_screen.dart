import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../config/app_config.dart';
import '../../main.dart';
import 'onboarding_screen.dart';

/// Settings: appearance, onboarding replay, permissions, diagnostics & logs, and about.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.onThemeChanged,
    required this.onHistoryToggled,
    required this.historyEnabled,
  });

  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool> onHistoryToggled;
  final bool historyEnabled;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ThemeMode _mode = ThemeMode.system;
  String _notificationStatus = 'Checking...';
  bool _exportingDiagnostics = false;
  int _diagnosticLogCount = 0;

  @override
  void initState() {
    super.initState();
    _refreshPermissions();
    _refreshDiagnosticCount();
  }

  Future<void> _refreshPermissions() async {
    final status = await AppServices.exporter.checkNotificationPermission();
    if (mounted) {
      setState(() {
        _notificationStatus = switch (status) {
          'granted' => 'Enabled',
          'denied' => 'Disabled',
          _ => 'Not requested / System default',
        };
      });
    }
  }

  Future<void> _refreshDiagnosticCount() async {
    final files = await AppServices.diagnosticExportService.getDiagnosticFiles();
    if (mounted) {
      setState(() {
        _diagnosticLogCount = files.length;
      });
    }
  }

  Future<void> _requestNotificationPermission() async {
    final res = await AppServices.exporter.requestNotificationPermission();
    await _refreshPermissions();
    if (res == 'denied' && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Notification permission was declined. Compression will continue to work normally.',
          ),
          action: SnackBarAction(
            label: 'Settings',
            onPressed: () => AppServices.exporter.openAppSettings(),
          ),
        ),
      );
    }
  }

  Future<void> _exportDiagnostics() async {
    if (_exportingDiagnostics) return;
    setState(() => _exportingDiagnostics = true);
    try {
      final zipPath = await AppServices.diagnosticExportService.generateReport();
      if (!mounted) return;
      final xfile = XFile(zipPath, mimeType: 'application/zip');
      final result = await SharePlus.instance.share(ShareParams(
        files: [xfile],
        subject: 'PureCompress Diagnostic Report',
        text: 'PureCompress Diagnostic Report bundle (ZIP)',
      ));
      if (mounted && result.status == ShareResultStatus.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Diagnostic report shared successfully.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export diagnostics: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _exportingDiagnostics = false);
    }
  }

  Future<void> _confirmClearLogs() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Diagnostic Logs?'),
        content: const Text(
          'This will remove temporary error logs and diagnostic crash reports.\n\n'
          'Your saved videos, compression history, and app preferences will NOT be affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear Logs'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final count = await AppServices.diagnosticExportService.clearLogs();
      await _refreshDiagnosticCount();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(count > 0
                ? '$count diagnostic log(s) cleared.'
                : 'No diagnostic logs to clear.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // -------------------------------------------------- Appearance ---
          const ListTile(
            title: Text('Appearance'),
            subtitle: Text('Dark / light theme follows this choice.'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) {
                setState(() => _mode = s.first);
                widget.onThemeChanged(s.first);
              },
            ),
          ),
          const Divider(height: 32),

          // -------------------------------------------------- Walkthrough --
          ListTile(
            leading: const Icon(Icons.school_outlined),
            title: const Text('How PureCompress Works'),
            subtitle: const Text('Replay the first-launch introduction and mode guide.'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (ctx) => OnboardingScreen(
                    isReplay: true,
                    onFinished: () => Navigator.of(ctx).pop(),
                  ),
                ),
              );
            },
          ),
          const Divider(height: 32),

          // ------------------------------------------------- Permissions ---
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              'Permissions & Access',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_none_rounded),
            title: const Text('Notifications'),
            subtitle: Text(
              'Status: $_notificationStatus\n'
              'Used solely to notify you when long-running background compression finishes. Denying will not affect compression.',
            ),
            isThreeLine: true,
            trailing: _notificationStatus == 'Disabled'
                ? OutlinedButton(
                    onPressed: () => AppServices.exporter.openAppSettings(),
                    child: const Text('Change'),
                  )
                : OutlinedButton(
                    onPressed: _requestNotificationPermission,
                    child: const Text('Check'),
                  ),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Video Access (SAF)'),
            subtitle: const Text(
              'Videos are chosen individually via Android\'s system picker. Broad storage access is never requested.',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.save_outlined),
            title: const Text('Export Storage'),
            subtitle: const Text(
              'Finished videos are exported directly to Movies/PureCompress via MediaStore. No storage permissions needed on Android 10+.',
            ),
          ),
          const Divider(height: 32),

          // ------------------------------------------------- Diagnostics ---
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              'Diagnostics & Error Logs',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Export Diagnostic Report'),
            subtitle: Text(
              '$_diagnosticLogCount crash/error log(s) available.\n'
              'Packages recent engine metrics, execution traces, and device info into a sanitized ZIP report.',
            ),
            isThreeLine: true,
            trailing: _exportingDiagnostics
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : FilledButton.tonal(
                    onPressed: _exportDiagnostics,
                    child: const Text('Export'),
                  ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('Clear Diagnostic Logs'),
            subtitle: const Text(
              'Deletes saved error logs from device storage. Does not affect history, settings, or videos.',
            ),
            onTap: _diagnosticLogCount > 0 ? _confirmClearLogs : null,
          ),
          const Divider(height: 32),

          // ----------------------------------------------------- History ---
          SwitchListTile(
            title: const Text('Keep recent compression list'),
            subtitle: const Text(
                'Stored only on this device. Source file paths are never saved.'),
            value: widget.historyEnabled,
            onChanged: widget.onHistoryToggled,
          ),
          ListTile(
            title: const Text('Clear history'),
            onTap: () async {
              await AppServices.jobRepository.clear();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('History cleared.')));
              }
            },
          ),
          const Divider(height: 32),

          // ------------------------------------------------------- About ---
          ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/images/logo.png',
                width: 36,
                height: 36,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    const Icon(Icons.movie_creation_outlined),
              ),
            ),
            title: const Text('About ${AppConfig.appName}'),
            subtitle: Text(
                '${AppConfig.privacyStatement}\n\nVersion ${AppConfig.version}\n'
                'Processing engine: FFmpeg (full GPL build), runs fully offline.'),
          ),
        ],
      ),
    );
  }
}