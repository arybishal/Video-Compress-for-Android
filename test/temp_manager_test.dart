import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pure_compress/config/app_config.dart';
import 'package:pure_compress/services/temp_manager.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String root =
      '${Directory.systemTemp.path}${Platform.pathSeparator}pc_test_root';
  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  late Directory sandbox;
  late TempManager tm;

  setUp(() async {
    PathProviderPlatform.instance = _FakePathProvider();
    tm = TempManager();
    final base = await tm.base();
    sandbox = base;
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('job ids are unique', () {
    final ids = {for (var i = 0; i < 100; i++) TempManager.newJobId()};
    expect(ids, hasLength(100));
    expect(ids.first, startsWith('job_'));
  });

  test('createJobDir makes a real directory and delete removes it', () async {
    final dir = await tm.createJobDir('job_test1');
    expect(await dir.exists(), isTrue);
    await tm.deleteJobDir('job_test1');
    expect(await dir.exists(), isFalse);
  });

  test('deleteJobDir on missing dir is a no-op', () async {
    await tm.deleteJobDir('never_existed'); // must not throw
  });

  test('cleanupOrphans removes stale dirs and keeps fresh ones', () async {
    await tm.createJobDir('job_a');
    await tm.createJobDir('job_b');
    // Fresh dirs survive a normal sweep.
    expect(await tm.cleanupOrphans(), 0);
    // With a simulated clock past the max age, both are reclaimed.
    final future = DateTime.now().add(AppConfig.tempMaxAge + const Duration(hours: 1));
    expect(await tm.cleanupOrphans(now: future), 2);
    expect(
      await Directory('${sandbox.path}${Platform.pathSeparator}job_a').exists(),
      isFalse,
    );
  });
}
