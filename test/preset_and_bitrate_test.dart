import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pure_compress/models/models.dart';
import 'package:pure_compress/services/bitrate_calculator.dart';
import 'package:pure_compress/services/job_planner.dart';
import 'package:pure_compress/services/preset_repository.dart';
import 'package:pure_compress/services/settings_validator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BitrateCalculator', () {
    test('calculates video bitrate budget accounting for audio and muxing overhead', () {
      // 10 MB target, 60s duration, audio kept at 128 kbps
      const targetBytes = 10 * 1024 * 1024; // 10,485,760 bytes
      const durationSeconds = 60.0;

      final kbps = BitrateCalculator.calculateVideoBitrateKbps(
        targetSizeBytes: targetBytes,
        durationSeconds: durationSeconds,
        audioAction: AudioAction.copySource,
        sourceAudioBitrate: 128000,
        hasAudio: true,
      );

      // Total usable bytes = 10MB * 0.96 = 10,066,329 bytes
      // Audio bytes (128 kbps for 60s) = (128000 / 8) * 60 = 960,000 bytes
      // Video bytes = 10,066,329 - 960,000 = 9,106,329 bytes
      // Video bitrate = (9,106,329 * 8) / 60 / 1000 ≈ 1214 kbps
      expect(kbps, greaterThan(1150));
      expect(kbps, lessThan(1250));
    });

    test('allocates full budget to video when audio is removed', () {
      const targetBytes = 10 * 1024 * 1024;
      const durationSeconds = 60.0;

      final kbpsWithAudio = BitrateCalculator.calculateVideoBitrateKbps(
        targetSizeBytes: targetBytes,
        durationSeconds: durationSeconds,
        audioAction: AudioAction.copySource,
        sourceAudioBitrate: 128000,
        hasAudio: true,
      );

      final kbpsNoAudio = BitrateCalculator.calculateVideoBitrateKbps(
        targetSizeBytes: targetBytes,
        durationSeconds: durationSeconds,
        audioAction: AudioAction.none,
        hasAudio: false,
      );

      // When audio is stripped, video bitrate budget should be noticeably higher
      expect(kbpsNoAudio, greaterThan(kbpsWithAudio));
      // Total usable bytes = 10MB * 0.96 = 10,066,329 bytes
      // Video bitrate = (10,066,329 * 8) / 60 / 1000 ≈ 1342 kbps
      expect(kbpsNoAudio, closeTo(1342, 10));
    });

    test('clamps to floor for tiny impossible sizes without crashing', () {
      final kbps = BitrateCalculator.calculateVideoBitrateKbps(
        targetSizeBytes: 1000, // 1 KB target for 1 hour video
        durationSeconds: 3600.0,
        audioAction: AudioAction.copySource,
        sourceAudioBitrate: 128000,
        hasAudio: true,
      );
      expect(kbps, equals(100)); // Minimum clamped floor
    });

    test('estimateOutputBytes correctly estimates file size', () {
      final estimated = BitrateCalculator.estimateOutputBytes(
        videoBitrateKbps: 1000,
        durationSeconds: 60.0,
        audioAction: AudioAction.none,
        hasAudio: false,
      );
      // (1000 * 1000 / 8) * 60 * 1.02 ≈ 7,650,000 bytes (around 7.3 MB)
      expect(estimated, greaterThan(7000000));
      expect(estimated, lessThan(8000000));
    });
  });

  group('ResolutionPreset', () {
    test('4K landscape downscales to 1080p, 720p, 480p preserving aspect ratio', () {
      const sourceW = 3840;
      const sourceH = 2160;

      final p1080 = ResolutionPreset.p1080.calculateDimensions(sourceW, sourceH);
      expect(p1080, equals((1920, 1080)));

      final p720 = ResolutionPreset.p720.calculateDimensions(sourceW, sourceH);
      expect(p720, equals((1280, 720)));

      final p480 = ResolutionPreset.p480.calculateDimensions(sourceW, sourceH);
      expect(p480, equals((852, 480)));
    });

    test('portrait video (9:16) preserves orientation and aspect ratio', () {
      const sourceW = 1080;
      const sourceH = 1920;

      final p720 = ResolutionPreset.p720.calculateDimensions(sourceW, sourceH);
      expect(p720, equals((720, 1280)));
    });

    test('does not upscale smaller video to larger preset', () {
      const sourceW = 1280;
      const sourceH = 720;

      final p4k = ResolutionPreset.p4k.calculateDimensions(sourceW, sourceH);
      expect(p4k, equals((1280, 720)));

      final p1080 = ResolutionPreset.p1080.calculateDimensions(sourceW, sourceH);
      expect(p1080, equals((1280, 720)));
    });

    test('ensures even dimensions for odd-sized inputs', () {
      const sourceW = 1921;
      const sourceH = 1079;

      final dims = ResolutionPreset.p720.calculateDimensions(sourceW, sourceH);
      expect(dims.$1 % 2, equals(0));
      expect(dims.$2 % 2, equals(0));
    });
  });

  group('PresetRepository', () {
    late PresetRepository repo;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      repo = PresetRepository();
    });

    test('loads all built-in platform presets by default', () async {
      final presets = await repo.loadPresets();
      expect(presets.length, greaterThanOrEqualTo(9));

      final names = presets.map((p) => p.name).toList();
      expect(names, contains('GitHub'));
      expect(names, contains('Discord Free'));
      expect(names, contains('Email'));
      expect(names, contains('Discord Nitro Basic'));
      expect(names, contains('Messenger'));
      expect(names, contains('Discord Nitro'));
      expect(names, contains('X Standard'));
      expect(names, contains('WhatsApp / Telegram'));
      expect(names, contains('X Premium'));

      final github = presets.firstWhere((p) => p.name == 'GitHub');
      expect(github.targetSizeBytes, equals(10 * 1024 * 1024));
      expect(github.isBuiltIn, isTrue);
    });

    test('saves, persists, and retrieves custom preset', () async {
      const custom = CompressionPreset(
        id: 'custom_test_1',
        name: 'Custom 15MB',
        description: 'For testing',
        targetSizeBytes: 15 * 1024 * 1024,
        videoCodec: VideoCodecOption.h264,
        isBuiltIn: false,
      );

      await repo.saveCustomPreset(custom);

      final loaded = await repo.loadPresets();
      final found = loaded.where((p) => p.id == 'custom_test_1');
      expect(found, isNotEmpty);
      expect(found.first.name, equals('Custom 15MB'));
      expect(found.first.targetSizeBytes, equals(15 * 1024 * 1024));
    });

    test('updates existing custom preset with same id', () async {
      const custom = CompressionPreset(
        id: 'custom_test_1',
        name: 'Initial Name',
        targetSizeBytes: 10 * 1024 * 1024,
      );
      await repo.saveCustomPreset(custom);

      const updated = CompressionPreset(
        id: 'custom_test_1',
        name: 'Updated Name',
        targetSizeBytes: 12 * 1024 * 1024,
      );
      await repo.saveCustomPreset(updated);

      final loaded = await repo.loadPresets();
      final matches = loaded.where((p) => p.id == 'custom_test_1');
      expect(matches.length, equals(1));
      expect(matches.first.name, equals('Updated Name'));
      expect(matches.first.targetSizeBytes, equals(12 * 1024 * 1024));
    });

    test('deletes custom preset', () async {
      const custom = CompressionPreset(
        id: 'custom_to_delete',
        name: 'To Delete',
      );
      await repo.saveCustomPreset(custom);

      var loaded = await repo.loadPresets();
      expect(loaded.any((p) => p.id == 'custom_to_delete'), isTrue);

      final removed = await repo.deleteCustomPreset('custom_to_delete');
      expect(removed, isTrue);

      loaded = await repo.loadPresets();
      expect(loaded.any((p) => p.id == 'custom_to_delete'), isFalse);
    });

    test('resetToDefaults clears custom presets while keeping built-ins', () async {
      const custom = CompressionPreset(
        id: 'custom_clear_me',
        name: 'Temporary',
      );
      await repo.saveCustomPreset(custom);

      await repo.resetToDefaults();

      final loaded = await repo.loadPresets();
      expect(loaded.any((p) => p.id == 'custom_clear_me'), isFalse);
      expect(loaded.length, equals(CompressionPreset.builtInPresets.length));
    });
  });

  group('JobPlanner with target size budgeting', () {
    const caps = FfmpegCapabilitiesLike(
      h264Software: true,
      hevcSoftware: true,
      av1Software: true,
      h264Hardware: false,
      hevcHardware: false,
    );

    final media = MediaInfo(
      formatName: 'mov,mp4,m4a',
      durationSeconds: 30.0,
      sizeBytes: 50 * 1024 * 1024,
      bitRate: 14000000,
      streams: const [
        StreamInfo(
          index: 0,
          codecType: 'video',
          codecName: 'h264',
          width: 1920,
          height: 1080,
          frameRate: 30.0,
          bitRate: 13500000,
        ),
        StreamInfo(
          index: 1,
          codecType: 'audio',
          codecName: 'aac',
          bitRate: 128000,
        ),
      ],
      tags: const {},
    );

    test('generates bitrate rate-control args instead of CRF when targetSizeBytes is set', () {
      final settings = CompressionSettings(
        mode: CompressionMode.highEfficiency,
        videoCodec: VideoCodecOption.h264,
        targetSizeBytes: 10 * 1024 * 1024, // 10 MB target
        crf: 23, // should be overridden by targetSizeBytes
      );

      final plan = JobPlanner.plan(
        settings: settings,
        media: media,
        caps: caps,
        sourcePath: 'in.mp4',
        outputPath: 'out.mp4',
      );

      expect(plan.stages.length, equals(1));
      final args = plan.stages.first;

      // Rate control args must be present
      expect(args, contains('-b:v'));
      expect(args, contains('-maxrate'));
      expect(args, contains('-bufsize'));
      // CRF must NOT be present when targetSizeBytes is targeted
      expect(args.contains('-crf'), isFalse);
      expect(plan.description, contains('Target size encode'));
      expect(plan.description, contains('10.0 MB target'));
    });
  });

  group('SettingsValidator targetSizeBytes validation', () {
    const caps = FfmpegCapabilitiesLike(
      h264Software: true,
      hevcSoftware: true,
      av1Software: true,
      h264Hardware: false,
      hevcHardware: false,
    );

    final media = MediaInfo(
      formatName: 'mov,mp4,m4a',
      durationSeconds: 30.0,
      sizeBytes: 50 * 1024 * 1024,
      bitRate: 14000000,
      streams: const [
        StreamInfo(
          index: 0,
          codecType: 'video',
          codecName: 'h264',
          width: 1920,
          height: 1080,
          frameRate: 30.0,
        ),
      ],
      tags: const {},
    );

    test('rejects negative or zero target size', () {
      final v = SettingsValidator.validate(
        const CompressionSettings(
          mode: CompressionMode.highEfficiency,
          targetSizeBytes: 0,
        ),
        media,
        caps: caps,
      );
      expect(v.canStart, isFalse);
      expect(v.errors.any((e) => e.message.contains('greater than 0')), isTrue);
    });

    test('warns when target size is larger than or equal to source', () {
      final v = SettingsValidator.validate(
        const CompressionSettings(
          mode: CompressionMode.highEfficiency,
          targetSizeBytes: 60 * 1024 * 1024,
        ),
        media,
        caps: caps,
      );
      expect(v.canStart, isTrue);
      expect(v.warnings.any((w) => w.message.contains('not below the original')), isTrue);
    });

    test('exactLossless rejects targetSizeBytes', () {
      final v = SettingsValidator.validate(
        const CompressionSettings(
          mode: CompressionMode.exactLossless,
          targetSizeBytes: 10 * 1024 * 1024,
        ),
        media,
        caps: caps,
      );
      expect(v.canStart, isFalse);
    });
  });
}
