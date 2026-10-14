/// Domain models for PureCompress. Pure Dart — no Flutter imports — so the
/// media logic is unit-testable on the host.
library;

import 'aspect_ratio_options.dart';
import 'compression_preset.dart';
import 'hdr_options.dart';
export 'aspect_ratio_options.dart';
export 'compression_preset.dart';
export 'hdr_options.dart';
export 'resolution_helper.dart';

/// Which compression strategy the user picked.
enum CompressionMode { exactLossless, highEfficiency, custom }

enum VideoCodecOption { h264, hevc, av1, copySource }

/// How the Exact Lossless mode produces its output.
enum LosslessEncoder {
  /// Stream copy (remux): no re-encoding at all. Fastest; container and
  /// metadata may change but encoded stream data is untouched.
  copy,

  /// H.264 mathematically lossless re-encode (libx264 -crf 0).
  x264,

  /// HEVC mathematically lossless re-encode (libx265 lossless=1).
  x265,

  /// AV1 mathematically lossless re-encode (libaom-av1 -lossless 1).
  av1,
}

/// Encoder speed/effort preset. Maps to x264/x265 `-preset` names and to
/// libaom `-cpu-used` values in the job planner.
enum SpeedPreset {
  veryfast('Very fast'),
  fast('Fast'),
  medium('Medium'),
  slow('Slow'),
  veryslow('Very slow');

  const SpeedPreset(this.label);
  final String label;
}

enum AudioAction { copySource, aac128, aac96, aac64, opus96, none }

enum ContainerOption { mp4, mkv }

/// Quality presets for High Efficiency mode. Explicitly lossy.
enum QualityPreset {
  highQuality('High quality', 'Visually near-identical, modest savings'),
  balanced('Balanced', 'Good savings, high visual quality'),
  smaller('Smaller file', 'Noticeably smaller, quality still good');

  const QualityPreset(this.label, this.description);
  final String label;
  final String description;
}

enum HardwarePreference { auto, hardware, software }

/// One stream as reported by ffprobe.
class StreamInfo {
  const StreamInfo({
    required this.index,
    required this.codecType,
    required this.codecName,
    this.width,
    this.height,
    this.pixFmt,
    this.frameRate,
    this.bitRate,
    this.sampleRate,
    this.channels,
    this.colorSpace,
    this.colorTransfer,
    this.colorPrimaries,
    this.colorRange,
    this.rotationDegrees = 0,
    this.language,
    this.title,
  });

  final int index;
  final String codecType; // 'video' | 'audio' | 'subtitle' | ...
  final String codecName;
  final int? width;
  final int? height;
  final String? pixFmt;
  final double? frameRate;
  final int? bitRate;
  final int? sampleRate;
  final int? channels;
  final String? colorSpace;
  final String? colorTransfer;
  final String? colorPrimaries;
  final String? colorRange;
  final int rotationDegrees;
  final String? language;
  final String? title;

  bool get isVideo => codecType == 'video';
  bool get isAudio => codecType == 'audio';
  bool get isSubtitle => codecType == 'subtitle';

  bool get isHdr => HdrCharacteristics.isHdrStream(
        transfer: colorTransfer,
        primaries: colorPrimaries,
        pixFmt: pixFmt,
      );

  int get bitDepth => (pixFmt?.contains('10') == true)
      ? 10
      : (pixFmt?.contains('12') == true)
          ? 12
          : 8;

  String get colorSummary {
    final parts = <String>[];
    if (colorPrimaries != null && colorPrimaries!.isNotEmpty) {
      parts.add(HdrCharacteristics.formatPrimaries(colorPrimaries));
    }
    if (colorTransfer != null && colorTransfer!.isNotEmpty) {
      parts.add(HdrCharacteristics.formatTransfer(colorTransfer));
    }
    if (bitDepth != 8) {
      parts.add('$bitDepth-bit');
    }
    return parts.isEmpty ? 'SDR (8-bit)' : parts.join(', ');
  }

  /// Display dimensions accounting for rotation metadata (90°/270° swaps width and height).
  int? get displayWidth =>
      (rotationDegrees == 90 || rotationDegrees == 270) ? height : width;

  int? get displayHeight =>
      (rotationDegrees == 90 || rotationDegrees == 270) ? width : height;

  bool get isPortrait => (displayHeight ?? 0) > (displayWidth ?? 0);

  String get aspectRatioString =>
      (displayWidth != null && displayHeight != null)
          ? AspectRatioHelper.formatAspectRatio(displayWidth!, displayHeight!)
          : 'Unknown';
}

/// Result of probing a source file with ffprobe.
class MediaInfo {
  const MediaInfo({
    required this.formatName,
    required this.durationSeconds,
    required this.sizeBytes,
    required this.bitRate,
    required this.streams,
    required this.tags,
    this.probeScore = 0,
  });

  final String formatName;
  final double durationSeconds;
  final int sizeBytes;
  final int bitRate;
  final List<StreamInfo> streams;
  final Map<String, String> tags;
  final int probeScore;

  StreamInfo? get videoStream =>
      streams.where((s) => s.isVideo).cast<StreamInfo?>().firstWhere(
            (s) => s != null,
            orElse: () => null,
          );
  StreamInfo? get audioStream =>
      streams.where((s) => s.isAudio).cast<StreamInfo?>().firstWhere(
            (s) => s != null,
            orElse: () => null,
          );
  List<StreamInfo> get subtitleStreams =>
      streams.where((s) => s.isSubtitle).toList();

  /// True when any pixel format or bit depth we cannot losslessly re-encode.
  bool get isHighBitDepth =>
      videoStream?.pixFmt?.contains('10') == true ||
      videoStream?.pixFmt?.contains('12') == true;

  /// True if the primary video stream has HDR color characteristics.
  bool get isHdrSource => videoStream?.isHdr ?? false;
}

/// Fully validated, ready-to-execute compression request.
class CompressionSettings {
  const CompressionSettings({
    required this.mode,
    this.videoCodec = VideoCodecOption.h264,
    this.quality = QualityPreset.balanced,
    this.targetWidth,
    this.targetHeight,
    this.targetBitrateKbps,
    this.targetSizeBytes,
    this.profile,
    this.presetId,
    this.frameRate,
    this.audio = AudioAction.copySource,
    this.container = ContainerOption.mp4,
    this.hardware = HardwarePreference.auto,
    this.keepMetadata = true,
    this.losslessEncoder = LosslessEncoder.copy,
    this.crf,
    this.speedPreset = SpeedPreset.medium,
    this.hdrMode = HdrMode.off,
    this.hdrIntensity = 0.5,
    this.aspectRatio = AspectRatioOption.original,
    this.customAspectRatioWidth,
    this.customAspectRatioHeight,
    this.fitPolicy = VideoFitPolicy.preserveOriginal,
  });

  final CompressionMode mode;
  final VideoCodecOption videoCodec;
  final QualityPreset quality;
  final int? targetWidth;
  final int? targetHeight;
  final int? targetBitrateKbps;
  final int? targetSizeBytes;
  final CompressionProfile? profile;
  final String? presetId;
  final double? frameRate;
  final AudioAction audio;
  final ContainerOption container;
  final HardwarePreference hardware;
  final bool keepMetadata;

  /// Exact Lossless output strategy (copy / x264 / x265 / av1 lossless).
  final LosslessEncoder losslessEncoder;

  /// Constant-Rate-Factor target. When set, software CRF encoding is used
  /// (hardware MediaCodec encoders have no CRF mode). Null = bitrate-based
  /// rate control (Custom mode).
  final int? crf;

  /// Software encoder speed/effort preset.
  final SpeedPreset speedPreset;

  /// HDR color management and enhancement strategy.
  final HdrMode hdrMode;

  /// Intensity factor for [HdrMode.hdrEffect] (0.1 to 1.0, default 0.5).
  final double hdrIntensity;

  /// Aspect ratio preference (Original, 9:16, 16:9, 1:1, 4:5, 3:4, 4:3, Custom).
  final AspectRatioOption aspectRatio;

  /// Custom aspect ratio width component.
  final int? customAspectRatioWidth;

  /// Custom aspect ratio height component.
  final int? customAspectRatioHeight;

  /// Explicit output-fit policy (preserveOriginal, fitPadding, cropFill, stretch).
  final VideoFitPolicy fitPolicy;

  CompressionSettings copyWith({
    CompressionMode? mode,
    VideoCodecOption? videoCodec,
    QualityPreset? quality,
    int? targetWidth,
    int? targetHeight,
    int? targetBitrateKbps,
    int? targetSizeBytes,
    CompressionProfile? profile,
    String? presetId,
    double? frameRate,
    AudioAction? audio,
    ContainerOption? container,
    HardwarePreference? hardware,
    bool? keepMetadata,
    LosslessEncoder? losslessEncoder,
    int? crf,
    SpeedPreset? speedPreset,
    HdrMode? hdrMode,
    double? hdrIntensity,
    AspectRatioOption? aspectRatio,
    int? customAspectRatioWidth,
    int? customAspectRatioHeight,
    VideoFitPolicy? fitPolicy,
    bool clearResolution = false,
    bool clearBitrate = false,
    bool clearTargetSize = false,
    bool clearProfile = false,
    bool clearPresetId = false,
    bool clearFrameRate = false,
    bool clearCrf = false,
    bool clearCustomAspectRatio = false,
  }) {
    return CompressionSettings(
      mode: mode ?? this.mode,
      videoCodec: videoCodec ?? this.videoCodec,
      quality: quality ?? this.quality,
      targetWidth: clearResolution ? null : (targetWidth ?? this.targetWidth),
      targetHeight: clearResolution ? null : (targetHeight ?? this.targetHeight),
      targetBitrateKbps:
          clearBitrate ? null : (targetBitrateKbps ?? this.targetBitrateKbps),
      targetSizeBytes:
          clearTargetSize ? null : (targetSizeBytes ?? this.targetSizeBytes),
      profile: clearProfile ? null : (profile ?? this.profile),
      presetId: clearPresetId ? null : (presetId ?? this.presetId),
      frameRate: clearFrameRate ? null : (frameRate ?? this.frameRate),
      audio: audio ?? this.audio,
      container: container ?? this.container,
      hardware: hardware ?? this.hardware,
      keepMetadata: keepMetadata ?? this.keepMetadata,
      losslessEncoder: losslessEncoder ?? this.losslessEncoder,
      crf: clearCrf ? null : (crf ?? this.crf),
      speedPreset: speedPreset ?? this.speedPreset,
      hdrMode: hdrMode ?? this.hdrMode,
      hdrIntensity: hdrIntensity ?? this.hdrIntensity,
      aspectRatio: aspectRatio ?? this.aspectRatio,
      customAspectRatioWidth: clearCustomAspectRatio
          ? null
          : (customAspectRatioWidth ?? this.customAspectRatioWidth),
      customAspectRatioHeight: clearCustomAspectRatio
          ? null
          : (customAspectRatioHeight ?? this.customAspectRatioHeight),
      fitPolicy: fitPolicy ?? this.fitPolicy,
    );
  }
}

/// A pre-flight issue found in settings. [isBlocking] = cannot start.
class ValidationIssue {
  const ValidationIssue(this.message, {this.isBlocking = true});
  final String message;
  final bool isBlocking;
}

/// A planned pipeline: an ordered list of ffmpeg argument lists (stages)
/// plus human-readable description. Executed as: `ffmpeg <stage args>`.
class CompressionPlan {
  const CompressionPlan({
    required this.stages,
    required this.description,
    this.isLossless = false,
    this.expectedVerification = VerificationExpectation.none,
  });

  final List<List<String>> stages;
  final String description;
  final bool isLossless;
  final VerificationExpectation expectedVerification;
}

enum VerificationExpectation {
  /// No verification performed (lossy output).
  none,

  /// Bit-exact packets expected (stream copy) — decoded frames + audio
  /// samples compared via framemd5.
  decodedEquality,

  /// Lossless re-encode — decoded frames + audio samples compared via
  /// framemd5 (file itself is *not* bit-identical).
  decodedEqualityReencode,
}

/// Live progress snapshot pushed from the engine. Never fabricated:
/// [percent] is null whenever the encoder cannot report an exact position.
class JobProgress {
  const JobProgress({
    required this.stageLabel,
    this.percent,
    this.processedMicros,
    this.speed,
    this.fps,
  });

  final String stageLabel;
  final double? percent;
  final int? processedMicros;
  final double? speed;
  final double? fps;
}

enum JobStatus { running, completed, failed, cancelled, interrupted }

/// Outcome of one compression job (persisted in local history).
class JobRecord {
  const JobRecord({
    required this.id,
    required this.createdAt,
    required this.sourceName,
    required this.originalBytes,
    required this.outputBytes,
    required this.durationMs,
    required this.mode,
    required this.videoCodec,
    this.outputPath,
    this.verification,
    this.integrity,
    this.status = JobStatus.completed,
    this.errorCode,
    this.outputPixFmt,
    this.outputColorPrimaries,
    this.outputColorTransfer,
    this.outputColorSpace,
    this.outputBitDepth,
    this.hdrMode,
    this.hdrStatus,
    this.outputWidth,
    this.outputHeight,
    this.outputAspectRatio,
    this.outputFps,
    this.aspectRatio,
    this.fitPolicy,
  });

  final String id;
  final DateTime createdAt;
  final String sourceName;
  final int originalBytes;
  final int outputBytes;
  final int durationMs;
  final CompressionMode mode;
  final String videoCodec;
  final String? outputPath;
  final VerificationResult? verification;

  /// Lossy-mode output integrity (decodable / duration / resolution / audio).
  final IntegrityResult? integrity;
  final JobStatus status;
  final String? errorCode;

  /// Verified output color and dynamic range characteristics.
  final String? outputPixFmt;
  final String? outputColorPrimaries;
  final String? outputColorTransfer;
  final String? outputColorSpace;
  final int? outputBitDepth;
  final HdrMode? hdrMode;
  final String? hdrStatus;

  /// Verified output dimensions and aspect ratio.
  final int? outputWidth;
  final int? outputHeight;
  final String? outputAspectRatio;
  final double? outputFps;
  final AspectRatioOption? aspectRatio;
  final VideoFitPolicy? fitPolicy;

  int get bytesDelta => originalBytes - outputBytes;

  /// Actual savings percentage. Negative when the output is larger.
  double get percentSaved =>
      originalBytes == 0 ? 0 : (bytesDelta / originalBytes) * 100;
}

/// Result of lossless verification. [completed] false = we must NOT claim
/// success or failure of losslessness.
///
/// `videoIdentical`/`audioIdentical` mean the *decoded* frames/samples of
/// source and output hash identically (framemd5 comparison).
class VerificationResult {
  const VerificationResult({
    required this.completed,
    required this.videoIdentical,
    required this.audioIdentical,
    this.detail,
  });

  final bool completed;
  final bool videoIdentical;
  final bool audioIdentical;
  final String? detail;

  bool get fullyIdentical => completed && videoIdentical && audioIdentical;

  static const notApplicable = VerificationResult(
    completed: false,
    videoIdentical: false,
    audioIdentical: false,
  );
}

/// Result of a lossy-output integrity check (spec: verify the output is
/// decodable and structurally sound — never a losslessness claim).
class IntegrityResult {
  const IntegrityResult({
    required this.decodable,
    required this.durationMatches,
    required this.resolutionMatches,
    required this.audioMatches,
    this.detail,
  });

  final bool decodable;
  final bool durationMatches;
  final bool resolutionMatches;

  /// Output audio presence matches what the settings asked for.
  final bool audioMatches;
  final String? detail;

  bool get ok => decodable && durationMatches && resolutionMatches && audioMatches;

  static const notRun = IntegrityResult(
    decodable: false,
    durationMatches: false,
    resolutionMatches: false,
    audioMatches: false,
  );
}

/// Byte/percentage math in one testable place.
class SizeStats {
  SizeStats._();
  static int bytesDelta(int original, int output) => original - output;
  static double percentSaved(int original, int output) =>
      original == 0 ? 0 : ((original - output) / original) * 100;
}
