import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';

/// Creates unique per-job working directories inside the app cache and
/// cleans up leftovers. Originals are never touched.
class TempManager {
  Directory? _base;

  Future<Directory> base() async {
    if (_base != null) return _base!;
    final cache = await getTemporaryDirectory();
    final dir = Directory('${cache.path}${Platform.pathSeparator}${AppConfig.tempDirName}');
    if (!await dir.exists()) await dir.create(recursive: true);
    _base = dir;
    return dir;
  }

  /// Creates a fresh, uniquely named working directory for one job.
  Future<Directory> createJobDir(String jobId) async {
    final b = await base();
    final dir = Directory('${b.path}${Platform.pathSeparator}$jobId');
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> deleteJobDir(String jobId) async {
    final b = await base();
    final dir = Directory('${b.path}${Platform.pathSeparator}$jobId');
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// Removes job directories older than [AppConfig.tempMaxAge]. Called at
  /// startup: reclaims interrupted or never-exported jobs without ever
  /// touching user files outside the app cache.
  Future<int> cleanupOrphans({DateTime? now}) async {
    final b = await base();
    final cutoff = (now ?? DateTime.now()).subtract(AppConfig.tempMaxAge);
    var removed = 0;
    await for (final e in b.list()) {
      if (e is! Directory) continue;
      try {
        final stat = await e.stat();
        if (stat.modified.isBefore(cutoff)) {
          await e.delete(recursive: true);
          removed++;
        }
      } catch (_) {}
    }
    return removed;
  }

  /// Removes old SAF-picked input copies from the cache. Sources live only
  /// as cache copies while in use; stale copies are reclaimable.
  Future<void> cleanupPickedInputs({DateTime? now}) async {
    try {
      final cache = await getTemporaryDirectory();
      final dir = Directory(
          '${cache.path}${Platform.pathSeparator}${AppConfig.pickDirName}');
      if (!await dir.exists()) return;
      final cutoff =
          (now ?? DateTime.now()).subtract(AppConfig.tempMaxAge);
      await for (final e in dir.list()) {
        if (e is! File) continue;
        try {
          final stat = await e.stat();
          if (stat.modified.isBefore(cutoff)) await e.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  static int _seq = 0;

  /// Time-based id plus a process-local counter so ids stay unique even when
  /// created within the same clock tick.
  static String newJobId() {
    final now = DateTime.now();
    final rand = now.microsecondsSinceEpoch.toRadixString(36);
    return 'job_$rand${(_seq++).toRadixString(36)}';
  }
}
