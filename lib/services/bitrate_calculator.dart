import '../models/models.dart';

/// Accurate bitrate budgeting and file size estimation.
class BitrateCalculator {
  BitrateCalculator._();

  /// Calculates the video bitrate (in kbps) needed to fit a video of [durationSeconds]
  /// within [targetSizeBytes], accounting for audio and container muxing overhead (~4%).
  static int calculateVideoBitrateKbps({
    required int targetSizeBytes,
    required double durationSeconds,
    required AudioAction audioAction,
    int? sourceAudioBitrate,
    bool hasAudio = true,
    HdrMode hdrMode = HdrMode.off,
  }) {
    if (durationSeconds <= 0) return 1000;

    // Safety margin for container/muxing overhead (MP4/MKV moov/idx/headers)
    // 4% overhead is standard and ensures target size is not exceeded.
    // 10-bit HDR streams have slightly more metadata.
    final overheadMargin = (hdrMode == HdrMode.sdrToHdr || hdrMode == HdrMode.preserveHdr)
        ? 0.95
        : 0.96;
    final usableBytes = targetSizeBytes * overheadMargin;

    // Determine audio bitrate in bits per second
    double audioBps = 0;
    if (hasAudio && audioAction != AudioAction.none) {
      audioBps = switch (audioAction) {
        AudioAction.copySource => (sourceAudioBitrate != null && sourceAudioBitrate > 0)
            ? sourceAudioBitrate.toDouble().clamp(32000, 320000)
            : 128000.0,
        AudioAction.aac128 => 128000.0,
        AudioAction.aac96 || AudioAction.opus96 => 96000.0,
        AudioAction.aac64 => 64000.0,
        AudioAction.none => 0.0,
      };
    }

    final audioBytes = (audioBps / 8.0) * durationSeconds;
    final videoBytes = usableBytes - audioBytes;

    final floorKbps = (hdrMode == HdrMode.sdrToHdr || hdrMode == HdrMode.preserveHdr) ? 250 : 100;
    if (videoBytes <= 0) {
      // Audio or container alone exceeds target size; return minimum floor
      return floorKbps;
    }

    final videoBps = (videoBytes * 8.0) / durationSeconds;
    final videoKbps = (videoBps / 1000.0).round();

    return videoKbps.clamp(floorKbps, 100000);
  }

  /// Calculates estimated output size in bytes given video bitrate, audio, and duration.
  static int estimateOutputBytes({
    required int videoBitrateKbps,
    required double durationSeconds,
    required AudioAction audioAction,
    int? sourceAudioBitrate,
    bool hasAudio = true,
    HdrMode hdrMode = HdrMode.off,
  }) {
    if (durationSeconds <= 0) return 0;
    double audioKbps = 0;
    if (hasAudio && audioAction != AudioAction.none) {
      audioKbps = switch (audioAction) {
        AudioAction.copySource => (sourceAudioBitrate != null && sourceAudioBitrate > 0)
            ? (sourceAudioBitrate / 1000.0).clamp(32.0, 320.0)
            : 128.0,
        AudioAction.aac128 => 128.0,
        AudioAction.aac96 || AudioAction.opus96 => 96.0,
        AudioAction.aac64 => 64.0,
        AudioAction.none => 0.0,
      };
    }
    final totalKbps = videoBitrateKbps + audioKbps;
    final rawBytes = (totalKbps * 1000 / 8.0) * durationSeconds;
    // Add 2% muxing overhead (2.5% for 10-bit HDR) for realistic estimate
    final muxFactor = (hdrMode == HdrMode.sdrToHdr || hdrMode == HdrMode.preserveHdr) ? 1.025 : 1.02;
    return (rawBytes * muxFactor).round();
  }
}
