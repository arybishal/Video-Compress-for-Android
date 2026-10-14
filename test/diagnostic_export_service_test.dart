import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pure_compress/models/models.dart';
import 'package:pure_compress/services/diagnostic_export_service.dart';
import 'package:pure_compress/services/diagnostic_log.dart';
import 'package:pure_compress/services/ffmpeg_service.dart';
import 'package:pure_compress/services/job_repository.dart';
import 'package:pure_compress/services/native_exporter.dart';
import 'package:pure_compress/services/temp_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String root =
      '${Directory.systemTemp.path}${Platform.pathSeparator}pc_diag_export_test';
  @override
  Future<String?> getTemporaryPath() async => root;
}

class _DummyFfmpeg extends FfmpegService {
  @override
  Future<FfmpegCapabilities> detectCapabilities() async =>
      const FfmpegCapabilities(
        h264Software: true,
        hevcSoftware: true,
        av1Software: true,
        h264Hardware: true,
        hevcHardware: true,
        av1Libaom: true,
        av1SvtAv1: false,
      );

  @override
  Future<FfmpegResult> runSmokeVersion() async => const FfmpegResult(
        returnCode: 0,
        isSuccess: true,
        output: 'ffmpeg version 8.0.0-full-gpl Copyright (c) 2000-2026',
        errorOutput: null,
        sessionId: 101,
        sessionState: 'COMPLETED',
        cancelled: false,
      );
}

class _DummyExporter extends NativeExporter {
  @override
  Future<int?> freeBytes() async => 1024 * 1024 * 500; // 500 MB

  @override
  Future<String> checkNotificationPermission() async => 'granted';
}

void main() {
  late Directory sandbox;
  late TempManager tm;
  late JobRepository repo;
  late DiagnosticExportService exportService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PathProviderPlatform.instance = _FakePathProvider();
    tm = TempManager();
    sandbox = await tm.base();
    repo = JobRepository();
    exportService = DiagnosticExportService(
      tempManager: tm,
      jobRepository: repo,
      ffmpeg: _DummyFfmpeg(),
      exporter: _DummyExporter(),
    );
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  test('generateReport bundles summary, json metadata, and raw logs into a ZIP',
      () async {
    // 1. Create a simulated diagnostic log
    final log = await DiagnosticLog.begin(sandbox, 'job_test_123');
    log.section('test_section');
    log.line('testing content://com.example.secret/path/video.mp4');
    log.line('engine return code: 1');

    // 2. Add a sample job record
    await repo.add(JobRecord(
      id: 'job_test_123',
      createdAt: DateTime.now(),
      sourceName: 'clip.mp4',
      originalBytes: 1000000,
      outputBytes: 800000,
      durationMs: 5000,
      mode: CompressionMode.highEfficiency,
      videoCodec: 'hevc',
      status: JobStatus.completed,
    ));

    // 3. Generate diagnostic report
    final zipPath = await exportService.generateReport();
    expect(zipPath, endsWith('.zip'));
    final zipFile = File(zipPath);
    expect(await zipFile.exists(), isTrue);
    expect(await zipFile.length(), greaterThan(0));

    // Verify file listing
    final files = await exportService.getDiagnosticFiles();
    expect(files, hasLength(1));
    expect(files.first.path, contains('job_test_123'));
  });

  test('clearLogs removes diagnostic logs without touching job records',
      () async {
    await DiagnosticLog.begin(sandbox, 'job_a');
    await DiagnosticLog.begin(sandbox, 'job_b');

    await repo.add(JobRecord(
      id: 'job_kept',
      createdAt: DateTime.now(),
      sourceName: 'saved.mp4',
      originalBytes: 50000,
      outputBytes: 40000,
      durationMs: 2000,
      mode: CompressionMode.exactLossless,
      videoCodec: 'h264',
    ));

    final count = await exportService.clearLogs();
    expect(count, equals(2));

    final remaining = await exportService.getDiagnosticFiles();
    expect(remaining, isEmpty);

    final history = await repo.load();
    expect(history, hasLength(1));
    expect(history.first.id, equals('job_kept'));
  });
}
