import '../models/models.dart';

/// Validates user settings against the actual source media before any work
/// starts. Pure Dart — unit-tested.
class SettingsValidator {
  SettingsValidator._();

  /// Codec/container compatibility matrix for stream copy.
  static const Map<ContainerOption, Set<String>> _copyableVideo = {
    // Deliberately strict: only codecs with dependable player support in MP4.
    ContainerOption.mp4: {'h264', 'hevc', 'av1', 'mpeg4'},
    ContainerOption.mkv: {
      'h264', 'hevc', 'av1', 'mpeg4', 'mpeg2video', 'vp9', 'vp8',
      'theora', 'ffv1', 'rawvideo',
    },
  };

  static const Map<ContainerOption, Set<String>> _copyableAudio = {
    ContainerOption.mp4: {'aac', 'mp3', 'ac3', 'eac3', 'alac'},
    ContainerOption.mkv: {
      'aac', 'mp3', 'ac3', 'eac3', 'flac', 'opus', 'vorbis', 'pcm_s16le',
      'pcm_s24le', 'alac',
    },
  };
  static bool videoCodecFitsContainer(String codec, ContainerOption c) =>
      _copyableVideo[c]?.contains(codec) ?? false;

  static bool audioCodecFitsContainer(String codec, ContainerOption c) =>
      _copyableAudio[c]?.contains(codec) ?? false;

  /// Full pre-flight validation. Returns blocking errors and soft warnings.
  static ValidationResult validate(
    CompressionSettings settings,
    MediaInfo media, {
    FfmpegCapabilitiesLike? caps,
  }) {
    final errors = <ValidationIssue>[];
    final warnings = <ValidationIssue>[];

    final video = media.videoStream;
    if (video == null) {
      errors.add(const ValidationIssue('This file has no video stream to compress.'));
      return ValidationResult(errors, warnings);
    }

    // ---------- Exact Lossless ----------
    if (settings.mode == CompressionMode.exactLossless) {
      if (settings.hdrMode == HdrMode.sdrToHdr ||
          settings.hdrMode == HdrMode.hdrEffect) {
        errors.add(const ValidationIssue(
            'Exact Lossless mode cannot apply HDR conversions or visual effects. '
            'Switch to High Efficiency or Custom mode.'));
      }
      if (settings.targetWidth != null ||
          settings.targetHeight != null ||
          settings.targetBitrateKbps != null ||
          settings.targetSizeBytes != null ||
          settings.frameRate != null) {
        errors.add(const ValidationIssue(
            'Exact Lossless cannot change resolution, bitrate, target size, or frame rate.'));
      }
      final audio = media.audioStream;

      if (settings.losslessEncoder == LosslessEncoder.copy) {
        if (!videoCodecFitsContainer(video.codecName, settings.container)) {
          errors.add(ValidationIssue(
              'The source video (${video.codecName}) cannot be stream-copied into '
              '${settings.container.name.toUpperCase()}. Choose MKV or a lossless re-encode.'));
        }
        if (audio != null &&
            settings.audio == AudioAction.copySource &&
            !audioCodecFitsContainer(audio.codecName, settings.container)) {
          errors.add(ValidationIssue(
              'The source audio (${audio.codecName}) cannot be stream-copied into '
              '${settings.container.name.toUpperCase()}. Choose MKV, an audio conversion, or "drop audio".'));
        }
      } else {
        // Lossless re-encode: encoder must exist in this build, the pixel
        // format must survive without conversion, and this build's lossless
        // encoders are verified for 8-bit sources only.
        final encoderName = switch (settings.losslessEncoder) {
          LosslessEncoder.x264 => 'libx264',
          LosslessEncoder.x265 => 'libx265',
          LosslessEncoder.av1 => 'libaom-av1',
          LosslessEncoder.copy => '',
        };
        if (caps != null && !caps.supportsEncoder(encoderName)) {
          errors.add(ValidationIssue(
              '$encoderName is not included in this app\u2019s FFmpeg build — '
              'choose another lossless option or stream copy.'));
        }
        if (media.isHighBitDepth) {
          errors.add(const ValidationIssue(
              'This source is high bit depth (10/12-bit). The available lossless '
              'encoders cannot preserve it losslessly here — only stream copy '
              '(remux) is offered.'));
        }
        final pixFmt = video.pixFmt ?? 'yuv420p';
        final supported = switch (settings.losslessEncoder) {
          LosslessEncoder.x265 => const {'yuv420p'},
          LosslessEncoder.x264 =>
            const {'yuv420p', 'yuv422p', 'yuv444p'},
          LosslessEncoder.av1 =>
            const {'yuv420p', 'yuv422p', 'yuv444p'},
          LosslessEncoder.copy => const <String>{},
        };
        if (!supported.contains(pixFmt)) {
          errors.add(ValidationIssue(
              'Pixel format $pixFmt cannot be preserved losslessly by '
              '$encoderName. Stream copy (remux) keeps the original data intact.'));
        }
        if (audio != null &&
            settings.audio == AudioAction.copySource &&
            !audioCodecFitsContainer(audio.codecName, settings.container)) {
          if (settings.container == ContainerOption.mkv) {
            warnings.add(ValidationIssue(
                'Audio ${audio.codecName} will be converted to FLAC (lossless) '
                'for MKV compatibility.',
                isBlocking: false));
          } else {
            errors.add(ValidationIssue(
                'The source audio (${audio.codecName}) cannot be stored losslessly '
                'in ${settings.container.name.toUpperCase()}. Choose MKV or an audio option.'));
          }
        }
      }
      if (settings.container == ContainerOption.mp4 &&
          media.subtitleStreams.isNotEmpty) {
        warnings.add(const ValidationIssue(
            'Subtitles will be dropped: MP4 supports only a few subtitle types. '
            'Choose MKV to keep them.',
            isBlocking: false));
      }
    }

    // ---------- High Efficiency / Custom ----------
    if (settings.mode == CompressionMode.highEfficiency ||
        settings.mode == CompressionMode.custom) {
      // HDR mode validation for lossy/re-encode
      if (settings.hdrMode == HdrMode.sdrToHdr) {
        if (settings.videoCodec == VideoCodecOption.copySource) {
          errors.add(const ValidationIssue(
              'Stream copy cannot convert SDR to HDR. Choose an encoding codec like HEVC.'));
        } else if (settings.videoCodec != VideoCodecOption.hevc) {
          errors.add(ValidationIssue(
              'SDR to HDR conversion requires HEVC (H.265) 10-bit encoding. '
              '${settings.videoCodec.name.toUpperCase()} cannot output genuine HDR10.'));
        }
        if (media.isHdrSource) {
          warnings.add(const ValidationIssue(
              'The source video is already HDR. SDR to HDR conversion may alter original HDR mastering.',
              isBlocking: false));
        }
        if (settings.hardware == HardwarePreference.hardware) {
          warnings.add(const ValidationIssue(
              'Hardware encoding selected: full HDR10 mastering metadata is best generated using Auto or Software encoding.',
              isBlocking: false));
        }
      } else if (settings.hdrMode == HdrMode.hdrEffect) {
        if (settings.videoCodec == VideoCodecOption.copySource) {
          errors.add(const ValidationIssue(
              'HDR Effect visual filters cannot be applied in stream copy mode.'));
        }
      } else if (settings.hdrMode == HdrMode.preserveHdr) {
        if (!media.isHdrSource) {
          warnings.add(const ValidationIssue(
              'Source video does not appear to be HDR. Original SDR color characteristics will be preserved.',
              isBlocking: false));
        } else if (settings.videoCodec == VideoCodecOption.h264 &&
            settings.videoCodec != VideoCodecOption.copySource) {
          warnings.add(const ValidationIssue(
              'H.264 standard profile is 8-bit and will downconvert 10-bit HDR to 8-bit SDR. Select HEVC to preserve 10-bit HDR.',
              isBlocking: false));
        }
      }

      if (settings.videoCodec == VideoCodecOption.copySource &&
          settings.mode == CompressionMode.custom) {
        if (!videoCodecFitsContainer(video.codecName, settings.container)) {
          errors.add(ValidationIssue(
              'Source codec ${video.codecName} cannot be copied into '
              '${settings.container.name.toUpperCase()}. Pick another container or an encoding codec.'));
        }
        if (settings.targetWidth != null ||
            settings.targetHeight != null ||
            settings.targetBitrateKbps != null ||
            settings.targetSizeBytes != null ||
            settings.frameRate != null) {
          errors.add(const ValidationIssue(
              'Stream copy (no re-encode) cannot change resolution, bitrate, target size, or frame rate.'));
        }
      } else {
        // Encoding selected — check requested codec availability. CRF mode
        // is always software (MediaCodec has no CRF), so software
        // availability is required whenever crf is set.
        if (caps != null) {
          final hw = settings.hardware;
          final crfMode = settings.crf != null;
          final needHw = !crfMode && hw != HardwarePreference.software;
          final needSw = crfMode || hw != HardwarePreference.hardware;
          // Block unless at least one encoder this choice can actually use
          // exists — never start a job the build/device cannot run.
          if (settings.videoCodec == VideoCodecOption.h264 &&
              !((needHw && caps.h264Hardware) ||
                  (needSw && caps.h264Software))) {
            errors.add(ValidationIssue(
                hw == HardwarePreference.hardware && !crfMode && caps.h264Software
                    ? 'Hardware encoding is not available on this device. '
                        'Choose Auto or Software for H.264.'
                    : 'H.264 encoding is not available in this app build.'));
          }
          if (settings.videoCodec == VideoCodecOption.hevc &&
              !((needHw && caps.hevcHardware) ||
                  (needSw && caps.hevcSoftware))) {
            errors.add(ValidationIssue(
                hw == HardwarePreference.hardware && !crfMode && caps.hevcSoftware
                    ? 'Hardware encoding is not available on this device. '
                        'Choose Auto or Software for HEVC.'
                    : 'HEVC (H.265) encoding is not available on this device.'));
          }
          if (settings.videoCodec == VideoCodecOption.av1 && !caps.av1Software) {
            errors.add(const ValidationIssue(
                'No AV1 encoder (libaom-av1 or libsvtav1) is included in this '
                'app\u2019s FFmpeg build, so AV1 is unavailable.'));
          }
        }

        // CRF bounds (x264/x265: 0–51; libaom/libsvtav1: 0–63).
        if (settings.crf != null) {
          final maxCrf = settings.videoCodec == VideoCodecOption.av1 ? 63 : 51;
          if (settings.crf! < 0 || settings.crf! > maxCrf) {
            errors.add(ValidationIssue(
                'CRF must be between 0 and $maxCrf for '
                '${settings.videoCodec.name.toUpperCase()}.'));
          } else if (settings.crf! < 18) {
            warnings.add(ValidationIssue(
                'CRF ${settings.crf} is very high quality — the output may be '
                'as large as, or larger than, the original. Lower CRF always '
                'means a larger file.',
                isBlocking: false));
          }
        }
        if (settings.videoCodec == VideoCodecOption.av1 &&
            settings.crf != null) {
          warnings.add(const ValidationIssue(
              'AV1 software encoding is much slower than H.264/HEVC on phones. '
              'Long videos can take a very long time and drain the battery.',
              isBlocking: false));
        }
        if (settings.videoCodec == VideoCodecOption.hevc &&
            settings.crf != null) {
          warnings.add(const ValidationIssue(
              'HEVC software encoding is slower than H.264. Keep the app open '
              'until the job finishes.',
              isBlocking: false));
        }

        if (settings.videoCodec == VideoCodecOption.av1 &&
            settings.container == ContainerOption.mp4) {
          warnings.add(const ValidationIssue(
              'AV1 in MP4 has limited player support. MKV is safer.',
              isBlocking: false));
        }
        if (settings.videoCodec == VideoCodecOption.hevc &&
            settings.container == ContainerOption.mp4) {
          warnings.add(const ValidationIssue(
              'HEVC playback depends on your device/player. H.264 is the most compatible.',
              isBlocking: false));
        }
        if (settings.targetBitrateKbps != null &&
            video.bitRate != null &&
            video.bitRate! > 0 &&
            settings.targetBitrateKbps! * 1000 >= video.bitRate!) {
          warnings.add(ValidationIssue(
              'The target bitrate is not below the source bitrate '
              '(${(video.bitRate! / 1000).round()} kbps) — the output may be as large as, or larger than, '
              'the original.',
              isBlocking: false));
        }
        if (settings.targetSizeBytes != null) {
          if (settings.targetSizeBytes! <= 0) {
            errors.add(const ValidationIssue('Target size must be greater than 0.'));
          } else if (settings.targetSizeBytes! >= media.sizeBytes) {
            warnings.add(const ValidationIssue(
                'The target size is not below the original video size — compression may not save space.',
                isBlocking: false));
          }
        }
        if (settings.frameRate != null && video.frameRate != null) {
          if (settings.frameRate! > video.frameRate!) {
            errors.add(ValidationIssue(
                'Frame rate cannot exceed the source (${video.frameRate!.toStringAsFixed(2)} fps). '
                'Duplicating frames adds no quality and can increase size.'));
          } else if (settings.frameRate! < video.frameRate!) {
            warnings.add(ValidationIssue(
                'Reducing frame rate to ${settings.frameRate!.toStringAsFixed(2)} fps changes motion smoothness.',
                isBlocking: false));
          }
        }
        if (media.isHighBitDepth) {
          warnings.add(const ValidationIssue(
              'This source is high bit depth (10/12-bit). 8-bit encoders will '
              'slightly reduce color precision.',
              isBlocking: false));
        }
        final audio = media.audioStream;
        if (audio != null &&
            settings.audio == AudioAction.copySource &&
            !audioCodecFitsContainer(audio.codecName, settings.container)) {
          warnings.add(ValidationIssue(
              'Audio ${audio.codecName} is not compatible with '
              '${settings.container.name.toUpperCase()} and will be converted to AAC.',
              isBlocking: false));
        }
        if (settings.hardware == HardwarePreference.hardware) {
          warnings.add(const ValidationIssue(
              'Forcing hardware encoding: quality is usually a little below the '
              'software encoder at the same bitrate.',
              isBlocking: false));
        }
      }
    }

    return ValidationResult(errors, warnings);
  }
}

/// Mirror of [FfmpegCapabilities] to keep this file Flutter/plugin-free.
class FfmpegCapabilitiesLike {
  const FfmpegCapabilitiesLike({
    required this.h264Software,
    required this.hevcSoftware,
    required this.av1Software,
    required this.h264Hardware,
    required this.hevcHardware,
    this.av1Libaom = false,
    this.av1SvtAv1 = false,
  });

  final bool h264Software;
  final bool hevcSoftware;

  /// Any software AV1 encoder present (libaom-av1 or libsvtav1).
  final bool av1Software;
  final bool h264Hardware;
  final bool hevcHardware;

  /// Which AV1 encoders this FFmpeg build actually contains.
  final bool av1Libaom;
  final bool av1SvtAv1;

  /// Whether the named encoder exists in the packaged build.
  bool supportsEncoder(String name) => switch (name) {
        'libx264' => h264Software,
        'libx265' => hevcSoftware,
        'libaom-av1' => av1Libaom,
        'libsvtav1' => av1SvtAv1,
        'h264_mediacodec' => h264Hardware,
        'hevc_mediacodec' => hevcHardware,
        _ => false,
      };

  factory FfmpegCapabilitiesLike.from(dynamic caps) => FfmpegCapabilitiesLike(
        h264Software: caps.h264Software as bool,
        hevcSoftware: caps.hevcSoftware as bool,
        av1Software: caps.av1Software as bool,
        h264Hardware: caps.h264Hardware as bool,
        hevcHardware: caps.hevcHardware as bool,
        av1Libaom: caps.av1Libaom as bool,
        av1SvtAv1: caps.av1SvtAv1 as bool,
      );
}

class ValidationResult {
  const ValidationResult(this.errors, this.warnings);
  final List<ValidationIssue> errors;
  final List<ValidationIssue> warnings;
  bool get canStart => errors.isEmpty;
}
