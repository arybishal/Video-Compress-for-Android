import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../../main.dart';
import '../../models/models.dart';
import '../format.dart';
import 'analysis_screen.dart';
import 'settings_screen.dart';

/// Home: app identity, prominent Select Video, the three modes, privacy note,
/// and recent local jobs.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.historyEnabled,
    required this.onThemeChanged,
    required this.onHistoryToggled,
  });

  final bool historyEnabled;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool> onHistoryToggled;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _picking = false;
  List<JobRecord> _history = const [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    if (!widget.historyEnabled) {
      setState(() => _history = const []);
      return;
    }
    final records = await AppServices.jobRepository.load();
    if (mounted) setState(() => _history = records);
  }

  @override
  void didUpdateWidget(covariant HomeScreen old) {
    super.didUpdateWidget(old);
    if (old.historyEnabled != widget.historyEnabled) _loadHistory();
  }

  Future<void> _pickVideo({CompressionMode? mode}) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final file = await AppServices.exporter.pickVideo();
      if (file == null) return;
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AnalysisScreen(
          sourcePath: file.path,
          sourceName: file.name,
          sourceBytes: file.size,
          initialMode: mode,
        ),
      ));
      _loadHistory();
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(AppConfig.appName,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SettingsScreen(
                  onThemeChanged: widget.onThemeChanged,
                  onHistoryToggled: widget.onHistoryToggled,
                  historyEnabled: widget.historyEnabled,
                ),
              ));
              _loadHistory();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _picking ? null : () => _pickVideo(),
            icon: _picking
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.video_library_outlined),
            label: const Text('Select video'),
          ),
          const SizedBox(height: 12),
          _ModeRow(onPick: _pickVideo),
          const SizedBox(height: 20),
          _PrivacyNote(text: AppConfig.privacyStatement),
          if (widget.historyEnabled && _history.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Recent compressions', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final job in _history.take(8)) _JobTile(job: job),
          ],
        ],
      ),
    );
  }
}

class _ModeRow extends StatelessWidget {
  const _ModeRow({required this.onPick});
  final void Function({CompressionMode? mode}) onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget card(CompressionMode mode, IconData icon, String title, String sub) {
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => onPick(mode: mode),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 22, color: theme.colorScheme.primary),
                const SizedBox(height: 8),
                Text(title,
                    style: theme.textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(sub,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            card(CompressionMode.exactLossless, Icons.verified_outlined,
                'Exact Lossless', 'Remux or lossless re-encode'),
            card(CompressionMode.highEfficiency, Icons.bolt_outlined,
                'High Efficiency', 'Quality-first lossy'),
            card(CompressionMode.custom, Icons.tune, 'Custom',
                'Codec, size, fps, audio'),
          ],
        ),
      ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.shield_outlined, color: scheme.onSecondaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSecondaryContainer)),
          ),
        ],
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.job});
  final JobRecord job;

  @override
  Widget build(BuildContext context) {
    final saved = job.bytesDelta >= 0;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          job.status == JobStatus.completed
              ? Icons.check_circle_outline
              : Icons.error_outline,
          color: job.status == JobStatus.completed
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.error,
        ),
        title: Text(job.sourceName, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${formatBytes(job.originalBytes)} → ${formatBytes(job.outputBytes)}'
          ' · ${saved ? 'saved ${formatBytes(job.bytesDelta)}' : 'grew ${formatBytes(-job.bytesDelta)}'}'
          ' · ${job.videoCodec}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(
          saved ? formatPercent(job.percentSaved) : '+${(-job.percentSaved).toStringAsFixed(1)}%',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: saved
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.error,
              ),
        ),
      ),
    );
  }
}
