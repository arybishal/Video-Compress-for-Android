import 'package:flutter_test/flutter_test.dart';
import 'package:pure_compress/models/models.dart';
import 'package:pure_compress/ui/format.dart';

void main() {
  group('SizeStats', () {
    test('positive savings', () {
      expect(SizeStats.bytesDelta(1000, 400), 600);
      expect(SizeStats.percentSaved(1000, 400), closeTo(60.0, 0.001));
    });

    test('negative savings (output larger) are reported honestly', () {
      expect(SizeStats.bytesDelta(1000, 1500), -500);
      expect(SizeStats.percentSaved(1000, 1500), closeTo(-50.0, 0.001));
    });

    test('zero-sized original does not divide by zero', () {
      expect(SizeStats.percentSaved(0, 100), 0);
    });

    test('identical size is 0%', () {
      expect(SizeStats.percentSaved(5000, 5000), 0);
    });
  });

  group('JobRecord derived values', () {
    test('percentSaved can be negative', () {
      final r = JobRecord(
        id: 'j',
        createdAt: DateTime(2026, 1, 1),
        sourceName: 'a.mp4',
        originalBytes: 2000,
        outputBytes: 3000,
        durationMs: 1000,
        mode: CompressionMode.exactLossless,
        videoCodec: 'stream copy',
      );
      expect(r.bytesDelta, -1000);
      expect(r.percentSaved, closeTo(-50.0, 0.001));
    });
  });

  group('display formatting', () {
    test('formatBytes', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(999), '999 B');
      expect(formatBytes(1024), '1.00 KB');
      expect(formatBytes(1024 * 1024 * 5), '5.00 MB');
      expect(formatBytes(-(1024 * 1024)), '-1.00 MB');
    });

    test('formatDuration', () {
      expect(formatDuration(0), '0:00');
      expect(formatDuration(65), '1:05');
      expect(formatDuration(3661), '1:01:01');
    });

    test('formatPercent marks negative savings with +', () {
      expect(formatPercent(60), '-60.0%');
      expect(formatPercent(-25), '+25.0%');
    });
  });
}
