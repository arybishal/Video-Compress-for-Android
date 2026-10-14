import 'dart:async';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';

import '../models/models.dart';
import 'media_probe.dart';

/// Thin wrapper over the FFmpeg engine. All argument lists are constructed by
/// [JobPlanner] — never from raw user command strings.
class FfmpegService {
  FfmpegService();

  int? _activeSessionId;
  Completer<FFmpegSession>? _activeCompleter;
  bool get isBusy => _activeSessionId != null;

  /// Probes [path] with ffprobe and returns parsed media info.
  /// Throws [FfmpegException] with a mapped reason on failure.
  Future<MediaInfo> probe(String path, {int fallbackSizeBytes = 0}) async {
    final session = await FFprobeKit.executeWithArguments([
      '-v', 'error',
      '-print_format', 'json',
      '-show_format',
      '-show_streams',
      path,
    ]);
    final rc = await session.getReturnCode();
    if (!ReturnCode.isSuccess(rc)) {
      throw FfmpegException(
        FfmpegErrorKind.corruptInput,
        'The file could not be analyzed. It may be corrupt or an unsupported format.',
        raw: await session.getFailStackTrace() ??
            mergeSessionText(
                await session.getOutput(), await session.getAllLogsAsString(2000)),
      );
    }
    final out = await session.getOutput();
    if (out == null || out.trim().isEmpty) {
      throw FfmpegException(FfmpegErrorKind.corruptInput,
          'The file could not be analyzed (no metadata found).');
    }
    return MediaProbe.parse(out, fallbackSizeBytes: fallbackSizeBytes);
  }

  /// Capability detection — the encoders this FFmpeg build + device support.
  Future<FfmpegCapabilities> detectCapabilities() async {
    if (_capabilities != null) return _capabilities!;
    final session = await FFmpegKit.executeWithArguments(
        ['-hide_banner', '-encoders']);
    // The listing may arrive on either session channel — read both so a real
    // encoder set is never mistaken for an empty one.
    final encoders = parseEncoderNames(mergeSessionText(
        await session.getOutput(), await session.getAllLogsAsString(2000)));
    final av1Libaom = encoders.contains('libaom-av1');
    final av1Svt = encoders.contains('libsvtav1');
    _capabilities = FfmpegCapabilities(
      h264Software: encoders.contains('libx264'),
      hevcSoftware: encoders.contains('libx265'),
      av1Software: av1Libaom || av1Svt,
      h264Hardware: encoders.contains('h264_mediacodec'),
      hevcHardware: encoders.contains('hevc_mediacodec'),
      av1Libaom: av1Libaom,
      av1SvtAv1: av1Svt,
    );
    return _capabilities!;
  }

  /// Harmless smoke test: runs FFmpeg -version and returns the engine version output.
  Future<FfmpegResult> runSmokeVersion() async =>
      run(['-version'], stageLabel: 'Version check');

  /// Combines the two channels ffmpeg-kit exposes for a session's console:
  /// [FFmpegSession.getOutput] (session output) and
  /// [FFmpegSession.getAllLogsAsString] (the av_log entries, where ffmpeg
  /// writes its errors). Neither channel alone is guaranteed to hold every
  /// line on every engine build, so failure mapping must read both.
  static String mergeSessionText(String? output, String? logs) {
    final o = (output ?? '').trim();
    final l = (logs ?? '').trim();
    if (o.isEmpty) return l;
    if (l.isEmpty) return o;
    if (l.contains(o)) return l;
    if (o.contains(l)) return o;
    return '$o\n$l';
  }

  /// Parses `ffmpeg -encoders` output into encoder names.
  ///
  /// Rows look like ` V....D libx264   libx264 H.264 / AVC (codec h264)` —
  /// column 2 is the encoder name. The legend rows (` V..... = Video`) and
  /// the `------` separator are skipped.
  static Set<String> parseEncoderNames(String output) {
    final re =
        RegExp(r'^\s*[VAS][A-Za-z.\-]{5}\s+([^=\s]\S*)', multiLine: true);
    return re.allMatches(output).map((m) => m.group(1)!).toSet();
  }

  FfmpegCapabilities? _capabilities;

  /// Executes one stage (an ffmpeg argument list). Progress comes from the
  /// engine's real statistics callback; [onProgress] receives it raw.
  Future<FfmpegResult> run(
    List<String> args, {
    required String stageLabel,
    double? totalDurationMs,
    void Function(JobProgress)? onProgress,
  }) async {
    final completer = Completer<FFmpegSession>();
    _activeCompleter = completer;

    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (FFmpegSession completedSession) {
        if (!completer.isCompleted) {
          completer.complete(completedSession);
        }
      },
      null,
      (Statistics? stats) {
        if (stats == null || onProgress == null) return;
        final processed = stats.getTime(); // ms of media timeline
        double? percent;
        if (totalDurationMs != null && totalDurationMs > 0 && processed >= 0) {
          percent = (processed / totalDurationMs).clamp(0.0, 1.0);
        }
        onProgress(JobProgress(
          stageLabel: stageLabel,
          percent: percent,
          processedMicros: processed * 1000,
          speed: stats.getSpeed(),
          fps: stats.getVideoFps(),
        ));
      },
    );
    final sessionId = session.getSessionId();
    _activeSessionId = sessionId;

    try {
      final completedSession = await completer.future;
      final rc = await completedSession.getReturnCode();
      final state = await completedSession.getState();
      // Merge both console channels: ffmpeg's error text (av_log) may only
      // appear in the session logs, and the failure mapper must always see it.
      final output = mergeSessionText(
          await completedSession.getOutput(),
          await completedSession.getAllLogsAsString(2000));
      final fail = await completedSession.getFailStackTrace();
      final isCancel = ReturnCode.isCancel(rc);
      final isSuccess = ReturnCode.isSuccess(rc);

      return FfmpegResult(
        returnCode: rc?.getValue() ?? (isCancel ? 255 : (isSuccess ? 0 : -1)),
        isSuccess: isSuccess,
        output: output,
        errorOutput: fail,
        cancelled: isCancel,
        sessionId: sessionId,
        sessionState: state.name,
      );
    } finally {
      _activeSessionId = null;
      _activeCompleter = null;
    }
  }

  /// Requests cancellation of the in-flight session (if any).
  Future<void> cancelActive() async {
    final id = _activeSessionId;
    if (id != null) {
      await FFmpegKit.cancel(id);
      final comp = _activeCompleter;
      if (comp != null && !comp.isCompleted) {
        // Fallback: if native completion event is lost, resolve after grace period
        Future.delayed(const Duration(milliseconds: 2000), () async {
          if (!comp.isCompleted) {
            try {
              final s = await FFmpegKitConfig.getSession(id);
              if (s is FFmpegSession && !comp.isCompleted) {
                comp.complete(s);
              }
            } catch (_) {}
          }
        });
      }
    }
  }
}

class FfmpegCapabilities {
  const FfmpegCapabilities({
    required this.h264Software,
    required this.hevcSoftware,
    required this.av1Software,
    required this.h264Hardware,
    required this.hevcHardware,
    required this.av1Libaom,
    required this.av1SvtAv1,
  });

  final bool h264Software;
  final bool hevcSoftware;
  final bool av1Software;
  final bool h264Hardware;
  final bool hevcHardware;

  /// Which AV1 encoders the packaged build contains (this app ships
  /// libaom-av1; libsvtav1 is not included in the current full-GPL build).
  final bool av1Libaom;
  final bool av1SvtAv1;

  @override
  String toString() =>
      'h264(sw:$h264Software,hw:$h264Hardware) hevc(sw:$hevcSoftware,hw:$hevcHardware) '
      'av1(libaom:$av1Libaom,svt:$av1SvtAv1)';
}

class FfmpegResult {
  const FfmpegResult({
    required this.returnCode,
    required this.isSuccess,
    required this.output,
    required this.errorOutput,
    required this.cancelled,
    this.sessionId,
    this.sessionState,
  });

  final int returnCode;
  final bool isSuccess;
  final String output;
  final String? errorOutput;
  final bool cancelled;
  final int? sessionId;
  final String? sessionState;
}

enum FfmpegErrorKind {
  unsupportedCodec,
  unsupportedOption,
  unsupportedContainer,
  corruptInput,
  inaccessibleInput,
  noSpace,
  encoderInit,
  hardwareEncoderFailed,
  ioError,
  outOfMemory,
  engineInit,
  sessionError,
  validationFailed,
  unknown,
}

class FfmpegException implements Exception {
  const FfmpegException(this.kind, this.userMessage, {this.raw});

  final FfmpegErrorKind kind;
  final String userMessage;
  final String? raw;

  @override
  String toString() => userMessage;
}

/// Maps raw ffmpeg stderr to an understandable, user-facing error.
FfmpegException mapFfmpegFailure(FfmpegResult result, {bool hardwareWasUsed = false}) {
  final err = (result.errorOutput ?? '') + result.output;
  final lower = err.toLowerCase();

  if (lower.contains('failed to load') ||
      lower.contains('unsatisfiedlinkerror') ||
      lower.contains('could not load')) {
    return FfmpegException(
      FfmpegErrorKind.engineInit,
      'The FFmpeg native library could not be loaded for your device architecture.',
      raw: err,
    );
  }
  if (lower.contains('unrecognized option') ||
      lower.contains('option not found') ||
      lower.contains('trailing options were found')) {
    return FfmpegException(
      FfmpegErrorKind.unsupportedOption,
      'The selected compression options are not supported by this engine build.',
      raw: err,
    );
  }
  if (lower.contains('no space left')) {
    return FfmpegException(FfmpegErrorKind.noSpace,
        'Not enough free storage to finish. Free up space and try again.',
        raw: err);
  }
  if (lower.contains('unknown encoder') || lower.contains('encoder not found')) {
    return FfmpegException(FfmpegErrorKind.unsupportedCodec,
        'The selected codec is not supported on this device.', raw: err);
  }
  if (lower.contains('unable to find a suitable output format') ||
      (lower.contains('invalid argument') && lower.contains('output')) ||
      lower.contains('could not write header for output') ||
      lower.contains('tag not found')) {
    return FfmpegException(FfmpegErrorKind.unsupportedContainer,
        'The selected output container cannot hold these streams.', raw: err);
  }
  if (hardwareWasUsed &&
      (lower.contains('mediacodec') || lower.contains('codec init failed') || lower.contains('error while opening encoder'))) {
    return FfmpegException(FfmpegErrorKind.hardwareEncoderFailed,
        'The hardware encoder failed to start. Try again with software encoding.',
        raw: err);
  }
  if (lower.contains('broken pipe') ||
      lower.contains('av_interleaved_write_frame') ||
      lower.contains('error muxing')) {
    return FfmpegException(FfmpegErrorKind.ioError,
        'The output could not be written. Check available storage and try again.',
        raw: err);
  }
  if (lower.contains('cannot allocate memory') ||
      lower.contains('not enough memory') ||
      lower.contains('out of memory')) {
    return FfmpegException(FfmpegErrorKind.outOfMemory,
        'The device ran out of memory during compression. Close other apps '
        'and try again with a lower resolution.',
        raw: err);
  }
  if (lower.contains('no such file or directory') ||
      lower.contains('does not exist')) {
    return FfmpegException(FfmpegErrorKind.inaccessibleInput,
        'The input file could not be found or accessed.',
        raw: err);
  }
  if (lower.contains('error opening input') ||
      lower.contains('error while opening input')) {
    return FfmpegException(FfmpegErrorKind.corruptInput,
        'The video could not be opened. It may be corrupt or in an '
        'unsupported format.',
        raw: err);
  }
  if (lower.contains('error while opening encoder') ||
      lower.contains('codec init failed')) {
    return FfmpegException(FfmpegErrorKind.encoderInit,
        'The encoder could not be initialized.', raw: err);
  }
  if (lower.contains('moov atom not found') ||
      lower.contains('invalid data found') ||
      lower.contains('end of file') ||
      lower.contains('corrupt')) {
    return FfmpegException(FfmpegErrorKind.corruptInput,
        'The video file appears to be corrupt or incomplete.', raw: err);
  }
  if (lower.contains('permission denied') || lower.contains('operation not permitted')) {
    return FfmpegException(FfmpegErrorKind.ioError,
        'Permission to read the source file was lost. Please select the video again.',
        raw: err);
  }
  if (result.sessionState == 'failed') {
    return FfmpegException(
      FfmpegErrorKind.sessionError,
      'The FFmpeg execution engine failed to run the session.',
      raw: err.isNotEmpty ? err : 'Session state: failed',
    );
  }
  // When no logs were captured and return code is -1:
  if (err.isEmpty && result.returnCode == -1) {
    return FfmpegException(FfmpegErrorKind.sessionError,
        'Compression failed before the engine could produce diagnostic output '
        '(session ${result.sessionId ?? 'unknown'}).',
        raw: 'Session ${result.sessionId}: state=${result.sessionState}, rc=-1, no log output captured.');
  }

  // Last resort: keep the engine's real console output in `raw` so the
  // diagnostic log can show what actually happened. The controller appends
  // a diagnostic id to this message.
  return FfmpegException(FfmpegErrorKind.unknown,
      'Processing failed unexpectedly. The original file was not modified.',
      raw: err.isEmpty ? 'return code ${result.returnCode}' : err);
}
