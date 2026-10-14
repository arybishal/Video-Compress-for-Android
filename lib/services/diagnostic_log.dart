import 'dart:io';

/// Append-only diagnostic log for one compression job: settings, source
/// facts, exact engine arguments, engine console output, return codes,
/// storage state and full exceptions with stack traces. One file per job,
/// kept only when the job does not finish normally (success and cancellation
/// discard it). Writing is best-effort — a logging failure must never break
/// the job it describes.
class DiagnosticLog {
  DiagnosticLog._(this.id, this.file);

  /// Job id; doubles as the user-facing diagnostic id in error messages.
  final String id;
  final File? file;

  static const _dirName = 'diagnostics';
  static const _keep = 5; // newest logs kept across runs
  static const _maxBytes = 256 * 1024; // cap per log so it stays shareable

  /// Opens (and rotates) the log for [jobId] under [base].
  static Future<DiagnosticLog> begin(Directory base, String jobId) async {
    File? file;
    try {
      final dir = Directory('${base.path}${Platform.pathSeparator}$_dirName');
      await dir.create(recursive: true);
      _rotate(dir);
      file = File('${dir.path}${Platform.pathSeparator}$jobId.log');
      await file.writeAsString('PureCompress diagnostics — $jobId\n'
          'started: ${DateTime.now().toIso8601String()}\n');
    } catch (_) {
      // Diagnostics must never block a job.
    }
    return DiagnosticLog._(jobId, file);
  }

  void section(String title) => _append('--- $title ---');

  void line(String text) => _append(redact(text));

  /// Records an unexpected error together with its full stack trace.
  void exception(Object error, StackTrace stack) =>
      _append('exception: ${error.runtimeType}: $error\nstack:\n$stack');

  /// Deletes the log — used when a job finishes or is cancelled normally.
  Future<void> discard() async {
    try {
      final f = file;
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Content URIs can carry document/account identifiers — strip them.
  static String redact(String text) =>
      text.replaceAll(RegExp("content://[^\\s'\"]+"), 'content://[redacted]');

  void _append(String text) {
    final f = file;
    if (f == null) return;
    try {
      if (f.lengthSync() >= _maxBytes) return;
      f.writeAsStringSync(
          '${DateTime.now().toIso8601String()}  $text\n',
          mode: FileMode.append);
    } catch (_) {}
  }

  static void _rotate(Directory dir) {
    try {
      final logs = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.log'))
          .toList()
        ..sort(
            (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      // Keep [_keep - 1] existing logs; the one about to be created makes [_keep].
      for (final old in logs.skip(_keep - 1)) {
        try {
          old.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
