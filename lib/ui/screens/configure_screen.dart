import 'package:flutter/material.dart';

import '../../main.dart';
import '../../models/models.dart';
import '../../services/ffmpeg_service.dart';
import '../../services/job_planner.dart';
import '../../services/settings_validator.dart';
import '../format.dart';
import 'processing_screen.dart';

/// Pre-flight configuration for the chosen mode. Shows trade-offs, blocking
/// validation errors, and non-blocking warnings before anything runs.
class ConfigureScreen extends StatefulWidget {
  const ConfigureScreen({
    super.key,
    required this.sourcePath,
    required this.sourceName,
    required this.media,
    required this.settings,
  });

  final String sourcePath;
  final String sourceName;
  final MediaInfo media;
  final CompressionSettings settings;

  @override
  State<ConfigureScreen> createState() => _ConfigureScreenState();
}

class _ConfigureScreenState extends State<ConfigureScreen> {
  late CompressionSettings _settings = widget.settings;
  FfmpegCapabilities? _caps;

  @override
  void initState() {
    super.initState();
    AppServices.ffmpeg.detectCapabilities().then((c) {
      if (mounted) setState(() => _caps = c);
    });
  }

  ValidationResult get _validation => SettingsValidator.validate(
        _settings,
        widget.media,
        caps: _caps == null
            ? null
            : FfmpegCapabilitiesLike.from(_caps!),
      );

  void _update(CompressionSettings s) => setState(() => _settings = s);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = widget.media;
    final video = media.videoStream!;
    final validation = _validation;

    return Scaffold(
      appBar: AppBar(title: const Text('Compression settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          // Mode selector --------------------------------------------------
          SegmentedButton<CompressionMode>(
            segments: const [
              ButtonSegment(
                  value: CompressionMode.exactLossless,
                  label: Text('Lossless')),
              ButtonSegment(
                  value: CompressionMode.highEfficiency,
                  label: Text('Efficient')),
              ButtonSegment(
                  value: CompressionMode.custom, label: Text('Custom')),
            ],
            selected: {_settings.mode},
            onSelectionChanged: (sel) {
              final mode = sel.first;
              _update(CompressionSettings(
                mode: mode,
                container: _settings.container,
                quality: _settings.quality,
                audio: mode == CompressionMode.exactLossless
                    ? AudioAction.copySource
                    : _settings.audio,
                hardware: _settings.hardware,
                keepMetadata: _settings.keepMetadata,
                videoCodec: VideoCodecOption.h264,
                losslessEncoder: LosslessEncoder.copy,
                // High Efficiency defaults to CRF (software); Custom stays
                // bitrate-based until the user asks for CRF.
                crf: mode == CompressionMode.highEfficiency ? 23 : null,
              ));
            },
          ),
          const SizedBox(height: 16),
          ..._modeControls(theme, video),
          const SizedBox(height: 16),
          _containerControl(),
          const SizedBox(height: 8),
          _metadataControl(),
          const SizedBox(height: 16),
          _estimateCard(),
          if (validation.warnings.isNotEmpty) ...[
            const SizedBox(height: 12),
            _IssuesCard(issues: validation.warnings, isError: false),
          ],
          if (validation.errors.isNotEmpty) ...[
            const SizedBox(height: 12),
            _IssuesCard(issues: validation.errors, isError: true),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: validation.canStart
                ? () => Navigator.of(context).pushReplacement(MaterialPageRoute(
                      builder: (_) => ProcessingScreen(
                        sourcePath: widget.sourcePath,
                        sourceName: widget.sourceName,
                        media: widget.media,
                        settings: _settings,
                      ),
                    ))
                : null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start compression'),
          ),
        ],
      ),
    );
  }

  List<Widget> _modeControls(ThemeData theme, StreamInfo video) {
    switch (_settings.mode) {
      case CompressionMode.exactLossless:
        return [
          _InfoCard(
            text: 'Exact Lossless never reduces quality. Stream copy (remux) '
                'repackages the original encoded data without re-encoding it '
                '— the video and audio data stay untouched, though the '
                'container, timestamps layout and metadata may change. A '
                'lossless re-encode decodes every frame, re-encodes it with '
                'a mathematically lossless setting, and is verified by '
                'comparing decoded frames. Both can produce a file that is '
                'the same size as — or larger than — the original.',
          ),
          const SizedBox(height: 12),
          ..._losslessEncoderControl(video),
          const SizedBox(height: 8),
          _audioControl(),
        ];
      case CompressionMode.highEfficiency:
        return [
          _InfoCard(
            text: 'High Efficiency re-encodes your video with CRF '
                '(constant quality). The result is high quality but '
                'mathematically lossy — this is NOT lossless. Resolution '
                'and frame rate are preserved unless you change them. Lower '
                'CRF = better quality and a larger file.',
          ),
          const SizedBox(height: 12),
          ..._hePresetControl(),
          const SizedBox(height: 8),
          ..._crfControl(),
          const SizedBox(height: 8),
          ..._speedControl(),
          const SizedBox(height: 8),
          ..._downscaleControl(video),
          const SizedBox(height: 8),
          _audioControl(),
        ];
      case CompressionMode.custom:
        return [
          ..._codecControl(includeCopy: true),
          const SizedBox(height: 8),
          ..._bitrateControl(),
          const SizedBox(height: 8),
          ..._fpsControl(video),
          const SizedBox(height: 8),
          ..._downscaleControl(video, allowCustom: true),
          const SizedBox(height: 8),
          ..._hardwareControl(),
          const SizedBox(height: 8),
          _audioControl(),
        ];
    }
  }

  // ------------------------------------------------------- lossless modes --
  /// Lossless encoder options (modes B/D/F + stream copy). Unavailable
  /// options are shown disabled with the exact reason — never silently
  /// swapped or faked.
  List<Widget> _losslessEncoderControl(StreamInfo video) {
    final caps = _caps;
    final highBitDepth = widget.media.isHighBitDepth;
    final pixFmt = video.pixFmt ?? 'yuv420p';
    String? x265Reason, x264Reason, av1Reason;
    if (highBitDepth) {
      x264Reason = x265Reason = av1Reason =
          'High bit-depth sources can only be kept via stream copy.';
    } else {
      if (caps != null && !caps.h264Software) {
        x264Reason = 'libx264 is not in this app\u2019s FFmpeg build.';
      } else if (!const {'yuv420p', 'yuv422p', 'yuv444p'}.contains(pixFmt)) {
        x264Reason = 'Pixel format $pixFmt cannot be preserved by libx264.';
      }
      if (caps != null && !caps.hevcSoftware) {
        x265Reason = 'libx265 is not in this app\u2019s FFmpeg build.';
      } else if (pixFmt != 'yuv420p') {
        x265Reason =
            'The packaged libx265 only preserves 8-bit $pixFmt sources losslessly for yuv420p — this source is $pixFmt.';
      }
      if (caps != null && !caps.av1Software) {
        av1Reason = 'No AV1 encoder (libaom-av1) in this app\u2019s FFmpeg build.';
      } else if (!const {'yuv420p', 'yuv422p', 'yuv444p'}.contains(pixFmt)) {
        av1Reason = 'Pixel format $pixFmt cannot be preserved losslessly by libaom-av1.';
      }
    }

    Widget tile(LosslessEncoder e, String title, String? reason) =>
        RadioListTile<LosslessEncoder>(
          value: e,
          enabled: reason == null,
          title: Text(title),
          subtitle: reason != null ? Text(reason) : null,
        );

    return [
      Text('Lossless method', style: Theme.of(context).textTheme.titleSmall),
      RadioGroup<LosslessEncoder>(
        groupValue: _settings.losslessEncoder,
        onChanged: (v) => _update(_settings.copyWith(losslessEncoder: v!)),
        child: Column(
          children: [
            tile(LosslessEncoder.copy,
                'Stream copy (fastest, no re-encoding)', null),
            tile(LosslessEncoder.x264, 'H.264 lossless — libx264 CRF 0',
                x264Reason),
            tile(LosslessEncoder.x265, 'HEVC lossless — libx265 lossless=1',
                x265Reason),
            tile(LosslessEncoder.av1, 'AV1 lossless — libaom-av1 lossless=1',
                av1Reason),
          ],
        ),
      ),
      const SizedBox(height: 4),
      Text(
        _settings.losslessEncoder == LosslessEncoder.copy
            ? 'No re-encoding happens, so the video data is bit-for-bit the '
                'same. Container and metadata can change; size stays about '
                'the same — this never shrinks the video data itself.'
            : 'Lossless re-encode: output may be larger than the original. '
                'Losslessness is verified by comparing decoded frames after '
                'encoding — it is never assumed.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ];
  }

  // ------------------------------------------------------ HE CRF presets --
  /// Modes A, C, G, E as one-tap presets (codec + default CRF).
  static const _hePresets = [
    (letter: 'A', label: 'Standard H.264 — CRF 23 (most compatible)',
        codec: VideoCodecOption.h264, crf: 23),
    (letter: 'C', label: 'H.265 / HEVC — CRF 26 (smaller, lossy)',
        codec: VideoCodecOption.hevc, crf: 26),
    (letter: 'G', label: 'H.265 low CRF — CRF 18 (highest quality, larger)',
        codec: VideoCodecOption.hevc, crf: 18),
    (letter: 'E', label: 'AV1 — CRF 30 (smallest, slowest, lossy)',
        codec: VideoCodecOption.av1, crf: 30),
  ];

  List<Widget> _hePresetControl() {
    final caps = _caps;
    bool available(VideoCodecOption c) {
      if (caps == null) return true;
      return switch (c) {
        VideoCodecOption.h264 => caps.h264Software,
        VideoCodecOption.hevc => caps.hevcSoftware,
        VideoCodecOption.av1 => caps.av1Software,
        _ => false,
      };
    }

    return [
      Text('Preset (all lossy)', style: Theme.of(context).textTheme.titleSmall),
      RadioGroup<int>(
        // index of the matching preset, or none when CRF was hand-edited
        groupValue: _hePresets.indexWhere((p) =>
            p.codec == _settings.videoCodec && p.crf == _settings.crf),
        onChanged: (i) {
          if (i == null || i < 0) return;
          final p = _hePresets[i];
          _update(_settings.copyWith(videoCodec: p.codec, crf: p.crf));
        },
        child: Column(
          children: [
            for (var i = 0; i < _hePresets.length; i++)
              RadioListTile<int>(
                value: i,
                enabled: available(_hePresets[i].codec),
                title: Text(_hePresets[i].label),
                subtitle: available(_hePresets[i].codec)
                    ? null
                    : Text(_hePresets[i].codec == VideoCodecOption.av1
                        ? 'No AV1 encoder in this app build.'
                        : 'HEVC encoder not available on this device.'),
              ),
          ],
        ),
      ),
    ];
  }

  int get _crfMax => _settings.videoCodec == VideoCodecOption.av1 ? 63 : 51;

  List<Widget> _crfControl() => [
        Text('Quality — CRF ${_settings.crf ?? 23} '
            '(lower = better quality, larger file)',
            style: Theme.of(context).textTheme.titleSmall),
        Slider(
          value: (_settings.crf ?? 23).clamp(0, _crfMax).toDouble(),
          min: 0,
          max: _crfMax.toDouble(),
          divisions: _crfMax,
          label: 'CRF ${_settings.crf ?? 23}',
          onChanged: (v) => _update(_settings.copyWith(crf: v.round())),
        ),
        Text(
          'This is lossy compression: quality is reduced to save space. '
          'CRF 18–23 is near-transparent for most videos; CRF $_crfMax is the '
          'worst quality. Very low CRF can make the file bigger than the original.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ];

  List<Widget> _speedControl() => [
        Text('Encoder speed', style: Theme.of(context).textTheme.titleSmall),
        DropdownButtonFormField<SpeedPreset>(
          initialValue: _settings.speedPreset,
          items: [
            for (final s in SpeedPreset.values)
              DropdownMenuItem(
                value: s,
                child: Text(s == SpeedPreset.medium
                    ? '${s.label} (recommended)'
                    : s.label),
              ),
          ],
          onChanged: (v) => _update(_settings.copyWith(speedPreset: v!)),
        ),
        const SizedBox(height: 4),
        Text('Slower settings usually produce a smaller file at the same '
            'quality, but take longer and use more battery.',
            style: Theme.of(context).textTheme.bodySmall),
      ];

  // ------------------------------------------------------------- controls --
  List<Widget> _codecControl({bool includeCopy = false}) {
    final caps = _caps;
    final codecs = <VideoCodecOption, String>{
      VideoCodecOption.h264: 'H.264 (most compatible)',
      VideoCodecOption.hevc: 'H.265 / HEVC (smaller, newer devices)',
      if (caps == null || caps.av1Software)
        VideoCodecOption.av1: 'AV1 (smallest, slowest)',
      if (includeCopy) VideoCodecOption.copySource: 'Copy source (no re-encode)',
    };
    final available = codecs.entries.where((e) {
      if (caps == null || e.key == VideoCodecOption.copySource) return true;
      return switch (e.key) {
        VideoCodecOption.hevc => caps.hevcSoftware || caps.hevcHardware,
        VideoCodecOption.av1 => caps.av1Software,
        _ => caps.h264Software || caps.h264Hardware,
      };
    }).toList();
    return [
      Text('Video codec', style: Theme.of(context).textTheme.titleSmall),
      RadioGroup<VideoCodecOption>(
        groupValue: _settings.videoCodec,
        onChanged: (v) => _update(_settings.copyWith(videoCodec: v!)),
        child: Column(
          children: [
            for (final e in available)
              RadioListTile<VideoCodecOption>(
                title: Text(e.value),
                value: e.key,
              ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _downscaleControl(StreamInfo video,
      {bool allowCustom = false}) {
    final h = video.height ?? 0;
    final options = <int?>[null];
    if (h > 1080) options.add(1080);
    if (h > 720) options.add(720);
    if (h > 480) options.add(480);
    if (options.length <= 1 && !allowCustom) return const [];
    return [
      Text('Resolution (optional downscale)',
          style: Theme.of(context).textTheme.titleSmall),
      DropdownButtonFormField<int?>(
        initialValue: _settings.targetHeight,
        items: [
          for (final o in options)
            DropdownMenuItem(
              value: o,
              child: Text(o == null
                  ? 'Keep source (${video.width}×${video.height})'
                  : '${_scaledW(video, o)}×$o'),
            ),
        ],
        onChanged: (v) => _update(_settings.copyWith(
          targetHeight: v,
          targetWidth: v == null ? null : _scaledW(video, v),
          clearResolution: v == null,
        )),
      ),
      const SizedBox(height: 4),
      Text('Downscaling is never applied unless you choose it.',
          style: Theme.of(context).textTheme.bodySmall),
    ];
  }

  static int _scaledW(StreamInfo video, int targetH) {
    final w = video.width ?? 0;
    final h = video.height ?? targetH;
    final scaled = (w * targetH / h).round();
    return scaled - (scaled % 2);
  }

  List<Widget> _bitrateControl() => [
        Text('Video bitrate (optional)',
            style: Theme.of(context).textTheme.titleSmall),
        TextFormField(
          initialValue: _settings.targetBitrateKbps?.toString(),
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            suffixText: 'kbps',
            hintText: 'Automatic (based on preset)',
            helperText: 'Leave empty to estimate from the quality preset.',
          ),
          onChanged: (v) {
            final parsed = int.tryParse(v.trim());
            _update(_settings.copyWith(
              targetBitrateKbps: (parsed == null || parsed <= 0) ? null : parsed,
              clearBitrate: parsed == null || parsed <= 0,
            ));
          },
        ),
      ];

  List<Widget> _fpsControl(StreamInfo video) => [
        Text('Frame rate (optional)',
            style: Theme.of(context).textTheme.titleSmall),
        TextFormField(
          initialValue: _settings.frameRate?.toString(),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            suffixText: 'fps',
            hintText: video.frameRate != null
                ? 'Keep source (${video.frameRate!.toStringAsFixed(2)})'
                : 'Automatic',
          ),
          onChanged: (v) {
            final parsed = double.tryParse(v.trim());
            _update(_settings.copyWith(
              frameRate: (parsed == null || parsed <= 0) ? null : parsed,
              clearFrameRate: parsed == null || parsed <= 0,
            ));
          },
        ),
      ];

  List<Widget> _hardwareControl() => [
        Text('Encoding hardware', style: Theme.of(context).textTheme.titleSmall),
        DropdownButtonFormField<HardwarePreference>(
          initialValue: _settings.hardware,
          items: const [
            DropdownMenuItem(
              value: HardwarePreference.auto,
              child: Text('Automatic (hardware if reliable)'),
            ),
            DropdownMenuItem(
              value: HardwarePreference.hardware,
              child: Text('Force hardware (faster, slightly lower quality)'),
            ),
            DropdownMenuItem(
              value: HardwarePreference.software,
              child: Text('Force software (best quality, slower)'),
            ),
          ],
          onChanged: (v) => _update(_settings.copyWith(hardware: v!)),
        ),
      ];

  Widget _audioControl() {
    final hasAudio = widget.media.audioStream != null;
    if (!hasAudio) {
      return const Text('This video has no audio stream.',
          style: TextStyle(fontStyle: FontStyle.italic));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Audio', style: Theme.of(context).textTheme.titleSmall),
        DropdownButtonFormField<AudioAction>(
          initialValue: _settings.audio,
          items: const [
            DropdownMenuItem(
                value: AudioAction.copySource, child: Text('Copy (keep as-is)')),
            DropdownMenuItem(
                value: AudioAction.aac128, child: Text('AAC 128 kbps')),
            DropdownMenuItem(
                value: AudioAction.aac96, child: Text('AAC 96 kbps')),
            DropdownMenuItem(
                value: AudioAction.aac64, child: Text('AAC 64 kbps')),
            DropdownMenuItem(
                value: AudioAction.opus96, child: Text('Opus 96 kbps (MKV)')),
            DropdownMenuItem(value: AudioAction.none, child: Text('Remove audio')),
          ],
          onChanged: (v) => _update(_settings.copyWith(audio: v!)),
        ),
      ],
    );
  }

  Widget _containerControl() => DropdownButtonFormField<ContainerOption>(
        initialValue: _settings.container,
        decoration: const InputDecoration(labelText: 'Output container'),
        items: const [
          DropdownMenuItem(value: ContainerOption.mp4, child: Text('MP4 (compatible)')),
          DropdownMenuItem(value: ContainerOption.mkv, child: Text('MKV (keeps more streams)')),
        ],
        onChanged: (v) => _update(_settings.copyWith(container: v!)),
      );

  Widget _metadataControl() => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Keep metadata'),
        subtitle: const Text('Title, creation date, rotation and color info.'),
        value: _settings.keepMetadata,
        onChanged: (v) => _update(_settings.copyWith(keepMetadata: v)),
      );

  // ------------------------------------------------------------ estimate --
  Widget _estimateCard() {
    final media = widget.media;
    final video = media.videoStream;
    String estimate;
    if (_settings.mode == CompressionMode.exactLossless) {
      estimate = _settings.losslessEncoder != LosslessEncoder.copy
          ? 'Lossless re-encode output is typically similar to or larger than the original.'
          : 'Stream copy output is approximately the same size as the original (${formatBytes(media.sizeBytes)}) — no re-encoding means no size win.';
    } else if (_settings.videoCodec == VideoCodecOption.copySource) {
      estimate = 'Stream copy output is approximately ${formatBytes(media.sizeBytes)}.';
    } else if (_settings.crf != null) {
      estimate = 'CRF ${_settings.crf} — the final size depends on the '
          'content. Lower CRF produces a larger, higher-quality file. '
          'This is lossy compression.';
    } else {
      final w = _settings.targetWidth ?? video?.width ?? 1280;
      final h = _settings.targetHeight ?? video?.height ?? 720;
      final fps = _settings.frameRate ?? video?.frameRate ?? 30.0;
      final kbps = _settings.targetBitrateKbps ??
          JobPlanner.debugEstimatedBitrateKbps(w, h, fps, _settings.quality,
              sourceVideoBitrate: video?.bitRate);
      final bytes = (kbps * 1000 / 8) * media.durationSeconds;
      estimate =
          'Estimated output ≈ ${formatBytes(bytes.round())} (rough estimate — actual size depends on content).';
    }
    return _InfoCard(text: estimate, icon: Icons.straighten_outlined);
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.text, this.icon = Icons.info_outline});
  final String text;
  final IconData icon;

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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: scheme.onSecondaryContainer),
          const SizedBox(width: 10),
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

class _IssuesCard extends StatelessWidget {
  const _IssuesCard({required this.issues, required this.isError});
  final List<ValidationIssue> issues;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isError ? scheme.errorContainer : scheme.tertiaryContainer;
    final onColor =
        isError ? scheme.onErrorContainer : scheme.onTertiaryContainer;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final issue in issues)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(isError ? Icons.cancel_outlined : Icons.warning_amber_rounded,
                      size: 18, color: onColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(issue.message,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: onColor)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
