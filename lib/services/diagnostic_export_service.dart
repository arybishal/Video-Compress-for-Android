import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import '../config/app_config.dart';
import 'diagnostic_log.dart';
import 'ffmpeg_service.dart';
import 'job_repository.dart';
import 'native_exporter.dart';
import 'temp_manager.dart';

/// Centralized diagnostic export and logging service.
/// Collects system state, engine info, recent job history, and diagnostic logs.
/// Packages everything into a shareable ZIP bundle containing a human-readable
/// summary and structured JSON logs.
class DiagnosticExportService {
  DiagnosticExportService({
    required this.tempManager,
    required this.jobRepository,
    required this.ffmpeg,
    required this.exporter,
  });

  final TempManager tempManager;
  final JobRepository jobRepository;
  final FfmpegService ffmpeg;
  final NativeExporter exporter;

  /// Returns all available raw diagnostic log files.
  Future<List<File>> getDiagnosticFiles() async {
    try {
      final base = await tempManager.base();
      final dir = Directory('${base.path}${Platform.pathSeparator}diagnostics');
      if (!await dir.exists()) return [];
      return dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.log'))
          .toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    } catch (_) {
      return [];
    }
  }

  /// Clears all stored diagnostic logs without touching user history or videos.
  Future<int> clearLogs() async {
    var count = 0;
    try {
      final files = await getDiagnosticFiles();
      for (final f in files) {
        try {
          await f.delete();
          count++;
        } catch (_) {}
      }
    } catch (_) {}
    return count;
  }

  /// Gathers environment metadata, recent history, and creates a sanitized ZIP report.
  /// Returns the path to the generated zip file.
  Future<String> generateReport() async {
    final now = DateTime.now().toUtc();
    final timestamp = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';

    final base = await tempManager.base();
    final exportDir = Directory('${base.path}${Platform.pathSeparator}diagnostic_exports');
    await exportDir.create(recursive: true);

    final zipPath = '${exportDir.path}${Platform.pathSeparator}purecompress-diagnostics-$timestamp.zip';

    // 1. Collect environment details
    final freeSpace = await exporter.freeBytes();
    final notifPerm = await exporter.checkNotificationPermission();
    FfmpegCapabilities? caps;
    String? ffmpegVersion;
    try {
      final smoke = await ffmpeg.runSmokeVersion();
      if (smoke.isSuccess) {
        ffmpegVersion = smoke.output.split('\n').firstWhere(
              (l) => l.contains('ffmpeg version'),
              orElse: () => 'unknown',
            );
      }
      caps = await ffmpeg.detectCapabilities();
    } catch (_) {}

    // 2. Collect recent job records
    final history = await jobRepository.load();

    // 3. Collect diagnostic log contents
    final logFiles = await getDiagnosticFiles();
    final logsContent = <String, String>{};
    for (final f in logFiles) {
      final name = f.uri.pathSegments.last;
      try {
        final content = await f.readAsString();
        logsContent[name] = DiagnosticLog.redact(content);
      } catch (_) {}
    }

    // 4. Build human-readable summary
    final summaryBuffer = StringBuffer()
      ..writeln('=====================================================')
      ..writeln('           PURECOMPRESS DIAGNOSTIC REPORT            ')
      ..writeln('=====================================================')
      ..writeln('Generated At (UTC): ${now.toIso8601String()}')
      ..writeln('App Name: ${AppConfig.appName}')
      ..writeln('App Version: ${AppConfig.version}')
      ..writeln('OS Platform: ${Platform.operatingSystem} (${Platform.operatingSystemVersion})')
      ..writeln('Dart Version: ${Platform.version.split(' ').first}')
      ..writeln('Engine: FFmpegKit (Full GPL build)')
      ..writeln('Engine Version: ${ffmpegVersion ?? 'unavailable'}')
      ..writeln('Available Free Storage: ${freeSpace != null ? '${(freeSpace / (1024 * 1024)).toStringAsFixed(1)} MB' : 'unknown'}')
      ..writeln('Notification Permission: $notifPerm')
      ..writeln('')
      ..writeln('--- ENGINE CAPABILITIES ---')
      ..writeln('H.264 Software (libx264): ${caps?.h264Software ?? false}')
      ..writeln('HEVC Software (libx265): ${caps?.hevcSoftware ?? false}')
      ..writeln('AV1 libaom (libaom-av1): ${caps?.av1Libaom ?? false}')
      ..writeln('H.264 MediaCodec (HW): ${caps?.h264Hardware ?? false}')
      ..writeln('HEVC MediaCodec (HW): ${caps?.hevcHardware ?? false}')
      ..writeln('')
      ..writeln('--- RECENT JOB HISTORY (${history.length} records) ---');

    for (final job in history) {
      summaryBuffer
        ..writeln('• Job ID: ${job.id}')
        ..writeln('  Date: ${job.createdAt.toIso8601String()}')
        ..writeln('  Source Name: ${DiagnosticLog.redact(job.sourceName)}')
        ..writeln('  Original Size: ${(job.originalBytes / 1024 / 1024).toStringAsFixed(2)} MB')
        ..writeln('  Output Size: ${(job.outputBytes / 1024 / 1024).toStringAsFixed(2)} MB')
        ..writeln('  Saved: ${job.percentSaved.toStringAsFixed(1)}%')
        ..writeln('  Mode: ${job.mode.name} | Codec: ${job.videoCodec}')
        ..writeln('  Status: ${job.status.name}${job.errorCode != null ? ' (${job.errorCode})' : ''}')
        ..writeln('  Duration: ${(job.durationMs / 1000).toStringAsFixed(1)}s')
        ..writeln('');
    }

    summaryBuffer
      ..writeln('--- LOG FILES INCLUDED (${logsContent.length}) ---')
      ..writeln(logsContent.keys.join(', '));

    final summaryText = summaryBuffer.toString();

    // 5. Build structured JSON
    final jsonReport = {
      'reportGeneratedUtc': now.toIso8601String(),
      'app': {
        'name': AppConfig.appName,
        'version': AppConfig.version,
        'package': AppConfig.androidApplicationId,
      },
      'system': {
        'platform': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'freeStorageBytes': freeSpace,
        'notificationPermission': notifPerm,
      },
      'ffmpeg': {
        'version': ffmpegVersion,
        'capabilities': {
          'h264Software': caps?.h264Software,
          'hevcSoftware': caps?.hevcSoftware,
          'av1Libaom': caps?.av1Libaom,
          'h264Hardware': caps?.h264Hardware,
          'hevcHardware': caps?.hevcHardware,
        },
      },
      'history': history
          .map((j) => {
                'id': j.id,
                'createdAt': j.createdAt.toIso8601String(),
                'sourceName': DiagnosticLog.redact(j.sourceName),
                'originalBytes': j.originalBytes,
                'outputBytes': j.outputBytes,
                'durationMs': j.durationMs,
                'mode': j.mode.name,
                'videoCodec': j.videoCodec,
                'status': j.status.name,
                'errorCode': j.errorCode,
              })
          .toList(),
      'logs': logsContent,
    };

    // 6. Assemble ZIP archive
    final archive = Archive();
    final summaryBytes = utf8.encode(summaryText);
    archive.addFile(ArchiveFile('summary.txt', summaryBytes.length, summaryBytes));

    final jsonBytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(jsonReport));
    archive.addFile(ArchiveFile('diagnostics.json', jsonBytes.length, jsonBytes));

    for (final entry in logsContent.entries) {
      final bytes = utf8.encode(entry.value);
      archive.addFile(ArchiveFile('logs/${entry.key}', bytes.length, bytes));
    }

    final zipEncoder = ZipEncoder();
    final encodedZip = zipEncoder.encode(archive);
    final zipFile = File(zipPath);
    await zipFile.writeAsBytes(encodedZip);
    return zipPath;
  }
}
