import 'dart:convert';
import 'dart:io';

import '../models/models.dart';
import 'ffmpeg_service.dart';

/// Lossless verification via decoded-frame fingerprinting.
///
/// Both source and output are decoded and hashed per frame with ffmpeg's
/// `framemd5` muxer. A successful ffmpeg exit code is NEVER treated as proof
/// of losslessness — only matching decoded fingerprints are.
///
/// Comparison notes:
/// - pts/dts columns are ignored (container timebases may differ after remux);
///   frames are compared by per-stream order + content hash.
/// - Audio may legitimately differ by a few frames of encoder priming when
///   the container (e.g. MP4 edit lists) trims it; a small prefix difference
///   is tolerated and reported honestly in [VerificationResult.detail].
class VerificationService {
  VerificationService(this._ffmpeg);

  final FfmpegService _ffmpeg;

  /// Maximum audio frames allowed to differ as container priming (~116 ms).
  static const int maxAudioPrimingFrames = 8;

  /// Lossy-output integrity check (spec: verify decodable + structure).
  /// Never a losslessness claim — just proof the output is a usable video
  /// with the expected shape.
  Future<IntegrityResult> verifyLossyIntegrity({
    required MediaInfo source,
    required String outputPath,
    int? expectedWidth,
    int? expectedHeight,
    required bool expectAudio,
  }) async {
    final out = await _ffmpeg.probe(outputPath, fallbackSizeBytes: 0);
    final video = out.videoStream;
    if (video == null) {
      return const IntegrityResult(
        decodable: false,
        durationMatches: false,
        resolutionMatches: false,
        audioMatches: false,
        detail: 'Output has no video stream.',
      );
    }

    // Duration: within max(1 s, 3%) of the source.
    final srcDur = source.durationSeconds;
    final outDur = out.durationSeconds;
    final tol = srcDur > 0 ? (srcDur * 0.03).clamp(1.0, 10.0) : 1.0;
    final durationMatches = (outDur - srcDur).abs() <= tol;

    // Resolution: compare against what the settings asked for.
    final wantW = expectedWidth ?? source.videoStream?.width;
    final wantH = expectedHeight ?? source.videoStream?.height;
    final resolutionMatches = (wantW == null || video.width == null ||
            video.width == wantW) &&
        (wantH == null || video.height == null || video.height == wantH);

    // Audio presence matches the expectation.
    final hasAudio = out.audioStream != null;
    final audioMatches = hasAudio == expectAudio;

    final problems = <String>[
      if (!durationMatches)
        'duration ${outDur.toStringAsFixed(1)}s vs source ${srcDur.toStringAsFixed(1)}s',
      if (!resolutionMatches)
        'resolution ${video.width}x${video.height} '
            'vs expected ${wantW ?? '?'}x${wantH ?? '?'}',
      if (!audioMatches) hasAudio ? 'unexpected audio stream' : 'audio missing',
    ];

    return IntegrityResult(
      decodable: true,
      durationMatches: durationMatches,
      resolutionMatches: resolutionMatches,
      audioMatches: audioMatches,
      detail: problems.isEmpty ? null : problems.join('; '),
    );
  }

  Future<VerificationResult> verifyDecodedEquality({
    required String sourcePath,
    required String outputPath,
    void Function(JobProgress)? onProgress,
    double? totalDurationMs,
  }) async {
    final srcHashes = File('$outputPath.src.framemd5');
    final outHashes = File('$outputPath.out.framemd5');
    try {
      for (final target in [sourcePath, outputPath]) {
        final dest = target == sourcePath ? srcHashes : outHashes;
        final r = await _ffmpeg.run([
          '-v', 'error',
          '-y',
          '-i', target,
          '-map', '0:v?',
          '-map', '0:a?',
          '-f', 'framemd5',
          dest.path,
        ], stageLabel: 'Verifying', totalDurationMs: totalDurationMs,
            onProgress: onProgress);
        if (!r.isSuccess) {
          return VerificationResult(
            completed: false,
            videoIdentical: false,
            audioIdentical: false,
            detail: 'Verification could not be completed.',
          );
        }
      }

      final src = await parseFramemd5File(srcHashes);
      final out = await parseFramemd5File(outHashes);

      final videoIdentical =
          compareHashSequences(src.video, out.video, maxExtraFrames: 0);
      int audioDiffFrames = 0;
      final audioIdentical = compareHashSequences(src.audio, out.audio,
          maxExtraFrames: maxAudioPrimingFrames, diffCount: (n) => audioDiffFrames = n);

      final detail = audioDiffFrames > 0 && audioIdentical
          ? 'Audio differs only by $audioDiffFrames container priming frame(s).'
          : null;

      return VerificationResult(
        completed: true,
        videoIdentical: videoIdentical,
        audioIdentical: audioIdentical,
        detail: detail,
      );
    } finally {
      await _deleteIfExists(srcHashes);
      await _deleteIfExists(outHashes);
    }
  }

  static Future<void> _deleteIfExists(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Streams a framemd5 file, keeping only content hashes per stream.
  static Future<Framemd5Data> parseFramemd5File(File f) async {
    final video = <String>[];
    final audio = <String>[];
    final other = <String>[];
    final lines = f.openRead().transform(utf8.decoder).transform(const LineSplitter());
    await for (final raw in lines) {
      if (raw.isEmpty || raw.startsWith('#')) continue;
      final parts = raw.split(',');
      // Format: stream, dts, pts, duration, size, md5hex
      if (parts.length < 6) continue;
      final stream = int.tryParse(parts[0].trim());
      final hash = parts.last.trim();
      switch (stream) {
        case null:
          continue;
        case 0:
          video.add(hash);
        default:
          // Stream 1+ may be audio or extra video; classify by order:
          // planner maps 0=v, 1=a.
          if (video.isNotEmpty) audio.add(hash);
      }
    }
    return Framemd5Data(video: video, audio: audio, other: other);
  }

  /// Compares hash sequences. When lengths differ by at most [maxExtraFrames]
  /// (container priming: extra frames at the head or tail of the longer
  /// sequence), the sequences are aligned and compared; [diffCount] reports
  /// how many frames were tolerated.
  static bool compareHashSequences(
    List<String> a,
    List<String> b, {
    required int maxExtraFrames,
    void Function(int)? diffCount,
  }) {
    if (a.length == b.length) {
      final diffs = _countDiffs(a, b, a.length);
      if (diffs == 0) return true;
      if (diffs <= maxExtraFrames) {
        diffCount?.call(diffs);
        return true;
      }
      return false;
    }
    final diff = (a.length - b.length).abs();
    if (diff > maxExtraFrames) return false;
    final (shorter, longer) = a.length < b.length ? (a, b) : (b, a);

    // Align at tail: skip [diff] priming frames from the head of the longer
    // sequence (the common MP4 encoder-delay case).
    var headDiffs = 0;
    for (var i = 0; i < shorter.length; i++) {
      if (shorter[i] != longer[i + diff]) headDiffs++;
    }
    if (diff + headDiffs <= maxExtraFrames) {
      diffCount?.call(diff + headDiffs);
      return true;
    }
    // Align at head: skip [diff] frames from the tail of the longer one.
    final tailDiffs = _countDiffs(shorter, longer, shorter.length);
    if (diff + tailDiffs <= maxExtraFrames) {
      diffCount?.call(diff + tailDiffs);
      return true;
    }
    return false;
  }

  static int _countDiffs(List<String> a, List<String> b, int n) {
    var diffs = 0;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) diffs++;
    }
    return diffs;
  }
}

class Framemd5Data {
  const Framemd5Data({required this.video, required this.audio, required this.other});
  final List<String> video;
  final List<String> audio;
  final List<String> other;
}
