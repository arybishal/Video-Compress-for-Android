import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../../main.dart';

/// Settings: appearance, local history control, privacy/about.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
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
          ListTile(
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