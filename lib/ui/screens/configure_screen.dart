import 'package:flutter/material.dart';

import '../../main.dart';
import '../../models/models.dart';
import '../../services/bitrate_calculator.dart';
import '../../services/ffmpeg_service.dart';
import '../../services/job_planner.dart';
import '../../services/settings_validator.dart';
import '../format.dart';
import 'processing_screen.dart';

/// Production-ready video compression configuration screen and preset manager.
/// Structured into 10 organized sections:
/// 1. Selected video & original file information
/// 2. Compression profile (High, Medium, Low)
/// 3. Platform or custom preset
/// 4. Encoding codec (H.264/AVC & H.265/HEVC as unified choices)
/// 5. Target size & compression strength slider / manual MB/GB input
/// 6. Output resolution with aspect-ratio preservation
/// 7. Output frame rate
/// 8. Audio settings (keep original or remove audio)
/// 9. Estimated output information
/// 10. Compress action
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
  late CompressionSettings _settings;
  FfmpegCapabilities? _caps;
  List<CompressionPreset> _presets = [];
  CompressionPreset? _selectedPreset;
  late TextEditingController _targetSizeTextController;
  bool _showAdvancedSettings = false;
  bool _isLosslessMode = false;

  @override
  void initState() {
    super.initState();
    _settings = widget.settings;
    _isLosslessMode = widget.settings.mode == CompressionMode.exactLossless;

    _targetSizeTextController = TextEditingController(
      text: _settings.targetSizeBytes != null
          ? (_settings.targetSizeBytes! / (1024 * 1024)).toStringAsFixed(1)
          : '',
    );

    _loadCapabilitiesAndPresets();
  }

  @override
  void dispose() {
    _targetSizeTextController.dispose();
    super.dispose();
  }

  Future<void> _loadCapabilitiesAndPresets() async {
    final caps = await AppServices.ffmpeg.detectCapabilities();
    final presets = await AppServices.presetRepository.loadPresets();
    if (!mounted) return;

    setState(() {
      _caps = caps;
      _presets = presets;
      if (_settings.presetId != null) {
        _selectedPreset = presets.firstWhere(
          (p) => p.id == _settings.presetId,
          orElse: () => presets.first,
        );
      }
    });
  }

  void _update(CompressionSettings s) {
    setState(() {
      _settings = s;
      if (s.targetSizeBytes != null) {
        final mb = s.targetSizeBytes! / (1024 * 1024);
        final formatted = mb >= 100 ? mb.round().toString() : mb.toStringAsFixed(1);
        if (_targetSizeTextController.text != formatted) {
          _targetSizeTextController.text = formatted;
        }
      } else {
        if (_targetSizeTextController.text.isNotEmpty && s.mode != CompressionMode.exactLossless) {
          _targetSizeTextController.clear();
        }
      }
    });
  }

  ValidationResult get _validation => SettingsValidator.validate(
        _settings,
        widget.media,
        caps: _caps == null ? null : FfmpegCapabilitiesLike.from(_caps!),
      );

  // -------------------------------------------------- Profile handling --
  void _applyProfile(CompressionProfile profile) {
    final video = widget.media.videoStream!;
    final sourceW = video.width ?? 1920;
    final sourceH = video.height ?? 1080;

    int? targetW;
    int? targetH;
    int crf = 23;
    QualityPreset quality = QualityPreset.balanced;

    switch (profile) {
      case CompressionProfile.high:
        // Preserves original up to 4K
        final dims = ResolutionPreset.p4k.calculateDimensions(sourceW, sourceH);
        targetW = dims.$1;
        targetH = dims.$2;
        crf = 18;
        quality = QualityPreset.highQuality;
        break;
      case CompressionProfile.medium:
        // 1080p maximum
        final dims = ResolutionPreset.p1080.calculateDimensions(sourceW, sourceH);
        targetW = dims.$1;
        targetH = dims.$2;
        crf = 23;
        quality = QualityPreset.balanced;
        break;
      case CompressionProfile.low:
        // 720p maximum
        final dims = ResolutionPreset.p720.calculateDimensions(sourceW, sourceH);
        targetW = dims.$1;
        targetH = dims.$2;
        crf = 28;
        quality = QualityPreset.smaller;
        break;
    }

    _update(_settings.copyWith(
      mode: CompressionMode.highEfficiency,
      profile: profile,
      clearPresetId: true,
      crf: crf,
      quality: quality,
      targetWidth: (targetW == sourceW && targetH == sourceH) ? null : targetW,
      targetHeight: (targetW == sourceW && targetH == sourceH) ? null : targetH,
      clearResolution: (targetW == sourceW && targetH == sourceH),
      clearTargetSize: true,
      clearBitrate: true,
    ));
    setState(() {
      _selectedPreset = null;
      _isLosslessMode = false;
    });
  }

  // --------------------------------------------------- Preset handling --
  void _applyPreset(CompressionPreset preset) {
    final video = widget.media.videoStream!;
    final sourceW = video.width ?? 1920;
    final sourceH = video.height ?? 1080;

    int? targetW;
    int? targetH;
    if (preset.targetHeight != null) {
      final resPreset = ResolutionPreset.all.firstWhere(
        (p) => p.standardHeight == preset.targetHeight,
        orElse: () => ResolutionPreset.p1080,
      );
      final dims = resPreset.calculateDimensions(sourceW, sourceH);
      if (dims.$1 < sourceW || dims.$2 < sourceH) {
        targetW = dims.$1;
        targetH = dims.$2;
      }
    }

    _update(_settings.copyWith(
      mode: CompressionMode.highEfficiency,
      presetId: preset.id,
      profile: preset.profile,
      videoCodec: preset.videoCodec,
      targetSizeBytes: preset.targetSizeBytes,
      targetWidth: targetW,
      targetHeight: targetH,
      clearResolution: targetW == null,
      frameRate: preset.frameRate,
      clearFrameRate: preset.frameRate == null,
      audio: preset.audio,
      container: preset.container,
      crf: preset.crf,
      quality: preset.quality,
      speedPreset: preset.speedPreset,
      hdrMode: preset.hdrMode ?? _settings.hdrMode,
      hdrIntensity: preset.hdrIntensity ?? _settings.hdrIntensity,
      clearBitrate: true,
    ));
    setState(() {
      _selectedPreset = preset;
      _isLosslessMode = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = widget.media;
    final video = media.videoStream!;
    final validation = _validation;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Compress Video'),
        actions: [
          IconButton(
            tooltip: _isLosslessMode
                ? 'Switch to Lossy Compression'
                : 'Exact Lossless Mode',
            icon: Icon(_isLosslessMode ? Icons.tune : Icons.verified_outlined),
            onPressed: () {
              setState(() {
                _isLosslessMode = !_isLosslessMode;
                if (_isLosslessMode) {
                  _update(CompressionSettings(
                    mode: CompressionMode.exactLossless,
                    container: _settings.container,
                    losslessEncoder: LosslessEncoder.copy,
                    audio: AudioAction.copySource,
                    keepMetadata: _settings.keepMetadata,
                  ));
                } else {
                  _applyProfile(CompressionProfile.medium);
                }
              });
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          // 1. Selected video & original file info card
          _buildSourceInfoSection(theme, media, video),
          const SizedBox(height: 16),

          if (_isLosslessMode) ...[
            _buildLosslessBanner(theme),
            const SizedBox(height: 16),
            ..._losslessEncoderControl(video),
            const SizedBox(height: 16),
            _buildAudioSection(theme, media),
            const SizedBox(height: 16),
            _buildContainerSection(theme),
          ] else ...[
            // 2. Compression Profile
            _buildProfileSection(theme),
            const SizedBox(height: 16),

            // 3. Platform or custom preset
            _buildPresetSection(theme),
            const SizedBox(height: 16),

            // 4. Encoding Codec
            _buildCodecSection(theme),
            const SizedBox(height: 16),

            // 5. Target Size & Compression Strength
            _buildTargetSizeSection(theme, media),
            const SizedBox(height: 16),

            // 6. Output Resolution
            _buildResolutionSection(theme, video),
            const SizedBox(height: 16),

            // 7. Output Frame Rate
            _buildFrameRateSection(theme, video),
            const SizedBox(height: 16),

            // 8. Audio Settings
            _buildAudioSection(theme, media),
            const SizedBox(height: 16),

            // 9. HDR & Color
            _buildHdrSection(theme, media, video),
            const SizedBox(height: 16),

            // Advanced Collapsible Settings
            _buildAdvancedSettingsSection(theme),
          ],

          const SizedBox(height: 16),

          // 9. Estimated output information
          _buildEstimateSection(theme, media, video),
          const SizedBox(height: 12),

          // Validation Warnings & Errors
          if (validation.warnings.isNotEmpty) ...[
            _IssuesCard(issues: validation.warnings, isError: false),
            const SizedBox(height: 12),
          ],
          if (validation.errors.isNotEmpty) ...[
            _IssuesCard(issues: validation.errors, isError: true),
            const SizedBox(height: 12),
          ],

          // 10. Compress action
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
            label: Text(
              _isLosslessMode
                  ? 'Start Lossless Stream Copy'
                  : 'Start Compression',
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 1. Source Video & Original File Information
  // -------------------------------------------------------------------------
  Widget _buildSourceInfoSection(
      ThemeData theme, MediaInfo media, StreamInfo video) {
    final scheme = theme.colorScheme;
    final audio = media.audioStream;

    return Card(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.video_file, color: scheme.primary, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.sourceName,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _InfoBadge(
                  icon: Icons.sd_card_outlined,
                  label: formatBytes(media.sizeBytes),
                ),
                _InfoBadge(
                  icon: Icons.timer_outlined,
                  label: formatDuration(media.durationSeconds),
                ),
                _InfoBadge(
                  icon: Icons.aspect_ratio,
                  label: '${video.width ?? '?'}×${video.height ?? '?'}',
                ),
                _InfoBadge(
                  icon: Icons.speed,
                  label: '${video.frameRate?.toStringAsFixed(1) ?? '?'} fps',
                ),
                _InfoBadge(
                  icon: Icons.memory,
                  label: '${video.codecName.toUpperCase()} (${video.pixFmt ?? 'yuv420p'})',
                ),
                _InfoBadge(
                  icon: video.isHdr ? Icons.hdr_on : Icons.palette_outlined,
                  label: video.colorSummary,
                ),
                _InfoBadge(
                  icon: audio != null ? Icons.volume_up : Icons.volume_off,
                  label: audio != null
                      ? '${audio.codecName.toUpperCase()}${audio.sampleRate != null ? ' ${audio.sampleRate! ~/ 1000}kHz' : ''}'
                      : 'No Audio',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 2. Compression Profile (High, Medium, Low)
  // -------------------------------------------------------------------------
  Widget _buildProfileSection(ThemeData theme) {
    final currentProfile = _settings.profile ?? CompressionProfile.medium;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('1. Compression Profile',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            if (_settings.profile != null)
              TextButton.icon(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: () => _applyProfile(currentProfile),
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('Reset profile defaults',
                    style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        SegmentedButton<CompressionProfile>(
          segments: const [
            ButtonSegment(
              value: CompressionProfile.high,
              label: Text('High'),
              icon: Icon(Icons.high_quality),
            ),
            ButtonSegment(
              value: CompressionProfile.medium,
              label: Text('Medium'),
              icon: Icon(Icons.tune),
            ),
            ButtonSegment(
              value: CompressionProfile.low,
              label: Text('Low'),
              icon: Icon(Icons.compress),
            ),
          ],
          selected: {currentProfile},
          onSelectionChanged: (selected) => _applyProfile(selected.first),
        ),
        const SizedBox(height: 4),
        Text(
          currentProfile.description,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // 3. Platform or Custom Preset Manager
  // -------------------------------------------------------------------------
  Widget _buildPresetSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('2. Platform & Custom Presets',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            PopupMenuButton<String>(
              tooltip: 'Preset options',
              icon: const Icon(Icons.more_horiz),
              onSelected: (choice) async {
                if (choice == 'reset') {
                  final confirm = await _showConfirmDialog(
                    title: 'Reset to default presets?',
                    message: 'This will remove all custom presets and restore built-in platform presets.',
                  );
                  if (confirm == true) {
                    await AppServices.presetRepository.resetToDefaults();
                    await _loadCapabilitiesAndPresets();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Presets reset to defaults')),
                      );
                    }
                  }
                } else if (choice == 'restore') {
                  await AppServices.presetRepository.restoreMissingDefaults();
                  await _loadCapabilitiesAndPresets();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Missing defaults restored')),
                    );
                  }
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'restore',
                  child: Text('Restore missing defaults'),
                ),
                PopupMenuItem(
                  value: 'reset',
                  child: Text('Reset to default presets'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 6),
        InputDecorator(
          decoration: const InputDecoration(
            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
            contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              value: _selectedPreset?.id,
              isExpanded: true,
              hint: const Text('Custom / Manual configuration'),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Manual configuration (no preset)'),
                ),
                for (final preset in _presets)
                  DropdownMenuItem<String?>(
                    value: preset.id,
                    child: Row(
                      children: [
                        Icon(
                          preset.isBuiltIn ? Icons.bookmark_outline : Icons.star_border,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            preset.targetSizeBytes != null
                                ? '${preset.name} (${formatBytes(preset.targetSizeBytes!)})'
                                : preset.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              onChanged: (id) {
                if (id == null) {
                  setState(() => _selectedPreset = null);
                  _update(_settings.copyWith(clearPresetId: true));
                } else {
                  final chosen = _presets.firstWhere((p) => p.id == id);
                  _applyPreset(chosen);
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.bookmark_add_outlined, size: 16),
              label: const Text('Save as preset'),
              onPressed: _showSavePresetDialog,
            ),
            if (_selectedPreset != null && !_selectedPreset!.isBuiltIn) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Delete preset'),
                onPressed: () async {
                  final confirm = await _showConfirmDialog(
                    title: 'Delete preset?',
                    message: 'Are you sure you want to delete "${_selectedPreset!.name}"?',
                  );
                  if (confirm == true) {
                    await AppServices.presetRepository.deleteCustomPreset(_selectedPreset!.id);
                    await _loadCapabilitiesAndPresets();
                    setState(() => _selectedPreset = null);
                    _update(_settings.copyWith(clearPresetId: true));
                  }
                },
              ),
            ],
          ],
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // 4. Encoding Codec (Unified H.264/AVC & H.265/HEVC)
  // -------------------------------------------------------------------------
  Widget _buildCodecSection(ThemeData theme) {
    final caps = _caps;
    final av1Available = caps == null || caps.av1Software;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('3. Video Codec',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        SegmentedButton<VideoCodecOption>(
          segments: [
            const ButtonSegment(
              value: VideoCodecOption.h264,
              label: Text('H.264 / AVC'),
            ),
            const ButtonSegment(
              value: VideoCodecOption.hevc,
              label: Text('H.265 / HEVC'),
            ),
            ButtonSegment(
              value: VideoCodecOption.av1,
              label: const Text('AV1'),
              enabled: av1Available,
            ),
          ],
          selected: {_settings.videoCodec},
          onSelectionChanged: (selected) {
            _update(_settings.copyWith(
              videoCodec: selected.first,
              clearPresetId: true,
            ));
          },
        ),
        const SizedBox(height: 4),
        Text(
          switch (_settings.videoCodec) {
            VideoCodecOption.h264 =>
              'Universal compatibility — plays smoothly on virtually all browsers, TVs, and devices.',
            VideoCodecOption.hevc =>
              'High compression efficiency — roughly 30-40% smaller than H.264 at identical visual quality.',
            VideoCodecOption.av1 =>
              'Next-gen royalty-free codec with highest compression. Slower encoding on mobile.',
            _ => '',
          },
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // 5. Target Size & Compression Strength
  // -------------------------------------------------------------------------
  Widget _buildTargetSizeSection(ThemeData theme, MediaInfo media) {
    final originalBytes = media.sizeBytes;
    final currentTargetBytes = _settings.targetSizeBytes;
    final currentPercentage = currentTargetBytes != null && originalBytes > 0
        ? (currentTargetBytes / originalBytes * 100.0).clamp(10.0, 100.0)
        : 80.0;

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('4. Target File Size',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                if (currentTargetBytes != null)
                  TextButton(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: () {
                      _update(_settings.copyWith(
                        clearTargetSize: true,
                        clearBitrate: true,
                      ));
                    },
                    child: const Text('Clear limit', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            const SizedBox(height: 8),

            // Slider: 10% to 100%
            Row(
              children: [
                const Text('10%', style: TextStyle(fontSize: 12)),
                Expanded(
                  child: Slider(
                    value: currentPercentage,
                    min: 10.0,
                    max: 100.0,
                    divisions: 18,
                    label: '${currentPercentage.round()}% (${formatBytes((originalBytes * currentPercentage / 100).round())})',
                    onChanged: (percent) {
                      final targetBytes = (originalBytes * (percent / 100.0)).round();
                      _update(_settings.copyWith(
                        targetSizeBytes: targetBytes,
                        clearBitrate: true,
                        clearPresetId: true,
                      ));
                    },
                  ),
                ),
                const Text('100%', style: TextStyle(fontSize: 12)),
              ],
            ),

            // Direct MB input & display
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _targetSizeTextController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Manual target size',
                      suffixText: 'MB',
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
                    ),
                    onChanged: (val) {
                      final mb = double.tryParse(val.trim());
                      if (mb != null && mb > 0) {
                        final bytes = (mb * 1024 * 1024).round();
                        _update(_settings.copyWith(
                          targetSizeBytes: bytes,
                          clearBitrate: true,
                          clearPresetId: true,
                        ));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    currentTargetBytes != null
                        ? '${formatBytes(currentTargetBytes)} (-${(100 - currentPercentage).toStringAsFixed(0)}%)'
                        : 'No limit',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 6. Output Resolution (Aspect-Ratio Preserved)
  // -------------------------------------------------------------------------
  Widget _buildResolutionSection(ThemeData theme, StreamInfo video) {
    final sourceW = video.width ?? 1920;
    final sourceH = video.height ?? 1080;
    final activeH = _settings.targetHeight;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('5. Output Resolution',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        InputDecorator(
          decoration: const InputDecoration(
            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
            contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int?>(
              value: activeH,
              isExpanded: true,
              items: [
                DropdownMenuItem<int?>(
                  value: null,
                  child: Text('Keep original ($sourceW×$sourceH)'),
                ),
                for (final res in ResolutionPreset.all)
                  DropdownMenuItem<int?>(
                    value: res.standardHeight,
                    child: () {
                      final dims = res.calculateDimensions(sourceW, sourceH);
                      final isSame = dims.$1 >= sourceW && dims.$2 >= sourceH;
                      return Text(
                        isSame
                            ? '${res.name} (Source $sourceW×$sourceH - no upscale)'
                            : '${res.name} (${dims.$1}×${dims.$2})',
                      );
                    }(),
                  ),
              ],
              onChanged: (selectedHeight) {
                if (selectedHeight == null) {
                  _update(_settings.copyWith(
                    clearResolution: true,
                    clearPresetId: true,
                  ));
                } else {
                  final preset = ResolutionPreset.all.firstWhere(
                    (p) => p.standardHeight == selectedHeight,
                  );
                  final dims = preset.calculateDimensions(sourceW, sourceH);
                  _update(_settings.copyWith(
                    targetWidth: dims.$1,
                    targetHeight: dims.$2,
                    clearPresetId: true,
                  ));
                }
              },
            ),
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // 7. Output Frame Rate
  // -------------------------------------------------------------------------
  Widget _buildFrameRateSection(ThemeData theme, StreamInfo video) {
    final sourceFps = video.frameRate ?? 30.0;
    final activeFps = _settings.frameRate;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('6. Output Frame Rate',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        SegmentedButton<double?>(
          segments: [
            ButtonSegment<double?>(
              value: null,
              label: Text('Original (${sourceFps.toStringAsFixed(0)})'),
            ),
            ButtonSegment<double?>(
              value: 30.0,
              label: const Text('30 fps'),
              enabled: sourceFps >= 29.0,
            ),
            ButtonSegment<double?>(
              value: 60.0,
              label: const Text('60 fps'),
              enabled: sourceFps >= 59.0,
            ),
            ButtonSegment<double?>(
              value: 120.0,
              label: const Text('120 fps'),
              enabled: sourceFps >= 119.0,
            ),
          ],
          selected: {activeFps},
          onSelectionChanged: (selected) {
            final fps = selected.first;
            _update(_settings.copyWith(
              frameRate: fps,
              clearFrameRate: fps == null,
              clearPresetId: true,
            ));
          },
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // 8. Audio Settings
  // -------------------------------------------------------------------------
  Widget _buildAudioSection(ThemeData theme, MediaInfo media) {
    final hasAudio = media.audioStream != null;
    if (!hasAudio) {
      return const Text('This video has no audio stream.',
          style: TextStyle(fontStyle: FontStyle.italic));
    }

    final isAudioRemoved = _settings.audio == AudioAction.none;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('7. Audio Settings',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: false,
              label: Text('Keep original audio'),
              icon: Icon(Icons.volume_up),
            ),
            ButtonSegment(
              value: true,
              label: Text('Remove audio'),
              icon: Icon(Icons.volume_off),
            ),
          ],
          selected: {isAudioRemoved},
          onSelectionChanged: (selected) {
            final remove = selected.first;
            _update(_settings.copyWith(
              audio: remove ? AudioAction.none : AudioAction.copySource,
              clearPresetId: true,
            ));
          },
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // 8. HDR & Color Section
  // -------------------------------------------------------------------------
  Widget _buildHdrSection(ThemeData theme, MediaInfo media, StreamInfo video) {
    final scheme = theme.colorScheme;
    final isSourceHdr = video.isHdr;
    final activeMode = _settings.hdrMode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.hdr_on, color: scheme.primary, size: 20),
                const SizedBox(width: 8),
                Text('8. HDR & Color',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: isSourceHdr
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                isSourceHdr ? 'Source: HDR' : 'Source: SDR',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: isSourceHdr
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SegmentedButton<HdrMode>(
          segments: const [
            ButtonSegment(
              value: HdrMode.off,
              label: Text('Off'),
            ),
            ButtonSegment(
              value: HdrMode.hdrEffect,
              label: Text('Effect'),
            ),
            ButtonSegment(
              value: HdrMode.sdrToHdr,
              label: Text('SDR→HDR'),
            ),
            ButtonSegment(
              value: HdrMode.preserveHdr,
              label: Text('Preserve'),
            ),
          ],
          selected: {activeMode},
          onSelectionChanged: (selected) {
            final mode = selected.first;
            _update(_settings.copyWith(
              hdrMode: mode,
              clearPresetId: true,
            ));
          },
        ),
        const SizedBox(height: 8),
        Card(
          elevation: 0,
          color: scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  switch (activeMode) {
                    HdrMode.off =>
                      'Preserves original SDR/HDR colors without enhancement or tone-mapping filters.',
                    HdrMode.hdrEffect =>
                      'Visual simulation of expanded dynamic range, contrast, and highlight detail. Works on standard SDR screens.',
                    HdrMode.sdrToHdr =>
                      'Converts 8-bit SDR into genuine 10-bit HDR10 (BT.2020 PQ color space and mastering metadata). Best on HDR screens.',
                    HdrMode.preserveHdr => isSourceHdr
                        ? 'Retains source 10-bit HDR primaries (BT.2020), transfer curve, and metadata without 8-bit downconversion.'
                        : 'Source video is SDR. Original SDR colors will be preserved without modification.',
                  },
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                if (activeMode == HdrMode.hdrEffect) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text(
                        'Effect Intensity: ${(_settings.hdrIntensity * 100).round()}%',
                        style: theme.textTheme.labelMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      Text(
                        _settings.hdrIntensity < 0.35
                            ? 'Subtle'
                            : _settings.hdrIntensity > 0.75
                                ? 'Vivid'
                                : 'Balanced',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.primary),
                      ),
                    ],
                  ),
                  Slider(
                    value: _settings.hdrIntensity,
                    min: 0.1,
                    max: 1.0,
                    divisions: 18,
                    label: '${(_settings.hdrIntensity * 100).round()}%',
                    onChanged: (v) {
                      _update(_settings.copyWith(
                        hdrIntensity: v,
                        clearPresetId: true,
                      ));
                    },
                  ),
                ],
                if (activeMode == HdrMode.sdrToHdr &&
                    _settings.videoCodec != VideoCodecOption.hevc) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, size: 18, color: scheme.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'SDR to HDR conversion requires HEVC (H.265) 10-bit encoding.',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: scheme.onErrorContainer),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            _update(_settings.copyWith(
                              videoCodec: VideoCodecOption.hevc,
                              clearPresetId: true,
                            ));
                          },
                          child: const Text('Use HEVC'),
                        ),
                      ],
                    ),
                  ),
                ],
                if (activeMode == HdrMode.preserveHdr &&
                    isSourceHdr &&
                    _settings.videoCodec == VideoCodecOption.h264) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, size: 18, color: scheme.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'H.264 is 8-bit and will downconvert 10-bit HDR to SDR. Switch to HEVC to preserve 10-bit HDR.',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: scheme.onErrorContainer),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            _update(_settings.copyWith(
                              videoCodec: VideoCodecOption.hevc,
                              clearPresetId: true,
                            ));
                          },
                          child: const Text('Use HEVC'),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Advanced Settings Collapsible
  // -------------------------------------------------------------------------
  Widget _buildAdvancedSettingsSection(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ExpansionTile(
        initiallyExpanded: _showAdvancedSettings,
        onExpansionChanged: (exp) => setState(() => _showAdvancedSettings = exp),
        title: const Text('Advanced Settings',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        subtitle: const Text('Container format, hardware acceleration, metadata',
            style: TextStyle(fontSize: 12)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          _buildContainerSection(theme),
          const SizedBox(height: 12),
          _buildHardwareSection(theme),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Keep metadata'),
            subtitle: const Text('Title, creation date, rotation and color tags'),
            value: _settings.keepMetadata,
            onChanged: (v) => _update(_settings.copyWith(keepMetadata: v)),
          ),
        ],
      ),
    );
  }

  Widget _buildContainerSection(ThemeData theme) {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Output container format',
        border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        isDense: true,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<ContainerOption>(
          value: _settings.container,
          isExpanded: true,
          items: const [
            DropdownMenuItem(value: ContainerOption.mp4, child: Text('MP4 (highest compatibility)')),
            DropdownMenuItem(value: ContainerOption.mkv, child: Text('MKV (preserves all streams)')),
          ],
          onChanged: (v) => _update(_settings.copyWith(container: v!)),
        ),
      ),
    );
  }

  Widget _buildHardwareSection(ThemeData theme) {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Hardware encoder acceleration',
        border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        isDense: true,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<HardwarePreference>(
          value: _settings.hardware,
          isExpanded: true,
          items: const [
            DropdownMenuItem(
              value: HardwarePreference.auto,
              child: Text('Automatic (hardware if available)'),
            ),
            DropdownMenuItem(
              value: HardwarePreference.hardware,
              child: Text('Force hardware acceleration (faster)'),
            ),
            DropdownMenuItem(
              value: HardwarePreference.software,
              child: Text('Force software encoding (best quality)'),
            ),
          ],
          onChanged: (v) => _update(_settings.copyWith(hardware: v!)),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 9. Estimated Output Information Card
  // -------------------------------------------------------------------------
  Widget _buildEstimateSection(
      ThemeData theme, MediaInfo media, StreamInfo video) {
    final scheme = theme.colorScheme;
    final w = _settings.targetWidth ?? video.width ?? 1280;
    final h = _settings.targetHeight ?? video.height ?? 720;
    final fps = _settings.frameRate ?? video.frameRate ?? 30.0;

    String estimatedSizeStr;
    int estimatedBytes = 0;
    int kbps = 0;

    if (_settings.mode == CompressionMode.exactLossless) {
      estimatedBytes = media.sizeBytes;
      estimatedSizeStr =
          '~${formatBytes(media.sizeBytes)} (exact lossless stream copy)';
    } else {
      kbps = JobPlanner.resolveVideoBitrateKbps(
        settings: _settings,
        media: media,
        targetWidth: w,
        targetHeight: h,
        fps: fps,
      );
      estimatedBytes = BitrateCalculator.estimateOutputBytes(
        videoBitrateKbps: kbps,
        durationSeconds: media.durationSeconds,
        audioAction: _settings.audio,
        sourceAudioBitrate: media.audioStream?.bitRate,
        hasAudio: media.audioStream != null,
        hdrMode: _settings.hdrMode,
      );
      estimatedSizeStr = '~${formatBytes(estimatedBytes)}';
    }

    final savingsPercent = SizeStats.percentSaved(media.sizeBytes, estimatedBytes);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.analytics_outlined,
                  size: 20, color: scheme.onSecondaryContainer),
              const SizedBox(width: 8),
              Text(
                'Estimated Output',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Estimated size:',
                  style: TextStyle(fontSize: 13, color: scheme.onSecondaryContainer)),
              Text(
                '$estimatedSizeStr (${formatPercent(savingsPercent)})',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ],
          ),
          if (kbps > 0) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Target video bitrate:',
                    style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer)),
                Text('$kbps kbps',
                    style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer)),
              ],
            ),
          ],
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Effective resolution:',
                  style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer)),
              Text('$w×$h @ ${fps.toStringAsFixed(1)} fps',
                  style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Color / Dynamic range:',
                  style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer)),
              Text(
                switch (_settings.hdrMode) {
                  HdrMode.off => video.isHdr ? 'Preserve HDR' : 'Standard SDR',
                  HdrMode.hdrEffect =>
                    'HDR Effect (${(_settings.hdrIntensity * 100).round()}%)',
                  HdrMode.sdrToHdr => 'HDR10 (10-bit BT.2020)',
                  HdrMode.preserveHdr =>
                    video.isHdr ? 'HDR10 preserved' : 'Standard SDR',
                },
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Lossless Controls (Exact Stream Copy)
  // -------------------------------------------------------------------------
  Widget _buildLosslessBanner(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.verified, color: theme.colorScheme.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Exact Lossless Mode active: Preserves 100% bit-exact streams via stream copy (-c copy). No resolution, frame-rate, or quality loss occurs.',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

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
        x264Reason = 'libx264 is not in this app build.';
      } else if (!const {'yuv420p', 'yuv422p', 'yuv444p'}.contains(pixFmt)) {
        x264Reason = 'Pixel format $pixFmt cannot be preserved by libx264.';
      }
      if (caps != null && !caps.hevcSoftware) {
        x265Reason = 'libx265 is not in this app build.';
      } else if (pixFmt != 'yuv420p') {
        x265Reason =
            'libx265 preserves 8-bit $pixFmt sources losslessly for yuv420p only.';
      }
      if (caps != null && !caps.av1Software) {
        av1Reason = 'No AV1 encoder (libaom-av1) in this app build.';
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
                'Stream copy (fastest, bit-exact remux)', null),
            tile(LosslessEncoder.x264, 'H.264 lossless (libx264 CRF 0)',
                x264Reason),
            tile(LosslessEncoder.x265, 'HEVC lossless (libx265 lossless=1)',
                x265Reason),
            tile(LosslessEncoder.av1, 'AV1 lossless (libaom-av1 lossless=1)',
                av1Reason),
          ],
        ),
      ),
    ];
  }

  // -------------------------------------------------------------------------
  // Dialogs
  // -------------------------------------------------------------------------
  Future<void> _showSavePresetDialog() async {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save as Custom Preset'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Preset name',
                hintText: 'e.g. My Fast Share',
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descCtrl,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                hintText: 'e.g. 720p 30fps small size',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (saved == true && nameCtrl.text.trim().isNotEmpty) {
      final newPreset = CompressionPreset(
        id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
        name: nameCtrl.text.trim(),
        description: descCtrl.text.trim(),
        targetSizeBytes: _settings.targetSizeBytes,
        profile: _settings.profile,
        videoCodec: _settings.videoCodec,
        targetWidth: _settings.targetWidth,
        targetHeight: _settings.targetHeight,
        frameRate: _settings.frameRate,
        audio: _settings.audio,
        container: _settings.container,
        crf: _settings.crf,
        speedPreset: _settings.speedPreset,
        quality: _settings.quality,
        hdrMode: _settings.hdrMode,
        hdrIntensity: _settings.hdrIntensity,
        isBuiltIn: false,
      );

      await AppServices.presetRepository.saveCustomPreset(newPreset);
      await _loadCapabilitiesAndPresets();
      setState(() => _selectedPreset = newPreset);
      _update(_settings.copyWith(presetId: newPreset.id));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Preset "${newPreset.name}" saved')),
        );
      }
    }
  }

  Future<bool?> _showConfirmDialog({
    required String title,
    required String message,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }
}

class _InfoBadge extends StatelessWidget {
  const _InfoBadge({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: scheme.primary),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
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
