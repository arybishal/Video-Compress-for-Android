/// Small display formatting helpers.
String formatBytes(int bytes) {
  if (bytes < 0) return '-${formatBytes(-bytes)}';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var i = -1;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : value >= 10 ? 1 : 2)} ${units[i]}';
}

String formatDuration(double seconds) {
  if (seconds <= 0) return '0:00';
  final total = seconds.round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
}

String formatPercent(double p) {
  final sign = p > 0 ? '-' : p < 0 ? '+' : '';
  return '$sign${p.abs().toStringAsFixed(1)}%';
}

String formatEta(Duration d) {
  final s = d.inSeconds;
  if (s < 60) return '${s}s';
  return '${s ~/ 60}m ${s % 60}s';
}
