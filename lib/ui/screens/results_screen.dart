import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../config/app_config.dart';
import '../../main.dart';
import '../../models/models.dart';
import '../format.dart';

/// Honest results: real sizes, real savings (even negative), real duration,
/// and verification only when it actually completed.
class ResultsScreen extends StatefulWidget {
  const ResultsScreen({super.key, required this.record});

  final JobRecord record;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  bool _exporting = false;
  String? _exportedUri;

  JobRecord get record => widget.record;
  bool get hasFile => record.outputPath != null;

  Future<void> _play() async {
    final path = record.outputPath;
    if (path == null) return;
    try {
      await AppServices.exporter.openWith(path);
    } catch (_) {
      _snack('No app found to play this video.');
    }
  }

  Future<void> _share() async {
    final path = record.outputPath;
    if (path == null) return;
    await SharePlus.instance.share(ShareParams(
      files: [XFile(path)],
      title: record.sourceName,
    ));
  }

  Future<void> _save() async {
    final path = record.outputPath;
    if (path == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      final uri = await AppServices.exporter.exportToMovies(
          path, _exportName());
      if (!mounted) return;
      setState(() => _exportedUri = uri);
      _snack('Saved to Movies/${AppConfig.exportDirName}.');
    } catch (e) {
      _snack('$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String _exportName() {
    final dot = record.sourceName.lastIndexOf('.');
    final base = dot > 0 ? record.sourceName.substring(0, dot) : record.sourceName;
    final ext = record.outputPath!.split('.').last;
    return '${base}_compressed.$ext';
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final saved = record.bytesDelta >= 0;
    final v = record.verification;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Result'),
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text(record.sourceName,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  _kv('Original size', formatBytes(record.originalBytes)),
                  _kv('Output size', formatBytes(record.outputBytes)),
                  Divider(color: theme.colorScheme.outlineVariant),
                  _kv(
                    saved ? 'Saved' : 'Increased by',
                    formatBytes(record.bytesDelta.abs()),
                    highlight: true,
                  ),
                  _kv(
                    saved ? 'Savings' : 'Size increase',
                    '${saved ? '' : '+'}${record.percentSaved.abs().toStringAsFixed(1)}%',
                    highlight: true,
                    highlightColor: saved
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                  _kv('Processing time',
                      formatDuration(record.durationMs / 1000)),
                  _kv('Mode', _modeLabel()),
                  _kv('Output codec', record.videoCodec),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (record.mode == CompressionMode.exactLossless)
            _verificationTile(v)
          else if (record.integrity != null)
            _integrityTile(record.integrity!),
          if (!hasFile)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'The temporary output file is no longer available '
                '(the app may have been restarted). Compress the video again to produce a new file.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 20),
          if (hasFile) ...[
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _play,
                    icon: const Icon(Icons.play_circle_outline),
                    label: const Text('Play'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _share,
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Share'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _exporting ? null : _save,
              icon: _exporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(_exportedUri != null
                      ? Icons.check_circle_outline
                      : Icons.save_alt_outlined),
              label: Text(_exportedUri != null ? 'Saved to device' : 'Save to device'),
            ),
          ],
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.replay),
            label: const Text('Compress another video'),
          ),
        ],
      ),
    );
  }

  String _modeLabel() => switch (record.mode) {
        CompressionMode.exactLossless => 'Exact Lossless',
        CompressionMode.highEfficiency => 'High Efficiency (lossy)',
        CompressionMode.custom => 'Custom',
      };

  Widget _integrityTile(IntegrityResult i) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: Icon(
          i.ok ? Icons.check_circle_outline : Icons.warning_amber_rounded,
          color: i.ok ? theme.colorScheme.primary : theme.colorScheme.error,
        ),
        title: Text(i.ok
            ? 'Output verified playable'
            : 'Output check found problems'),
        subtitle: Text(i.detail ??
            (i.ok
                ? 'The output decodes correctly with the expected duration, '
                    'resolution and audio. This is a lossy result — it is not '
                    'a losslessness claim.'
                : 'The output may not match what was requested.')),
      ),
    );
  }

  Widget _verificationTile(VerificationResult? v) {
    final theme = Theme.of(context);
    if (v == null || !v.completed) {
      return Card(
        child: ListTile(
          leading: Icon(Icons.help_outline, color: theme.colorScheme.outline),
          title: const Text('Lossless verification not completed'),
          subtitle: const Text(
              'We cannot claim the output is lossless because verification did not finish.'),
        ),
      );
    }
    final identical = v.fullyIdentical;
    return Card(
      child: ListTile(
        leading: Icon(
          identical ? Icons.verified : Icons.cancel_outlined,
          color: identical ? theme.colorScheme.primary : theme.colorScheme.error,
        ),
        title: Text(identical
            ? 'Verified lossless'
            : 'Verification found differences'),
        subtitle: Text(v.detail ??
            (identical
                ? 'Decoded video frames and audio samples match the source exactly.'
                : 'Decoded output does not match the source — the result is not lossless.')),
      ),
    );
  }

  Widget _kv(String k, String v,
      {bool highlight = false, Color? highlightColor}) {
    final style = highlight
        ? Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: highlightColor ?? Theme.of(context).colorScheme.primary,
            )
        : Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(child: Text(k)),
          Text(v, style: style),
        ],
      ),
    );
  }
}
