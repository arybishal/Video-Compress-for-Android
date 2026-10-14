import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pure_compress/models/models.dart';
import 'package:pure_compress/services/compression_controller.dart';
import 'package:pure_compress/services/ffmpeg_service.dart';
import 'package:pure_compress/services/job_repository.dart';
import 'package:pure_compress/services/native_exporter.dart';
import 'package:pure_compress/services/temp_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String root =
      '${Directory.systemTemp.path}${Platform.pathSeparator}pc_ctrl_root';
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

/// FFmpeg fake that blocks inside run() until cancelActive() is called —
/// simulating a long encode interrupted by the user.
class _BlockingFfmpeg extends FfmpegService {
  final started = Completer<void>();
  final _gate = Completer<FfmpegResult>();
  bool cancelRequested = false;

  @override
  Future<FfmpegCapabilities> detectCapabilities() async => _caps;

  @override
  Future<FfmpegResult> run(
    List<String> args, {
    required String stageLabel,
    double? totalDurationMs,
    void Function(JobProgress)? onProgress,
  }) {
    started.complete();
    return _gate.future;
  }

  @override
  Future<void> cancelActive() async {
    cancelRequested = true;
    if (!_gate.isCompleted) {
      _gate.complete(const FfmpegResult(
        returnCode: 255,
        isSuccess: false,
        output: '',
        errorOutput: null,
        cancelled: true,
      ));
    }
  }
}

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

void main() {
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

  test('cancelling mid-encode cleans up and records the cancellation',
      () async {
    sandbox = await tm.base();
    final ffmpeg = _BlockingFfmpeg();
    final controller = CompressionController(
      ffmpeg: ffmpeg,
      tempManager: tm,
      jobRepository: JobRepository(),
      exporter: NativeExporter(),
    );

    final future = controller.run(
      sourcePath: '/in.mp4',
      sourceName: 'clip.mp4',
      media: _media(),
      settings: const CompressionSettings(
          mode: CompressionMode.highEfficiency, crf: 23),
    );

    // The encode stage is now running (job dir created, ffmpeg "started").
    await ffmpeg.started.future;
    final jobDirs = sandbox
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.contains('job_'))
        .toList();
    expect(jobDirs, hasLength(1), reason: 'working dir exists mid-job');

    await controller.cancel();
    final record = await future;

    expect(record.status, JobStatus.cancelled);
    expect(ffmpeg.cancelRequested, isTrue);
    expect(controller.status, JobStatus.cancelled);
    // Partial output + working dir are gone; the source was never touched.
    final left = sandbox
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.contains('job_'))
        .toList();
    expect(left, isEmpty, reason: 'job dir cleaned up after cancel');
  });

  test('cancellation before ffmpeg starts is still handled', () async {
    sandbox = await tm.base();
    final ffmpeg = _BlockingFfmpeg();
    final controller = CompressionController(
      ffmpeg: ffmpeg,
      tempManager: tm,
      jobRepository: JobRepository(),
      exporter: NativeExporter(),
    );
    final future = controller.run(
      sourcePath: '/in.mp4',
      sourceName: 'clip.mp4',
      media: _media(),
      settings: const CompressionSettings(
          mode: CompressionMode.highEfficiency, crf: 23),
    );
    await controller.cancel(); // before started completes
    await ffmpeg.started.future;
    final record = await future;
    expect(record.status, JobStatus.cancelled);
  });
}
