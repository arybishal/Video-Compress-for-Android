// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pure_compress/models/models.dart';
import 'package:pure_compress/services/compression_controller.dart';
import 'package:pure_compress/services/ffmpeg_service.dart';
import 'package:pure_compress/services/job_repository.dart';
import 'package:pure_compress/services/native_exporter.dart';
import 'package:pure_compress/services/temp_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final ffmpeg = FfmpegService();
  final tempManager = TempManager();
  final jobRepo = JobRepository();
  final exporter = NativeExporter();

  testWidgets('Smoke test 1: engine version check', (tester) async {
    final versionResult = await ffmpeg.runSmokeVersion();
    print('SMOKE TEST 1: version=${versionResult.returnCode}, success=${versionResult.isSuccess}');
    expect(versionResult.isSuccess, isTrue, reason: 'Smoke version should succeed');
    expect(versionResult.returnCode, equals(0));
    expect(versionResult.sessionId, isNotNull);
    expect(versionResult.output, contains('ffmpeg version'));
  });

  testWidgets('Smoke test 2: probe video in app private cache', (tester) async {
    final tempDir = await tempManager.base();
    final cachedInputPath = '${tempDir.parent.path}${Platform.pathSeparator}test_input.mp4';
    print('SMOKE TEST 2 checking path: $cachedInputPath');
    final file = File(cachedInputPath);
    expect(await file.exists(), isTrue, reason: 'Source file in private cache should exist');

    final media = await ffmpeg.probe(cachedInputPath);
    print('SMOKE TEST 2: probed video codec=${media.videoStream?.codecName}, res=${media.videoStream?.width}x${media.videoStream?.height}');
    expect(media.videoStream!.codecName, equals('hevc'));
    expect(media.videoStream!.width, equals(3840));
    expect(media.videoStream!.height, equals(2160));
  });

  testWidgets('Smoke test 3: Exact Lossless stream copy', (tester) async {
    final tempDir = await tempManager.base();
    final cachedInputPath = '${tempDir.parent.path}${Platform.pathSeparator}test_input.mp4';
    final media = await ffmpeg.probe(cachedInputPath);

    final controller = CompressionController(
      ffmpeg: ffmpeg,
      tempManager: tempManager,
      jobRepository: jobRepo,
      exporter: exporter,
    );

    const settings = CompressionSettings(
      mode: CompressionMode.exactLossless,
      videoCodec: VideoCodecOption.h264,
      losslessEncoder: LosslessEncoder.copy,
      audio: AudioAction.copySource,
      container: ContainerOption.mp4,
      hardware: HardwarePreference.auto,
      keepMetadata: true,
    );

    final record = await controller.run(
      sourcePath: cachedInputPath,
      sourceName: 'test_input.mp4',
      media: media,
      settings: settings,
    );

    print('SMOKE TEST 3: status=${record.status}, outPath=${record.outputPath}, err=${record.errorCode}');
    expect(record.status, equals(JobStatus.completed),
        reason: 'Job should complete successfully: ${record.errorCode}');
    expect(record.outputPath, isNotNull);
    final outFile = File(record.outputPath!);
    expect(await outFile.exists(), isTrue);
    expect(await outFile.length(), greaterThan(0));

    print('SMOKE TEST 3: output size=${await outFile.length()} bytes');

    // Verify output stream is HEVC (preserved stream copy, not re-encoded)
    final outMedia = await ffmpeg.probe(record.outputPath!);
    print('SMOKE TEST 3: outMedia codec=${outMedia.videoStream?.codecName}, res=${outMedia.videoStream?.width}x${outMedia.videoStream?.height}');
    expect(outMedia.videoStream!.codecName, equals('hevc'));
    expect(outMedia.videoStream!.width, equals(3840));
    expect(outMedia.videoStream!.height, equals(2160));
    expect(record.videoCodec.toLowerCase(), contains('hevc'));
  });
}
