import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pure_compress/models/models.dart';
import 'package:pure_compress/services/compression_controller.dart';
import 'package:pure_compress/services/diagnostic_log.dart';
import 'package:pure_compress/services/ffmpeg_service.dart';
import 'package:pure_compress/services/job_repository.dart';
import 'package:pure_compress/services/native_exporter.dart';
import 'package:pure_compress/services/settings_validator.dart';
import 'package:pure_compress/services/temp_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String root =
      '${Directory.systemTemp.path}${Platform.pathSeparator}pc_diag_root';
  @override
  Future<String?> getTemporaryPath() async => root;
}

const _caps = FfmpegCapabilities(
  h264Software: true,
  hevcSoftware: true,
  av1Software: true,
  h264Hardware: true,
  hevcHardware: true,
  av1Libaom: true,
  av1SvtAv1: false,
);

MediaInfo _media() => MediaInfo(
      formatName: 'mov,mp4',
      durationSeconds: 60,
      sizeBytes: 60000000,
      bitRate: 8200000,
      streams: const [
        StreamInfo(
            index: 0,
            codecType: 'video',
            codecName: 'h264',
            width: 1920,
            height: 1080,
            pixFmt: 'yuv420p',
            frameRate: 30,
            bitRate: 8000000),
        StreamInfo(
            index: 1,
            codecType: 'audio',
            codecName: 'aac',
            sampleRate: 48000,
            channels: 2),
      ],
      tags: const {},
    );

/// Fake engine that fails every stage with a fixed result.
class _FailingFfmpeg extends FfmpegService {
  _FailingFfmpeg(this.result);
  final FfmpegResult result;

  @override
  Future<FfmpegCapabilities> detectCapabilities() async => _caps;

  @override
  Future<FfmpegResult> run(
    List<String> args, {
    required String stageLabel,
    double? totalDurationMs,
    void Function(JobProgress)? onProgress,
  }) async =>
      result;
}

/// Fake engine that throws a non-Ffmpeg Dart error mid-stage.
class _ThrowingFfmpeg extends FfmpegService {
  @override
  Future<FfmpegCapabilities> detectCapabilities() async => _caps;

  @override
  Future<FfmpegResult> run(
    List<String> args, {
    required String stageLabel,
    double? totalDurationMs,
    void Function(JobProgress)? onProgress,
  }) async =>
      throw StateError('simulated engine crash');
}

/// Fake engine that "encodes" by creating the output file.
class _SucceedingFfmpeg extends FfmpegService {
  @override
  Future<FfmpegCapabilities> detectCapabilities() async => _caps;

  // The integrity check tolerates a probe failure; keeping probe off the
  // real plugin here mirrors that path without needing a device binding.
  @override
  Future<MediaInfo> probe(String path, {int fallbackSizeBytes = 0}) async =>
      throw const FfmpegException(
          FfmpegErrorKind.corruptInput, 'probe unavailable in test');

  @override
  Future<FfmpegResult> run(
    List<String> args, {
    required String stageLabel,
    double? totalDurationMs,
    void Function(JobProgress)? onProgress,
  }) async {
    final out = File(args.last); // planner appends the output path last
    await out.parent.create(recursive: true);
    await out.writeAsString('fake encoded video');
    return const FfmpegResult(
        returnCode: 0,
        isSuccess: true,
        output: '',
        errorOutput: null,
        cancelled: false);
  }
}

void main() {
  group('session console merge (root cause of the generic error)', () {
    test('reproduces the reported generic message when no console was captured',
        () {
      final e = mapFfmpegFailure(const FfmpegResult(
          returnCode: 1,
          isSuccess: false,
          output: '',
          errorOutput: null,
          cancelled: false));
      expect(e.kind, FfmpegErrorKind.unknown);
      expect(e.userMessage,
          'Processing failed unexpectedly. The original file was not modified.');
    });

    test('the same failure maps to the real cause once logs are merged', () {
      final e = mapFfmpegFailure(const FfmpegResult(
          returnCode: 1,
          isSuccess: false,
          output: "Unknown encoder 'libx264'",
          errorOutput: null,
          cancelled: false));
      expect(e.kind, FfmpegErrorKind.unsupportedCodec);
      expect(e.userMessage, contains('not supported'));
    });

    test('mergeSessionText combines both ffmpeg-kit channels', () {
      expect(FfmpegService.mergeSessionText(null, null), '');
      expect(FfmpegService.mergeSessionText('', 'stderr text'), 'stderr text');
      expect(FfmpegService.mergeSessionText('stdout text', ''), 'stdout text');
      expect(FfmpegService.mergeSessionText('abc', 'abc'), 'abc');
      expect(
          FfmpegService.mergeSessionText('out', 'err'), 'out\nerr');
    });

    test('maps previously-unmapped engine failures to real causes', () {
      FfmpegResult r(String err) => FfmpegResult(
          returnCode: 1,
          isSuccess: false,
          output: err,
          errorOutput: null,
          cancelled: false);

      final pipe = mapFfmpegFailure(r('av_interleaved_write_frame(): Broken pipe'));
      expect(pipe.kind, FfmpegErrorKind.ioError);
      expect(pipe.userMessage, contains('output could not be written'));

      final oom = mapFfmpegFailure(r('av_malloc(): Cannot allocate memory'));
      expect(oom.kind, FfmpegErrorKind.outOfMemory);

      final input =
          mapFfmpegFailure(r('Error opening input files: Invalid argument'));
      expect(input.kind, FfmpegErrorKind.corruptInput);
    });
  });

  group('DiagnosticLog', () {
    late Directory base;

    setUp(() {
      base = Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}pc_diag_log')
        ..createSync(recursive: true);
    });

    tearDown(() {
      if (base.existsSync()) base.deleteSync(recursive: true);
    });

    test('captures sections, redacts content URIs, records exceptions',
        () async {
      final log = await DiagnosticLog.begin(base, 'job_alpha');
      expect(log.file, isNotNull);

      log.section('settings');
      log.line('picked content://com.android.documents/document/abc%2Fsecret.mp4');
      log.exception(StateError('boom'), StackTrace.current);

      final text = log.file!.readAsStringSync();
      expect(text, contains('PureCompress diagnostics — job_alpha'));
      expect(text, contains('--- settings ---'));
      expect(text, isNot(contains('abc%2Fsecret')));
      expect(text, contains('content://[redacted]'));
      expect(text, contains('StateError: Bad state: boom'));
      expect(text, contains('stack:'));
    });

    test('rotation keeps only the newest logs', () async {
      for (var i = 1; i <= 7; i++) {
        final log = await DiagnosticLog.begin(base, 'job_$i');
        // Explicit timestamps so rotation order is deterministic.
        await log.file!.setLastModified(DateTime(2026, 1, i));
      }
      final dir = Directory('${base.path}${Platform.pathSeparator}diagnostics');
      final kept = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.log'))
          .toList();
      expect(kept, hasLength(5));
      expect(kept.map((f) => f.path).join('\n'), contains('job_7'));
      expect(kept.map((f) => f.path).join('\n'), isNot(contains('job_1')));
    });

    test('discard deletes the log', () async {
      final log = await DiagnosticLog.begin(base, 'job_del');
      expect(log.file!.existsSync(), isTrue);
      await log.discard();
      expect(log.file!.existsSync(), isFalse);
    });
  });

  group('encoder availability gating', () {
    const noCaps = FfmpegCapabilitiesLike(
        h264Software: false,
        hevcSoftware: false,
        av1Software: false,
        h264Hardware: false,
        hevcHardware: false);
    const swOnly = FfmpegCapabilitiesLike(
        h264Software: true,
        hevcSoftware: true,
        av1Software: true,
        h264Hardware: false,
        hevcHardware: false);

    test('CRF mode is blocked when the software encoder is missing', () {
      final r = SettingsValidator.validate(
          const CompressionSettings(mode: CompressionMode.highEfficiency, crf: 23),
          _media(),
          caps: noCaps);
      expect(r.canStart, isFalse,
          reason: 'a CRF job without libx264 would always fail');
      expect(r.errors.map((e) => e.message).join('\n'), contains('H.264'));
    });

    test('CRF mode runs when the software encoder exists', () {
      final r = SettingsValidator.validate(
          const CompressionSettings(mode: CompressionMode.highEfficiency, crf: 23),
          _media(),
          caps: swOnly);
      expect(r.canStart, isTrue);
    });

    test('auto mode allows the software fallback when hardware is missing',
        () {
      final r = SettingsValidator.validate(
          const CompressionSettings(mode: CompressionMode.custom),
          _media(),
          caps: swOnly);
      expect(r.canStart, isTrue);
    });

    test('forced hardware without a hardware encoder is blocked', () {
      final r = SettingsValidator.validate(
          const CompressionSettings(
              mode: CompressionMode.custom,
              hardware: HardwarePreference.hardware),
          _media(),
          caps: swOnly);
      expect(r.canStart, isFalse);
      expect(r.errors.map((e) => e.message).join('\n'),
          contains('Hardware encoding is not available'));
    });
  });

  group('controller diagnostics', () {
    late Directory sandbox;
    late TempManager tm;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      PathProviderPlatform.instance = _FakePathProvider();
      tm = TempManager();
    });

    tearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    CompressionController controller(FfmpegService ffmpeg) =>
        CompressionController(
          ffmpeg: ffmpeg,
          tempManager: tm,
          jobRepository: JobRepository(),
          exporter: NativeExporter(),
        );

    test('engine failure keeps a diagnostic log and shows the real cause',
        () async {
      sandbox = await tm.base();
      final ffmpeg = _FailingFfmpeg(const FfmpegResult(
          returnCode: 1,
          isSuccess: false,
          output: "Unknown encoder 'libx264'",
          errorOutput: null,
          cancelled: false));
      final c = controller(ffmpeg);

      final record = await c.run(
        sourcePath: '/in.mp4',
        sourceName: 'clip.mp4',
        media: _media(),
        settings: const CompressionSettings(
            mode: CompressionMode.highEfficiency, crf: 23),
      );

      expect(record.status, JobStatus.failed);
      expect(record.errorCode, 'unsupportedCodec');
      expect(c.error!.userMessage, contains('not supported'));
      expect(c.error!.userMessage, isNot(contains('failed unexpectedly')));

      // The diagnostic log holds the full debugging trail.
      expect(c.lastDiagnosticId, record.id);
      final log = File(c.lastDiagnosticPath!).readAsStringSync();
      expect(log, contains('--- source & settings ---'));
      expect(log, contains('mode=highEfficiency'));
      expect(log, contains('stage 1 args:'));
      expect(log, contains("Unknown encoder 'libx264'"));
      expect(log, contains('rc=1'));
      expect(log, contains('kind: unsupportedCodec'));

      // Working dir removed; source untouched.
      final jobs = sandbox
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.contains('job_'));
      expect(jobs, isEmpty);
    });

    test('unexpected engine exceptions record the stack and a diagnostic id',
        () async {
      sandbox = await tm.base();
      final c = controller(_ThrowingFfmpeg());

      final record = await c.run(
        sourcePath: '/in.mp4',
        sourceName: 'clip.mp4',
        media: _media(),
        settings: const CompressionSettings(
            mode: CompressionMode.highEfficiency, crf: 23),
      );

      expect(record.status, JobStatus.failed);
      expect(record.errorCode, 'unknown');
      expect(c.error!.userMessage, contains('Diagnostic ID: ${record.id}'));
      expect(c.error!.userMessage, contains('original file was not modified'));

      final log = File(c.lastDiagnosticPath!).readAsStringSync();
      expect(log, contains('--- failure ---'));
      expect(log, contains('StateError: Bad state: simulated engine crash'));
      expect(log, contains('stack:'));
    });

    test('a successful job leaves no diagnostic log', () async {
      sandbox = await tm.base();
      final c = controller(_SucceedingFfmpeg());

      final record = await c.run(
        sourcePath: '/in.mp4',
        sourceName: 'clip.mp4',
        media: _media(),
        settings: const CompressionSettings(
            mode: CompressionMode.highEfficiency, crf: 23),
      );

      expect(record.status, JobStatus.completed);
      expect(c.lastDiagnosticPath, isNull);
      final diagDir = Directory('${sandbox.path}${Platform.pathSeparator}diagnostics');
      if (diagDir.existsSync()) {
        final kept = diagDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.contains(record.id));
        expect(kept, isEmpty, reason: 'success discards its log');
      }
    });
  });
}
