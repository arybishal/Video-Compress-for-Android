import 'package:flutter_test/flutter_test.dart';
import 'package:pure_compress/models/models.dart';
import 'package:pure_compress/services/job_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late JobRepository repo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = JobRepository();
  });

  JobRecord record(String id, {int original = 100, int output = 50}) => JobRecord(
        id: id,
        createdAt: DateTime(2026, 10, 13, 12),
        sourceName: 'clip_$id.mp4',
        originalBytes: original,
        outputBytes: output,
        durationMs: 1234,
        mode: CompressionMode.highEfficiency,
        videoCodec: 'H.264 (hardware)',
        outputPath: '/tmp/x/out.mp4',
        verification: const VerificationResult(
          completed: true,
          videoIdentical: true,
          audioIdentical: true,
        ),
      );

  test('round-trips a record with verification', () async {
    await repo.add(record('a'));
    final all = await repo.load();
    expect(all, hasLength(1));
    final r = all.first;
    expect(r.id, 'a');
    expect(r.sourceName, 'clip_a.mp4');
    expect(r.originalBytes, 100);
    expect(r.outputBytes, 50);
    expect(r.mode, CompressionMode.highEfficiency);
    expect(r.verification!.fullyIdentical, isTrue);
    expect(r.percentSaved, closeTo(50.0, 0.001));
  });

  test('newest record comes first and list is capped', () async {
    for (var i = 0; i < 25; i++) {
      await repo.add(record('r$i'));
    }
    final all = await repo.load();
    expect(all, hasLength(20));
    expect(all.first.id, 'r24');
  });

  test('clear empties the history', () async {
    await repo.add(record('a'));
    await repo.clear();
    expect(await repo.load(), isEmpty);
  });

  test('corrupted storage yields empty history instead of crashing', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('job_history_v1', '{not json');
    expect(await repo.load(), isEmpty);
  });

  test('unknown enum values deserialize defensively', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('job_history_v1', '''
[{"id":"x","createdAt":"2026-10-13T00:00:00.000","sourceName":"a.mp4",
  "originalBytes":10,"outputBytes":5,"durationMs":1,
  "mode":"weird_mode","videoCodec":null,"status":"weird_status"}]
''');
    final all = await repo.load();
    expect(all.single.mode, CompressionMode.highEfficiency);
    expect(all.single.status, JobStatus.completed);
  });
}
