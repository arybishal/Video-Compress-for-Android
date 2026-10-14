import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'diagnostic_log.dart';
import 'ffmpeg_service.dart';
import 'job_planner.dart';
import 'job_repository.dart';
import 'native_exporter.dart';
import 'settings_validator.dart';
import 'temp_manager.dart';
import 'verification_service.dart';

/// Orchestrates one compression job at a time. Real progress only; honest
/// failure handling; never touches the source file.
class CompressionController extends ChangeNotifier {
  CompressionController({
    required this.ffmpeg,
    required this.tempManager,
    required this.jobRepository,
    required this.exporter,
    VerificationService? verification,
  }) : _verification = verification ?? VerificationService(ffmpeg);

  final FfmpegService ffmpeg;
  final TempManager tempManager;
  final JobRepository jobRepository;
  final NativeExporter exporter;
  final VerificationService _verification;

  JobStatus status = JobStatus.running;
  JobProgress? progress;
  FfmpegException? error;
  JobRecord? lastRecord;
  CompressionPlan? lastPlan;
  VerificationResult? verificationResult;
  IntegrityResult? integrityResult;
  bool usedHardwareFallback = false;

  /// Diagnostic id (== job id) of the current/last run, shown on failure.
  String? lastDiagnosticId;

  /// Path of the diagnostic log file, non-null while a failed job's log
  /// exists — the failure screen offers to share it.
  String? lastDiagnosticPath;

  bool _cancelled = false;
  bool get isBusy => status == JobStatus.running;

  /// Runs [settings] on [sourcePath] from start to verified result.
  Future<JobRecord> run({
    required String sourcePath,
    required String sourceName,
    required MediaInfo media,
    required CompressionSettings settings,
  }) async {
    _cancelled = false;
    status = JobStatus.running;
    progress = const JobProgress(stageLabel: 'Preparing');
    final sw = Stopwatch()..start();
    final jobId = TempManager.newJobId();

    // The job id doubles as the diagnostic id in user-facing messages.
    lastDiagnosticId = jobId;
    lastDiagnosticPath = null;
    DiagnosticLog? diag;

    try {
      diag = await DiagnosticLog.begin(await tempManager.base(), jobId);
      lastDiagnosticPath = diag.file?.path;

      // ---- pre-flight -----------------------------------------------------
      final caps = await ffmpeg.detectCapabilities();
      diag.section('source & settings');
      diag.line(
          'settings: mode=${settings.mode.name} codec=${settings.videoCodec.name} '
          'lossless=${settings.losslessEncoder.name} crf=${settings.crf} '
          'speed=${settings.speedPreset.name} audio=${settings.audio.name} '
          'container=${settings.container.name} hardware=${settings.hardware.name} '
          'resolution=${settings.targetWidth == null ? 'unchanged' : '${settings.targetWidth}x${settings.targetHeight}'} '
          'fps=${settings.frameRate ?? 'unchanged'} '
          'bitrateKbps=${settings.targetBitrateKbps ?? '-'} '
          'keepMetadata=${settings.keepMetadata}');
      diag.line('source: $sourcePath');
      final isContentUri = sourcePath.startsWith('content://');
      diag.line('source isContentUri: $isContentUri');
      if (isContentUri) {
        throw const FfmpegException(
          FfmpegErrorKind.inaccessibleInput,
          'Cannot pass a content URI directly to FFmpeg. The video must be copied to app storage first.',
        );
      }

      final sourceFile = File(sourcePath);
      bool sourceExists = false;
      int sourceBytes = -1;
      try {
        sourceExists = await sourceFile.exists();
        if (sourceExists) {
          sourceBytes = await sourceFile.length();
          final raf = await sourceFile.open(mode: FileMode.read);
          await raf.close();
        }
      } on FileSystemException catch (e) {
        diag.line('source file filesystem error: $e');
        throw FfmpegException(
          FfmpegErrorKind.ioError,
          'Could not read the source video: ${e.message}',
          raw: '$e',
        );
      } catch (e) {
        diag.line('source file verification error: $e');
      }

      diag.line('source exists: $sourceExists, source bytes: $sourceBytes '
          '(probe reports ${media.sizeBytes}), '
          'format ${media.formatName}, duration ${media.durationSeconds}s');

      if (sourceExists && sourceBytes == 0) {
        throw FfmpegException(
          FfmpegErrorKind.corruptInput,
          'The selected video file is empty (0 bytes).',
          raw: 'sourceExists=true, sourceBytes=0, path=$sourcePath',
        );
      }

      final inVideo = media.videoStream;
      diag.line('video: ${inVideo?.codecName ?? 'none'} '
          '${inVideo?.width ?? '?'}x${inVideo?.height ?? '?'} '
          '${inVideo?.pixFmt ?? '?'} ${inVideo?.frameRate ?? '?'}fps');
      final inAudio = media.audioStream;
      diag.line('audio: ${inAudio?.codecName ?? 'none'}');
      diag.section('engine capabilities');
      diag.line('$caps');

      final validation = SettingsValidator.validate(
        settings,
        media,
        caps: FfmpegCapabilitiesLike.from(caps),
      );
      if (!validation.canStart) {
        throw FfmpegException(FfmpegErrorKind.unknown,
            validation.errors.map((e) => e.message).join('\n'));
      }

      final jobDir = await tempManager.createJobDir(jobId);
      final jobDirExists = await jobDir.exists();
      bool jobDirWritable = false;
      try {
        final probeFile = File('${jobDir.path}${Platform.pathSeparator}.write_probe');
        await probeFile.writeAsString('ok');
        await probeFile.delete();
        jobDirWritable = true;
      } on FileSystemException catch (e) {
        diag.line('job directory writability probe failed: $e');
        throw FfmpegException(
          FfmpegErrorKind.ioError,
          'Cannot write to temporary working directory: ${e.message}',
          raw: '$e',
        );
      }
      diag.line('job dir: ${jobDir.path} (exists=$jobDirExists, writable=$jobDirWritable)');

      final settings2 = await _autoFallbackSettings(settings, caps);
      usedHardwareFallback = settings2.hardware != settings.hardware;

      final outputPath =
          '${jobDir.path}${Platform.pathSeparator}${JobPlanner.outputName(sourceName, settings2, jobId: jobId)}';

      final plan = JobPlanner.plan(
        settings: settings2,
        media: media,
        caps: FfmpegCapabilitiesLike.from(caps),
        sourcePath: sourcePath,
        outputPath: outputPath,
      );
      lastPlan = plan;

      diag.section('plan');
      diag.line('job dir: ${jobDir.path}');
      diag.line('output: $outputPath');
      diag.line('stages: ${plan.stages.length}, '
          'verification: ${plan.expectedVerification.name}, '
          'auto hardware fallback: $usedHardwareFallback');

      // ---- storage sanity check -------------------------------------------
      final free = await exporter.freeBytes() ?? 0;
      diag.line('free bytes: $free');
      if (free > 0 && free < media.sizeBytes) {
        throw FfmpegException(
            FfmpegErrorKind.noSpace,
            'Not enough free storage: this job may need close to the original '
            'size (${_mb(media.sizeBytes)} MB) of working space, but only ${_mb(free)} MB is available.');
      }

      // ---- execute stages --------------------------------------------------
      final totalMs = media.durationSeconds * 1000;
      for (var i = 0; i < plan.stages.length; i++) {
        final label = plan.stages.length == 1
            ? (i == 0 ? 'Compressing' : 'Stage ${i + 1}')
            : 'Stage ${i + 1} of ${plan.stages.length}';
        final args = plan.stages[i];
        diag.line('stage ${i + 1} args: ${args.join(' ')}');
        final result = await ffmpeg.run(
          args,
          stageLabel: label,
          totalDurationMs: totalMs,
          onProgress: _onProgress,
        );
        diag.line('stage ${i + 1} result: rc=${result.returnCode} '
            'success=${result.isSuccess} cancelled=${result.cancelled} '
            'sessionId=${result.sessionId} sessionState=${result.sessionState}');
        if (!result.isSuccess && result.output.isNotEmpty) {
          diag.line('stage ${i + 1} console (tail):\n${_tail(result.output)}');
        }
        if (_cancelled || result.cancelled) {
          await diag.discard();
          await _cleanup(jobId);
          status = JobStatus.cancelled;
          notifyListeners();
          return _record(sourceName, media, settings2, sw, jobId,
              status: JobStatus.cancelled,
              codec: _codecLabel(settings2, sourceVideoCodec: inVideo?.codecName));
        }
        if (!result.isSuccess) {
          int partialBytes = -1;
          try {
            final partialFile = File(outputPath);
            if (await partialFile.exists()) {
              partialBytes = await partialFile.length();
            }
          } catch (_) {}
          diag.line('stage ${i + 1} failed: partial output exists=${partialBytes >= 0} ($partialBytes bytes)');
          throw mapFfmpegFailure(result,
              hardwareWasUsed: settings2.hardware != HardwarePreference.software);
        }
      }

      var finalSettings = settings2;

      // ---- bounded target-size retry ---------------------------------------
      if (settings2.targetSizeBytes != null && !_cancelled) {
        final outCheckFile = File(outputPath);
        if (await outCheckFile.exists()) {
          final firstPassBytes = await outCheckFile.length();
          if (firstPassBytes > settings2.targetSizeBytes!) {
            final currentBitrate = JobPlanner.resolveVideoBitrateKbps(
              settings: settings2,
              media: media,
            );
            final ratio = settings2.targetSizeBytes! / firstPassBytes;
            final adjustedBitrate =
                (currentBitrate * ratio * 0.92).round().clamp(80, 100000);

            diag.section('target size retry');
            diag.line(
                'First pass output ($firstPassBytes bytes) exceeded target '
                '(${settings2.targetSizeBytes} bytes). Retrying once with '
                'adjusted bitrate $adjustedBitrate kbps (original: $currentBitrate kbps).');

            progress = const JobProgress(
              stageLabel: 'Refining target size',
              percent: 0.0,
            );
            notifyListeners();

            try {
              await outCheckFile.delete();
            } catch (_) {}

            final retrySettings =
                settings2.copyWith(targetBitrateKbps: adjustedBitrate);
            final retryPlan = JobPlanner.plan(
              settings: retrySettings,
              media: media,
              caps: FfmpegCapabilitiesLike.from(caps),
              sourcePath: sourcePath,
              outputPath: outputPath,
            );

            for (var i = 0; i < retryPlan.stages.length; i++) {
              final label = 'Refining size (pass 2)';
              final args = retryPlan.stages[i];
              diag.line('retry stage ${i + 1} args: ${args.join(' ')}');
              final result = await ffmpeg.run(
                args,
                stageLabel: label,
                totalDurationMs: totalMs,
                onProgress: _onProgress,
              );
              diag.line('retry stage ${i + 1} result: rc=${result.returnCode} '
                  'success=${result.isSuccess} cancelled=${result.cancelled}');
              if (_cancelled || result.cancelled) {
                await diag.discard();
                await _cleanup(jobId);
                status = JobStatus.cancelled;
                notifyListeners();
                return _record(sourceName, media, retrySettings, sw, jobId,
                    status: JobStatus.cancelled,
                    codec: _codecLabel(retrySettings,
                        sourceVideoCodec: inVideo?.codecName));
              }
              if (!result.isSuccess) {
                diag.line('retry stage failed: ${result.output}');
                throw mapFfmpegFailure(result,
                    hardwareWasUsed:
                        retrySettings.hardware != HardwarePreference.software);
              }
            }
            finalSettings = retrySettings;
          }
        }
      }

      // ---- verify (lossless modes) / integrity-check (lossy) ---------------
      if (plan.expectedVerification != VerificationExpectation.none) {
        progress = const JobProgress(stageLabel: 'Verifying losslessness');
        notifyListeners();
        verificationResult = await _verification.verifyDecodedEquality(
          sourcePath: sourcePath,
          outputPath: outputPath,
          totalDurationMs: totalMs,
          onProgress: _onProgress,
        );
        if (_cancelled) {
          await diag.discard();
          await _cleanup(jobId);
          status = JobStatus.cancelled;
          notifyListeners();
          return _record(sourceName, media, finalSettings, sw, jobId,
              status: JobStatus.cancelled, codec: _codecLabel(finalSettings));
        }
        diag.section('lossless verification');
        diag.line('completed=${verificationResult?.completed} '
            'videoIdentical=${verificationResult?.videoIdentical} '
            'audioIdentical=${verificationResult?.audioIdentical}');
        if (verificationResult?.detail != null) {
          diag.line(verificationResult!.detail!);
        }
      } else {
        // Lossy output: verify it is decodable and structurally intact.
        progress = const JobProgress(stageLabel: 'Checking output');
        notifyListeners();
        try {
          integrityResult = await _verification.verifyLossyIntegrity(
            source: media,
            outputPath: outputPath,
            expectedWidth: finalSettings.targetWidth,
            expectedHeight: finalSettings.targetHeight,
            expectAudio: media.audioStream != null &&
                finalSettings.audio != AudioAction.none,
          );
        } catch (_) {
          integrityResult = null; // integrity check itself must not fail the job
        }
        diag.section('output integrity check');
        diag.line(integrityResult == null
            ? 'check did not run (probe unavailable)'
            : 'ok=${integrityResult!.ok}: '
                '${integrityResult!.detail ?? 'all checks passed'}');
      }

      // ---- finalize --------------------------------------------------------
      final outputFile = File(outputPath);
      final outputExists = await outputFile.exists();
      final outputBytes = outputExists ? await outputFile.length() : 0;
      diag.section('output');
      diag.line('created=$outputExists bytes=$outputBytes path=$outputPath');
      if (!outputExists || outputBytes == 0) {
        throw const FfmpegException(
            FfmpegErrorKind.ioError, 'The output file was not created or is empty (0 bytes).');
      }

      String outputCodecLabel = _codecLabel(finalSettings, sourceVideoCodec: inVideo?.codecName);
      String? outPixFmt;
      String? outColorPrimaries;
      String? outColorTransfer;
      String? outColorSpace;
      int? outBitDepth;
      String? hdrStatus;

      try {
        final outProbe = await ffmpeg.probe(outputPath, fallbackSizeBytes: outputBytes);
        final probedVideo = outProbe.videoStream;
        final probedCodec = probedVideo?.codecName;
        if (probedCodec != null && probedCodec.isNotEmpty) {
          outputCodecLabel = _formatVerifiedCodec(finalSettings, probedCodec);
        }
        outPixFmt = probedVideo?.pixFmt;
        outColorPrimaries = probedVideo?.colorPrimaries;
        outColorTransfer = probedVideo?.colorTransfer;
        outColorSpace = probedVideo?.colorSpace;
        outBitDepth = probedVideo?.bitDepth;

        if (finalSettings.hdrMode == HdrMode.hdrEffect) {
          hdrStatus = 'HDR Effect (${(finalSettings.hdrIntensity * 100).round()}%)';
        } else if (probedVideo != null && probedVideo.isHdr) {
          final prim = probedVideo.colorPrimaries != null && probedVideo.colorPrimaries!.isNotEmpty
              ? probedVideo.colorPrimaries!
              : 'BT.2020';
          final trc = probedVideo.colorTransfer != null && probedVideo.colorTransfer!.isNotEmpty
              ? probedVideo.colorTransfer!
              : 'PQ';
          hdrStatus = 'HDR10 ($prim / $trc, ${outBitDepth ?? 10}-bit)';
        } else if (finalSettings.hdrMode == HdrMode.sdrToHdr) {
          hdrStatus = 'HDR10 (10-bit BT.2020)';
        } else {
          hdrStatus = (outBitDepth != null && outBitDepth > 8)
              ? '$outBitDepth-bit SDR'
              : 'SDR (8-bit)';
        }
      } catch (_) {}
      diag.line('verified output codec: $outputCodecLabel');
      if (hdrStatus != null) {
        diag.line('verified output HDR/color: $hdrStatus (pixFmt=$outPixFmt, prim=$outColorPrimaries, trc=$outColorTransfer, bitDepth=$outBitDepth)');
      }

      status = JobStatus.completed;
      lastRecord = _record(
        sourceName,
        media,
        finalSettings,
        sw,
        jobId,
        outputPath: outputPath,
        outputBytesOverride: outputBytes,
        codec: outputCodecLabel,
        verification: verificationResult,
        integrity: integrityResult,
        outputPixFmt: outPixFmt,
        outputColorPrimaries: outColorPrimaries,
        outputColorTransfer: outColorTransfer,
        outputColorSpace: outColorSpace,
        outputBitDepth: outBitDepth,
        hdrMode: finalSettings.hdrMode,
        hdrStatus: hdrStatus,
      );
      await jobRepository.add(lastRecord!);
      progress = const JobProgress(stageLabel: 'Done', percent: 1.0);
      // Normal finish: no diagnostics kept.
      await diag.discard();
      lastDiagnosticPath = null;
      notifyListeners();
      return lastRecord!;
    } on FfmpegException catch (e) {
      diag?.section('failure');
      diag?.line('kind: ${e.kind.name}');
      diag?.line('message: ${e.userMessage}');
      if (e.raw != null && e.raw!.isNotEmpty) {
        diag?.line('engine detail (tail):\n${_tail(e.raw!)}');
      }
      return _fail(
        sourceName: sourceName,
        media: media,
        settings: settings,
        sw: sw,
        jobId: jobId,
        error: e.kind == FfmpegErrorKind.unknown
            ? FfmpegException(e.kind,
                '${e.userMessage}\n\nDiagnostic ID: $jobId. You can share the '
                'diagnostic log for troubleshooting.',
                raw: e.raw)
            : e,
        errorCode: e.kind.name,
      );
    } on ArgumentError catch (e) {
      // Planner guard-rails state a real reason — surface it instead of the
      // generic "unexpectedly" message.
      diag?.section('failure');
      diag?.exception(e, StackTrace.current);
      return _fail(
        sourceName: sourceName,
        media: media,
        settings: settings,
        sw: sw,
        jobId: jobId,
        error: FfmpegException(
            FfmpegErrorKind.unknown,
            '${e.message}\n\nDiagnostic ID: $jobId. You can share the '
            'diagnostic log for troubleshooting.',
            raw: '$e'),
      );
    } catch (e, st) {
      diag?.section('failure');
      diag?.exception(e, st);
      return _fail(
        sourceName: sourceName,
        media: media,
        settings: settings,
        sw: sw,
        jobId: jobId,
        error: FfmpegException(
            FfmpegErrorKind.unknown,
            'Compression failed unexpectedly. Diagnostic ID: $jobId. You can '
            'share the diagnostic log for troubleshooting. The original file '
            'was not modified.',
            raw: '$e'),
      );
    }
  }

  /// Common failure bookkeeping: surface the error, remove the working dir
  /// (including any partial output), record the failed job.
  Future<JobRecord> _fail({
    required String sourceName,
    required MediaInfo media,
    required CompressionSettings settings,
    required Stopwatch sw,
    required String jobId,
    required FfmpegException error,
    String errorCode = 'unknown',
  }) async {
    this.error = error;
    status = JobStatus.failed;
    await _cleanup(jobId);
    lastRecord = _record(sourceName, media, settings, sw, jobId,
        status: JobStatus.failed,
        codec: _codecLabel(settings, sourceVideoCodec: media.videoStream?.codecName),
        errorCode: errorCode);
    await jobRepository.add(lastRecord!);
    notifyListeners();
    return lastRecord!;
  }

  /// Requests cancellation of the running encode.
  Future<void> cancel() async {
    _cancelled = true;
    progress = const JobProgress(stageLabel: 'Cancelling');
    notifyListeners();
    await ffmpeg.cancelActive();
  }

  /// In auto mode, a hardware encoder can be probed safely because the
  /// software encoder is the automatic fallback on failure. Returns settings
  /// unchanged for explicit choices.
  Future<CompressionSettings> _autoFallbackSettings(
      CompressionSettings settings, FfmpegCapabilities caps) async {
    if (settings.mode == CompressionMode.exactLossless ||
        settings.hardware != HardwarePreference.auto ||
        settings.videoCodec == VideoCodecOption.copySource ||
        settings.videoCodec == VideoCodecOption.av1) {
      return settings;
    }
    final hwOk = settings.videoCodec == VideoCodecOption.hevc
        ? caps.hevcHardware
        : caps.h264Hardware;
    final swOk = settings.videoCodec == VideoCodecOption.hevc
        ? caps.hevcSoftware
        : caps.h264Software;
    if (!hwOk && swOk) {
      return settings.copyWith(hardware: HardwarePreference.software);
    }
    return settings;
  }

  void _onProgress(JobProgress p) {
    progress = p;
    notifyListeners();
  }

  Future<void> _cleanup(String jobId) async {
    // Removes the working dir including any partial output.
    await tempManager.deleteJobDir(jobId);
  }

  JobRecord _record(
    String sourceName,
    MediaInfo media,
    CompressionSettings settings,
    Stopwatch sw,
    String jobId, {
    String? outputPath,
    int? outputBytesOverride,
    JobStatus status = JobStatus.completed,
    String codec = 'unknown',
    VerificationResult? verification,
    IntegrityResult? integrity,
    String? errorCode,
    String? outputPixFmt,
    String? outputColorPrimaries,
    String? outputColorTransfer,
    String? outputColorSpace,
    int? outputBitDepth,
    HdrMode? hdrMode,
    String? hdrStatus,
  }) {
    final record = JobRecord(
      id: jobId,
      createdAt: DateTime.now(),
      sourceName: sourceName,
      originalBytes: media.sizeBytes,
      outputBytes: outputPath != null ? (outputBytesOverride ?? 0) : 0,
      durationMs: sw.elapsedMilliseconds,
      mode: settings.mode,
      videoCodec: codec,
      outputPath: outputPath,
      status: status,
      verification: verification,
      integrity: integrity,
      errorCode: errorCode,
      outputPixFmt: outputPixFmt,
      outputColorPrimaries: outputColorPrimaries,
      outputColorTransfer: outputColorTransfer,
      outputColorSpace: outputColorSpace,
      outputBitDepth: outputBitDepth,
      hdrMode: hdrMode ?? settings.hdrMode,
      hdrStatus: hdrStatus,
    );
    lastRecord = record;
    return record;
  }

  /// Last [max] characters of engine console output — the interesting error
  /// is at the end, and the log has a size cap.
  static String _tail(String text, [int max = 16000]) =>
      text.length <= max ? text : '…${text.substring(text.length - max)}';

  static String _formatVerifiedCodec(CompressionSettings s, String probedCodec) {
    final upper = probedCodec.toUpperCase();
    if (s.mode == CompressionMode.exactLossless) {
      return switch (s.losslessEncoder) {
        LosslessEncoder.copy => '$upper (stream copy)',
        LosslessEncoder.x264 => '$upper (H.264 lossless)',
        LosslessEncoder.x265 => '$upper (HEVC lossless)',
        LosslessEncoder.av1 => '$upper (AV1 lossless)',
      };
    }
    if (s.videoCodec == VideoCodecOption.copySource) {
      return '$upper (stream copy)';
    }
    if (s.crf != null) {
      return '$upper CRF ${s.crf}';
    }
    final hw = s.hardware == HardwarePreference.software ? 'SW' : 'HW';
    return '$upper ($hw)';
  }

  static String _codecLabel(CompressionSettings s, {String? sourceVideoCodec}) {
    if (s.mode == CompressionMode.exactLossless) {
      return switch (s.losslessEncoder) {
        LosslessEncoder.copy => sourceVideoCodec != null
            ? '${sourceVideoCodec.toUpperCase()} (stream copy)'
            : 'stream copy',
        LosslessEncoder.x264 => 'H.264 lossless',
        LosslessEncoder.x265 => 'HEVC lossless',
        LosslessEncoder.av1 => 'AV1 lossless',
      };
    }
    final crf = s.crf != null ? ' CRF ${s.crf}' : '';
    return switch (s.videoCodec) {
      VideoCodecOption.hevc => 'HEVC$crf',
      VideoCodecOption.av1 => 'AV1$crf',
      VideoCodecOption.copySource => sourceVideoCodec != null
          ? '${sourceVideoCodec.toUpperCase()} (stream copy)'
          : 'stream copy',
      VideoCodecOption.h264 => s.hardware == HardwarePreference.software || s.crf != null
          ? 'H.264$crf (SW)'
          : 'H.264 (HW)',
    };
  }

  static int _mb(int bytes) => (bytes / (1024 * 1024)).ceil();
}
