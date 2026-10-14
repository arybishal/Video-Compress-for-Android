import 'package:flutter/material.dart';

import '../../main.dart';
import '../../models/models.dart';
import '../../services/ffmpeg_service.dart';
import '../../services/settings_validator.dart';
import '../format.dart';
import 'configure_screen.dart';

/// Video analysis: everything ffprobe learned about the selected file,
/// storage availability, and which modes are supported.
class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen({
    super.key,
    required this.sourcePath,
    required this.sourceName,
    required this.sourceBytes,
    this.initialMode,
  });

  final String sourcePath;
  final String sourceName;
  final int sourceBytes;
  final CompressionMode? initialMode;

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  MediaInfo? _media;
  FfmpegCapabilities? _caps;
  int? _freeBytes;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _analyze();
  }

  Future<void> _analyze() async {
    try {
      final media = await AppServices.ffmpeg
          .probe(widget.sourcePath, fallbackSizeBytes: widget.sourceBytes);
      final caps = await AppServices.ffmpeg.detectCapabilities();
      final free = await AppServices.exporter.freeBytes();
      if (!mounted) return;
      setState(() {
        _media = media;
        _caps = caps;
        _freeBytes = free;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Video details')),
      body: _error != null
          ? _ErrorView(
              message: _error is FfmpegException
                  ? (_error as FfmpegException).userMessage
                  : 'The file could not be analyzed.',
              onRetry: () {
                setState(() => _error = null);
                _analyze();
              },
            )
          : _media == null
              ? const Center(child: CircularProgressIndicator())
              : _buildContent(theme),
    );
  }

  Widget _buildContent(ThemeData theme) {
    final media = _media!;
    final video = media.videoStream;
    final audio = media.audioStream;
    final modes = _supportedModes(media);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        Text(widget.sourceName,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('Original size: ${formatBytes(media.sizeBytes)}',
            style: theme.textTheme.bodyMedium),
        const SizedBox(height: 16),
        _Section(title: 'Stream information', children: [
          _row('Duration', formatDuration(media.durationSeconds)),
          _row('Resolution',
              video != null ? '${video.width}×${video.height}' : '—'),
          _row('Frame rate', video?.frameRate != null
              ? '${video!.frameRate!.toStringAsFixed(2)} fps'
              : '—'),
          _row('Video codec',
              video != null ? '${video.codecName}${video.pixFmt != null ? ' · ${video.pixFmt}' : ''}' : '—'),
          _row('Audio codec',
              audio != null ? '${audio.codecName}${audio.channels != null ? ' · ${audio.channels} ch' : ''}' : 'no audio'),
          _row('Rotation', '${video?.rotationDegrees ?? 0}°'),
          _row('Container', media.formatName),
          if (_freeBytes != null)
            _row('Free storage', formatBytes(_freeBytes!)),
        ]),
        const SizedBox(height: 16),
        _Section(title: 'Supported modes', children: [
          for (final m in modes.entries)
            _row(
              _modeLabel(m.key),
              m.value.isEmpty
                  ? 'Supported'
                  : 'Limited: ${m.value.join('; ')}',
            ),
        ]),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () async {
            final defaultSettings = _defaultSettingsFor(modes);
            await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ConfigureScreen(
                sourcePath: widget.sourcePath,
                sourceName: widget.sourceName,
                media: media,
                settings: defaultSettings,
              ),
            ));
          },
          child: const Text('Choose compression settings'),
        ),
      ],
    );
  }

  /// Maps each mode to the list of limitations for this specific file.
  Map<CompressionMode, List<String>> _supportedModes(MediaInfo media) {
    final caps = _caps;
    final video = media.videoStream;
    final result = <CompressionMode, List<String>>{};

    // Exact Lossless: always possible via some path (remux or lossless
    // re-encode), but note when stream copy is unavailable.
    final losslessLimits = <String>[];
    if (video != null &&
        !SettingsValidator.videoCodecFitsContainer(
            video.codecName, _containerFor(media))) {
      losslessLimits.add('stream copy not possible for this container');
    }
    if (media.isHighBitDepth) {
      losslessLimits.add('re-encode unavailable (high bit depth) — remux only');
    }
    result[CompressionMode.exactLossless] = losslessLimits;

    final heLimits = <String>[];
    if (caps != null && !caps.h264Hardware && !caps.h264Software) {
      heLimits.add('no H.264 encoder available');
    }
    result[CompressionMode.highEfficiency] = heLimits;

    result[CompressionMode.custom] = const [];
    return result;
  }

  static ContainerOption _containerFor(MediaInfo media) {
    final fmt = media.formatName.toLowerCase();
    return fmt.contains('matroska') || fmt.contains('webm')
        ? ContainerOption.mkv
        : ContainerOption.mp4;
  }

  CompressionSettings _defaultSettingsFor(Map<CompressionMode, List<String>> modes) {
    final container = _containerFor(_media!);
    final startMode = widget.initialMode ?? CompressionMode.highEfficiency;
    if (startMode == CompressionMode.exactLossless) {
      return CompressionSettings(
          mode: CompressionMode.exactLossless, container: container);
    }
    if (startMode == CompressionMode.custom) {
      return CompressionSettings(
          mode: CompressionMode.custom, container: container);
    }
    return CompressionSettings(
        mode: CompressionMode.highEfficiency, container: container);
  }

  static String _modeLabel(CompressionMode m) => switch (m) {
        CompressionMode.exactLossless => 'Exact Lossless',
        CompressionMode.highEfficiency => 'High Efficiency',
        CompressionMode.custom => 'Custom',
      };

  static Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 130,
                child: Text(k,
                    style: const TextStyle(fontWeight: FontWeight.w500))),
            Expanded(child: Text(v)),
          ],
        ),
      );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
