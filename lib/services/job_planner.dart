import '../models/models.dart';
import 'bitrate_calculator.dart';
import 'settings_validator.dart';

/// Builds validated ffmpeg argument lists for every mode. Pure Dart, no
/// plugin imports — fully unit-tested. Arguments are always passed to the
/// engine as an explicit list (no shell strings, no user-supplied commands).
class JobPlanner {
  JobPlanner._();

  /// Bits-per-pixel-per-second factors for the quality presets. Calibrated so
  /// 1080p30 lands around 7.5 / 5 / 2.8 Mbps.
  static const Map<QualityPreset, double> _bitrateFactor = {
    QualityPreset.highQuality: 0.12,
    QualityPreset.balanced: 0.08,
    QualityPreset.smaller: 0.045,
  };

  /// x264/x265 `-preset` names per speed preset.
  static const Map<SpeedPreset, String> _swPresetName = {
    SpeedPreset.veryfast: 'veryfast',
    SpeedPreset.fast: 'fast',
    SpeedPreset.medium: 'medium',
    SpeedPreset.slow: 'slow',
    SpeedPreset.veryslow: 'veryslow',
  };

  /// libaom `-cpu-used` (0 = slowest/best, 9 = fastest) per speed preset.
  static const Map<SpeedPreset, int> _aomCpuUsed = {
    SpeedPreset.veryfast: 9,
    SpeedPreset.fast: 7,
    SpeedPreset.medium: 5,
    SpeedPreset.slow: 3,
    SpeedPreset.veryslow: 1,
  };

  static const Map<AudioAction, List<String>> _audioEncodeArgs = {
    AudioAction.aac128: ['-c:a', 'aac', '-b:a', '128k'],
    AudioAction.aac96: ['-c:a', 'aac', '-b:a', '96k'],
    AudioAction.aac64: ['-c:a', 'aac', '-b:a', '64k'],
    AudioAction.opus96: ['-c:a', 'libopus', '-b:a', '96k'],
    AudioAction.none: ['-an'],
  };

  /// Plans the full pipeline for [settings] against a probed [media].
  /// Throws [ArgumentError] if settings are invalid for this media — callers
  /// must run [SettingsValidator] first.
  static CompressionPlan plan({
    required CompressionSettings settings,
    required MediaInfo media,
    required FfmpegCapabilitiesLike caps,
    required String sourcePath,
    required String outputPath,
  }) {
    final video = media.videoStream;
    if (video == null) {
      throw ArgumentError('No video stream');
    }

    final losslessRemux = settings.mode == CompressionMode.exactLossless &&
        settings.losslessEncoder == LosslessEncoder.copy;
    final losslessReencode = settings.mode == CompressionMode.exactLossless &&
        settings.losslessEncoder != LosslessEncoder.copy;

    if (losslessRemux) {
      return _planRemux(settings, media, sourcePath, outputPath,
          lossless: true, label: 'Stream copy (remux)');
    }
    if (losslessReencode) {
      return _planLosslessReencode(settings, media, caps, sourcePath, outputPath);
    }
    if (settings.mode == CompressionMode.custom &&
        settings.videoCodec == VideoCodecOption.copySource) {
      return _planRemux(settings, media, sourcePath, outputPath,
          lossless: false, label: 'Stream copy (custom)');
    }
    return _planEncode(settings, media, caps, sourcePath, outputPath);
  }

  // Convenience used by tests and the controller: append the output path to
  // a planned stage's args.
  static List<String> stageWithOutput(List<String> args, String outputPath) =>
      [...args, outputPath];

  // ---------------------------------------------------------------- remux ---
  static CompressionPlan _planRemux(
    CompressionSettings settings,
    MediaInfo media,
    String sourcePath,
    String outputPath, {
    required bool lossless,
    required String label,
  }) {
    final args = <String>[
      '-y',
      '-i', sourcePath,
      '-map', '0:v?',
      '-map', '0:a?',
    ];
    final keepSubs =
        settings.container == ContainerOption.mkv && media.subtitleStreams.isNotEmpty;
    if (keepSubs) args.addAll(const ['-map', '0:s?']);
    args.addAll(const ['-c', 'copy']);
    if (settings.container == ContainerOption.mp4) {
      if (media.subtitleStreams.isNotEmpty) {
        // Only text subtitles can be converted into MP4.
        args.addAll(const ['-c:s', 'mov_text']);
      }
      args.addAll(const ['-movflags', '+faststart']);
    }
    args.addAll(['-map_metadata', settings.keepMetadata ? '0' : '-1']);
    args.add(outputPath);

    return CompressionPlan(
      stages: [args],
      description: lossless
          ? 'Bit-exact stream copy — no re-encoding, timestamps and rotation preserved.'
          : 'Stream copy without re-encoding (custom mode).',
      isLossless: lossless,
      expectedVerification: lossless
          ? VerificationExpectation.decodedEquality
          : VerificationExpectation.none,
    );
  }

  // -------------------------------------------- lossless re-encode (all) ---
  /// Verified lossless encoder configurations (8-bit sources only):
  /// - x264:  `-c:v libx264 -crf 0`   (CRF 0 == mathematically lossless)
  /// - x265:  `-c:v libx265 -x265-params lossless=1`
  /// - aom:   `-c:v libaom-av1 -lossless 1` (AV1 qindex-0 lossless mode)
  /// The pixel format is pinned to the source so no color conversion can
  /// alter decoded samples. Losslessness is still only *claimed* after the
  /// framemd5 decoded-frame comparison succeeds.
  static CompressionPlan _planLosslessReencode(
    CompressionSettings settings,
    MediaInfo media,
    FfmpegCapabilitiesLike caps,
    String sourcePath,
    String outputPath,
  ) {
    final video = media.videoStream!;
    final pixFmt = video.pixFmt ?? 'yuv420p';
    final preset = _swPresetName[settings.speedPreset] ?? 'medium';

    final (encoderName, codecArgs, label) = switch (settings.losslessEncoder) {
      LosslessEncoder.x264 => (
          'libx264',
          ['-c:v', 'libx264', '-preset', preset, '-crf', '0'],
          'H.264 lossless (CRF 0)'
        ),
      LosslessEncoder.x265 => (
          'libx265',
          ['-c:v', 'libx265', '-preset', preset, '-x265-params', 'lossless=1'],
          'HEVC lossless'
        ),
      LosslessEncoder.av1 => (
          'libaom-av1',
          [
            '-c:v', 'libaom-av1', '-lossless', '1', '-b:v', '0',
            '-cpu-used', '${_aomCpuUsed[settings.speedPreset] ?? 5}',
          ],
          'AV1 lossless'
        ),
      LosslessEncoder.copy => throw ArgumentError('handled by remux'),
    };
    if (!caps.supportsEncoder(encoderName)) {
      throw ArgumentError('$encoderName is not available in this app build');
    }

    final args = <String>[
      '-y',
      '-i', sourcePath,
      '-map', '0:v?',
      '-map', '0:a?',
      ...codecArgs,
      '-pix_fmt', pixFmt, // pin format: no color conversion allowed
    ];
    _applyAudio(settings, media, args, losslessFallbackCodec: 'flac');
    if (settings.container == ContainerOption.mp4) {
      args.addAll(const ['-movflags', '+faststart']);
    }
    args.addAll(settings.keepMetadata
        ? const ['-map_metadata', '0']
        : const ['-map_metadata', '-1']);
    args.add(outputPath);

    return CompressionPlan(
      stages: [args],
      description:
          '$label re-encode. Decoded frames must match the source exactly '
          '(verified after encoding); the file itself is a different encoding, '
          'not a bit-identical copy. Output can be larger than the original.',
      isLossless: true,
      expectedVerification: VerificationExpectation.decodedEqualityReencode,
    );
  }

  // ----------------------------------------------------------- lossy encode ---
  static CompressionPlan _planEncode(
    CompressionSettings settings,
    MediaInfo media,
    FfmpegCapabilitiesLike caps,
    String sourcePath,
    String outputPath,
  ) {
    final video = media.videoStream!;
    final width = settings.targetWidth ?? video.width ?? 1280;
    final height = settings.targetHeight ?? video.height ?? 720;
    final fps = settings.frameRate ?? video.frameRate ?? 30.0;
    final codec = settings.videoCodec;
    final hasTargetSize = settings.targetSizeBytes != null;
    final useCrf = !hasTargetSize && settings.crf != null;

    // CRF is a software-encoder feature; MediaCodec has no CRF mode, so a
    // CRF request always selects the software encoder.
    final useHardware = !useCrf && _chooseHardware(settings, caps);
    final swEncoder = _softwareEncoderName(codec, caps);
    int? kbps; // bitrate target (hardware / custom bitrate paths only)

    final args = <String>[
      '-y',
      '-i', sourcePath,
      '-map', '0:v?',
      '-map', '0:a?',
    ];

    // Determine target pixel format and color parameters based on HDR mode
    final is10BitTarget = (settings.hdrMode == HdrMode.sdrToHdr) ||
        (settings.hdrMode == HdrMode.preserveHdr &&
            video.isHdr &&
            video.bitDepth >= 10 &&
            codec == VideoCodecOption.hevc) ||
        (settings.hdrMode == HdrMode.off &&
            video.isHdr &&
            video.bitDepth >= 10 &&
            codec == VideoCodecOption.hevc);

    final outPixFmt = is10BitTarget ? 'yuv420p10le' : 'yuv420p';
    final colorArgs = <String>[];

    if (settings.hdrMode == HdrMode.sdrToHdr) {
      colorArgs.addAll([
        '-pix_fmt', outPixFmt,
        '-color_primaries', 'bt2020',
        '-color_trc', 'smpte2084',
        '-colorspace', 'bt2020nc',
        '-color_range', 'tv',
      ]);
      if (!useHardware && swEncoder == 'libx265') {
        colorArgs.addAll([
          '-x265-params',
          'hdr10-opt=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400',
        ]);
      }
    } else if ((settings.hdrMode == HdrMode.preserveHdr ||
            settings.hdrMode == HdrMode.off) &&
        video.isHdr) {
      colorArgs.addAll(['-pix_fmt', outPixFmt]);
      if (video.colorPrimaries != null && video.colorPrimaries!.isNotEmpty) {
        colorArgs.addAll(['-color_primaries', video.colorPrimaries!]);
      }
      if (video.colorTransfer != null && video.colorTransfer!.isNotEmpty) {
        colorArgs.addAll(['-color_trc', video.colorTransfer!]);
      }
      if (video.colorSpace != null && video.colorSpace!.isNotEmpty) {
        colorArgs.addAll(['-colorspace', video.colorSpace!]);
      }
      if (video.colorRange != null && video.colorRange!.isNotEmpty) {
        colorArgs.addAll(['-color_range', video.colorRange!]);
      }
      if (!useHardware && swEncoder == 'libx265') {
        final prim = video.colorPrimaries ?? 'bt2020';
        final trc = video.colorTransfer ?? 'smpte2084';
        final matrix = video.colorSpace ?? 'bt2020nc';
        colorArgs.addAll([
          '-x265-params',
          'hdr10-opt=1:repeat-headers=1:colorprim=$prim:transfer=$trc:colormatrix=$matrix',
        ]);
      }
    } else {
      colorArgs.addAll(['-pix_fmt', 'yuv420p']);
    }

    if (useHardware) {
      kbps = resolveVideoBitrateKbps(
        settings: settings,
        media: media,
        targetWidth: width,
        targetHeight: height,
        fps: fps,
      );
      final hwName =
          codec == VideoCodecOption.hevc ? 'hevc_mediacodec' : 'h264_mediacodec';
      args.addAll(['-c:v', hwName, '-b:v', '${kbps}k',
        '-maxrate', '${(kbps * 1.5).round()}k', '-bufsize', '${kbps * 2}k']);
      args.addAll(colorArgs);
    } else if (useCrf) {
      // Software CRF rate control (modes A/C/E/G).
      args.addAll(['-c:v', swEncoder]);
      if (swEncoder == 'libaom-av1') {
        // libaom needs -b:v 0 to activate constant-quality (CRF) mode and
        // uses -cpu-used (0 best … 9 fastest) instead of -preset.
        args.addAll(['-crf', '${settings.crf}', '-b:v', '0',
          '-cpu-used', '${_aomCpuUsed[settings.speedPreset] ?? 5}']);
      } else {
        final preset = _swPresetName[settings.speedPreset] ?? 'medium';
        args.addAll(['-preset', preset, '-crf', '${settings.crf}']);
      }
      args.addAll(colorArgs);
    } else {
      kbps = resolveVideoBitrateKbps(
        settings: settings,
        media: media,
        targetWidth: width,
        targetHeight: height,
        fps: fps,
      );
      if (swEncoder == 'libaom-av1') {
        args.addAll(['-c:v', swEncoder, '-b:v', '${kbps}k',
          '-cpu-used', '${_aomCpuUsed[settings.speedPreset] ?? 5}']);
      } else {
        args.addAll(['-c:v', swEncoder, '-b:v', '${kbps}k',
          '-maxrate', '${(kbps * 1.5).round()}k', '-bufsize', '${kbps * 2}k',
          '-preset', _swPresetName[settings.speedPreset] ?? 'medium']);
      }
      args.addAll(colorArgs);
    }

    // Explicit changes only — resolution/fps preserved unless the user asked.
    final filters = <String>[];
    if (settings.targetWidth != null || settings.targetHeight != null) {
      final evenW = width - (width % 2);
      final evenH = height - (height % 2);
      filters.add('scale=$evenW:$evenH');
    }
    if (settings.frameRate != null) {
      filters.add('fps=${settings.frameRate}');
    }
    if (settings.hdrMode == HdrMode.hdrEffect) {
      final intensity = settings.hdrIntensity.clamp(0.1, 1.0);
      final c = (1.0 + 0.16 * intensity).toStringAsFixed(2);
      final b = (0.015 * intensity).toStringAsFixed(3);
      final s = (1.0 + 0.15 * intensity).toStringAsFixed(2);
      final g = (1.0 + 0.05 * intensity).toStringAsFixed(2);
      final u = (0.50 * intensity).toStringAsFixed(2);
      filters.add('eq=contrast=$c:brightness=$b:saturation=$s:gamma=$g');
      filters.add('unsharp=3:3:$u:3:3:0.0');
    }
    if (filters.isNotEmpty) args.addAll(['-vf', filters.join(',')]);

    _applyAudio(settings, media, args, losslessFallbackCodec: 'aac');
    if (settings.container == ContainerOption.mp4) {
      args.addAll(const ['-movflags', '+faststart']);
    }
    args.addAll(settings.keepMetadata
        ? const ['-map_metadata', '0']
        : const ['-map_metadata', '-1']);
    args.add(outputPath);

    final codecLabel = switch (codec) {
      VideoCodecOption.hevc => useHardware ? 'HEVC (hardware)' : 'HEVC (software)',
      VideoCodecOption.av1 => 'AV1 (libaom)',
      _ => useHardware ? 'H.264 (hardware)' : 'H.264 (software)',
    };
    final rateLabel = useCrf ? 'CRF ${settings.crf}' : null;
    final hdrTag = switch (settings.hdrMode) {
      HdrMode.hdrEffect => ' with HDR Effect (${(settings.hdrIntensity * 100).round()}%)',
      HdrMode.sdrToHdr => ' [HDR10 10-bit conversion]',
      HdrMode.preserveHdr => video.isHdr ? ' [HDR preserved]' : '',
      HdrMode.off => '',
    };

    final description = hasTargetSize
        ? 'Target size encode — $codecLabel at ~${kbps ?? 0} kbps for '
            '${(settings.targetSizeBytes! / (1024 * 1024)).toStringAsFixed(1)} MB target$hdrTag.'
        : useCrf
            ? 'Lossy re-encode — $codecLabel at $rateLabel, ${settings.speedPreset.label} speed$hdrTag. '
                'Lower CRF = better quality and a larger file. Not lossless.'
            : 'Lossy re-encode — $codecLabel, ~${kbps ?? 0} kbps, ${settings.quality.label}$hdrTag. '
                'Quality is high but this is not mathematically lossless.';

    return CompressionPlan(
      stages: [args],
      description: description,
      isLossless: false,
      expectedVerification: VerificationExpectation.none,
    );
  }

  /// Resolves the target video bitrate in kbps for [settings] and [media].
  static int resolveVideoBitrateKbps({
    required CompressionSettings settings,
    required MediaInfo media,
    int? targetWidth,
    int? targetHeight,
    double? fps,
  }) {
    if (settings.targetBitrateKbps != null) {
      return settings.targetBitrateKbps!;
    }
    if (settings.targetSizeBytes != null) {
      return BitrateCalculator.calculateVideoBitrateKbps(
        targetSizeBytes: settings.targetSizeBytes!,
        durationSeconds: media.durationSeconds,
        audioAction: settings.audio,
        sourceAudioBitrate: media.audioStream?.bitRate,
        hasAudio: media.audioStream != null,
        hdrMode: settings.hdrMode,
      );
    }
    final video = media.videoStream;
    final w = targetWidth ?? settings.targetWidth ?? video?.width ?? 1280;
    final h = targetHeight ?? settings.targetHeight ?? video?.height ?? 720;
    final f = fps ?? settings.frameRate ?? video?.frameRate ?? 30.0;
    return _estimatedBitrateKbps(w, h, f, settings.quality,
        sourceVideoBitrate: video?.bitRate, hdrMode: settings.hdrMode);
  }

  /// Software encoder name actually present in the packaged build for
  /// [codec]. AV1 ships as libaom-av1 in this app's FFmpeg (libsvtav1 is
  /// NOT included); libsvtav1 is only used if a build provides it without
  /// libaom.
  static String _softwareEncoderName(
      VideoCodecOption codec, FfmpegCapabilitiesLike caps) {
    return switch (codec) {
      VideoCodecOption.hevc => 'libx265',
      VideoCodecOption.av1 =>
        (caps.av1Libaom || !caps.av1SvtAv1) ? 'libaom-av1' : 'libsvtav1',
      _ => 'libx264',
    };
  }

  /// Public alias used by the configuration screen for size estimates.
  static int debugEstimatedBitrateKbps(
    int w,
    int h,
    double fps,
    QualityPreset quality, {
    int? sourceVideoBitrate,
    HdrMode hdrMode = HdrMode.off,
  }) =>
      _estimatedBitrateKbps(w, h, fps, quality,
          sourceVideoBitrate: sourceVideoBitrate, hdrMode: hdrMode);

  /// Estimated target bitrate (kbps) for [w]x[h]@fps. Capped below the source
  /// bitrate to avoid "compression" that increases size.
  static int _estimatedBitrateKbps(
    int w,
    int h,
    double fps,
    QualityPreset quality, {
    int? sourceVideoBitrate,
    HdrMode hdrMode = HdrMode.off,
  }) {
    final baseFactor = _bitrateFactor[quality] ?? 0.008;
    final factor = (hdrMode == HdrMode.sdrToHdr || hdrMode == HdrMode.preserveHdr)
        ? baseFactor * 1.12
        : baseFactor;
    var kbps = (w * h * fps * factor / 1000).round();
    if (sourceVideoBitrate != null && sourceVideoBitrate > 0) {
      final cap = (sourceVideoBitrate / 1000 * 0.85).round();
      if (kbps > cap) kbps = cap;
    }
    final floor = (hdrMode == HdrMode.sdrToHdr || hdrMode == HdrMode.preserveHdr) ? 250 : 200;
    if (kbps < floor) kbps = floor;
    return kbps;
  }

  static bool _chooseHardware(
      CompressionSettings settings, FfmpegCapabilitiesLike caps) {
    final codec = settings.videoCodec;
    final hwAvailable = switch (codec) {
      VideoCodecOption.hevc => caps.hevcHardware,
      VideoCodecOption.h264 => caps.h264Hardware,
      _ => false,
    };
    final swAvailable = switch (codec) {
      VideoCodecOption.hevc => caps.hevcSoftware,
      VideoCodecOption.h264 => caps.h264Software,
      _ => caps.av1Software,
    };
    return switch (settings.hardware) {
      HardwarePreference.hardware => hwAvailable,
      HardwarePreference.software => false,
      HardwarePreference.auto => hwAvailable || !swAvailable ? hwAvailable : false,
    };
  }

  static void _applyAudio(
    CompressionSettings settings,
    MediaInfo media,
    List<String> args, {
    required String losslessFallbackCodec,
  }) {
    final audio = media.audioStream;
    if (audio == null) {
      args.add('-an');
      return;
    }
    if (settings.audio == AudioAction.none) {
      args.addAll(const ['-an']);
      return;
    }
    if (settings.audio == AudioAction.copySource) {
      if (SettingsValidator.audioCodecFitsContainer(
          audio.codecName, settings.container)) {
        args.addAll(const ['-c:a', 'copy']);
      } else {
        // Incompatible copy → convert. Lossless modes must not silently go lossy.
        final lossless = settings.mode == CompressionMode.exactLossless;
        if (lossless && settings.container == ContainerOption.mkv) {
          args.addAll(const ['-c:a', 'flac']);
        } else if (lossless) {
          throw ArgumentError(
              'Audio ${audio.codecName} cannot be copied to ${settings.container.name} — '
              'choose MKV or an explicit audio option to avoid lossy conversion.');
        } else {
          args.addAll(const ['-c:a', 'aac', '-b:a', '128k']);
        }
      }
      return;
    }
    args.addAll(_audioEncodeArgs[settings.audio] ?? const ['-c:a', 'aac', '-b:a', '128k']);
  }

  /// Output file name for a job: sanitized base + suffix + extension.
  static String outputName(String sourceName, CompressionSettings settings,
      {String jobId = ''}) {
    final dot = sourceName.lastIndexOf('.');
    var base = dot > 0 ? sourceName.substring(0, dot) : sourceName;
    base = base.replaceAll(RegExp(r'[^\w\-. ]'), '_');
    base = base.replaceAll(RegExp(r'^[_\s]+|[_\s]+$'), '').trim();
    if (base.isEmpty) base = 'video';
    final suffix = switch (settings.mode) {
      CompressionMode.exactLossless => switch (settings.losslessEncoder) {
          LosslessEncoder.copy => 'remux',
          LosslessEncoder.x264 => 'lossless',
          LosslessEncoder.x265 => 'hevc_lossless',
          LosslessEncoder.av1 => 'av1_lossless',
        },
      CompressionMode.highEfficiency => 'compressed',
      CompressionMode.custom => 'custom',
    };
    final ext = settings.container == ContainerOption.mkv ? 'mkv' : 'mp4';
    final tag = jobId.isEmpty ? '' : '_$jobId';
    return '${base}_$suffix$tag.$ext';
  }
}
