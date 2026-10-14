import 'package:flutter_test/flutter_test.dart';
import 'package:pure_compress/models/models.dart';
import 'package:pure_compress/services/job_planner.dart';
import 'package:pure_compress/services/settings_validator.dart';

void main() {
  group('AspectRatioHelper & AspectRatioOption', () {
    test('calculates standard aspect ratio strings correctly', () {
      expect(AspectRatioHelper.formatAspectRatio(1920, 1080), equals('16:9'));
      expect(AspectRatioHelper.formatAspectRatio(1080, 1920), equals('9:16'));
      expect(AspectRatioHelper.formatAspectRatio(1080, 1080), equals('1:1'));
      expect(AspectRatioHelper.formatAspectRatio(1080, 1350), equals('4:5'));
      expect(AspectRatioHelper.formatAspectRatio(1280, 720), equals('16:9'));
      expect(AspectRatioHelper.formatAspectRatio(854, 480), equals('16:9'));
      expect(AspectRatioHelper.formatAspectRatio(640, 480), equals('4:3'));
    });

    test('calculates custom aspect ratio with GCD', () {
      expect(AspectRatioHelper.gcd(21, 9), equals(3));
      expect(AspectRatioHelper.formatAspectRatio(2100, 900), equals('21:9'));
      expect(AspectRatioHelper.formatAspectRatio(500, 300), equals('5:3'));
    });

    test('AspectRatioOption values have correct ratios', () {
      expect(AspectRatioOption.ar16_9.ratio, closeTo(16 / 9, 0.001));
      expect(AspectRatioOption.ar9_16.ratio, closeTo(9 / 16, 0.001));
      expect(AspectRatioOption.ar1_1.ratio, closeTo(1.0, 0.001));
      expect(AspectRatioOption.ar4_5.ratio, closeTo(4 / 5, 0.001));
      expect(AspectRatioOption.ar3_4.ratio, closeTo(3 / 4, 0.001));
      expect(AspectRatioOption.ar4_3.ratio, closeTo(4 / 3, 0.001));
      expect(AspectRatioOption.original.ratio, isNull);
      expect(AspectRatioOption.custom.ratio, isNull);
    });
  });

  group('ResolutionHelper.calculateGeometry', () {
    test('original aspect ratio with no target resolution produces no filters', () {
      final res = ResolutionHelper.calculateGeometry(
        sourceWidth: 1920,
        sourceHeight: 1080,
        aspectRatio: AspectRatioOption.original,
        fitPolicy: VideoFitPolicy.preserveOriginal,
      );

      expect(res.outputWidth, equals(1920));
      expect(res.outputHeight, equals(1080));
      expect(res.filters, isEmpty);
      expect(res.isPadded, isFalse);
      expect(res.isCropped, isFalse);
      expect(res.isStretched, isFalse);
    });

    test('fit with padding for 16:9 source into 9:16 target produces scale and pad filters', () {
      final res = ResolutionHelper.calculateGeometry(
        sourceWidth: 1920,
        sourceHeight: 1080,
        aspectRatio: AspectRatioOption.ar9_16,
        targetWidth: 1080,
        targetHeight: 1920,
        fitPolicy: VideoFitPolicy.fitPadding,
      );

      expect(res.outputWidth, equals(1080));
      expect(res.outputHeight, equals(1920));
      expect(res.isPadded, isTrue);
      expect(res.isCropped, isFalse);
      expect(res.isStretched, isFalse);
      expect(res.filters.length, equals(2));
      expect(res.filters[0], startsWith('scale=1080:'));
      expect(res.filters[1], startsWith('pad=1080:1920:'));
    });

    test('crop to fill for 16:9 source into 9:16 target produces scale and crop filters', () {
      final res = ResolutionHelper.calculateGeometry(
        sourceWidth: 1920,
        sourceHeight: 1080,
        aspectRatio: AspectRatioOption.ar9_16,
        targetWidth: 1080,
        targetHeight: 1920,
        fitPolicy: VideoFitPolicy.cropFill,
      );

      expect(res.outputWidth, equals(1080));
      expect(res.outputHeight, equals(1920));
      expect(res.isCropped, isTrue);
      expect(res.isPadded, isFalse);
      expect(res.isStretched, isFalse);
      expect(res.filters.length, equals(2));
      expect(res.filters[0], startsWith('scale='));
      expect(res.filters[1], startsWith('crop=1080:1920:'));
    });

    test('stretch to fill produces single scale filter and distortion warning', () {
      final res = ResolutionHelper.calculateGeometry(
        sourceWidth: 1920,
        sourceHeight: 1080,
        aspectRatio: AspectRatioOption.ar9_16,
        targetWidth: 1080,
        targetHeight: 1920,
        fitPolicy: VideoFitPolicy.stretch,
      );

      expect(res.outputWidth, equals(1080));
      expect(res.outputHeight, equals(1920));
      expect(res.isStretched, isTrue);
      expect(res.filters, equals(['scale=1080:1920']));
      expect(res.warning, contains('distort'));
    });

    test('guarantees strictly even dimensions for odd inputs', () {
      final res = ResolutionHelper.calculateGeometry(
        sourceWidth: 1921,
        sourceHeight: 1079,
        aspectRatio: AspectRatioOption.ar1_1,
        targetWidth: 1001,
        targetHeight: 1001,
        fitPolicy: VideoFitPolicy.fitPadding,
      );

      expect(res.outputWidth % 2, equals(0));
      expect(res.outputHeight % 2, equals(0));
    });

    test('warns when aspect ratio differs from resolution preset container', () {
      final res = ResolutionHelper.calculateGeometry(
        sourceWidth: 1920,
        sourceHeight: 1080,
        aspectRatio: AspectRatioOption.ar9_16, // 9:16 requested
        targetWidth: 1920, // but container is 16:9
        targetHeight: 1080,
        fitPolicy: VideoFitPolicy.fitPadding,
      );

      expect(res.warning, isNotNull);
      expect(res.warning, contains('differs from container resolution'));
    });
  });

  group('Social Media Presets', () {
    test('all 5 social media presets exist with 9:16 and 1080x1920 defaults', () {
      final presets = CompressionPreset.builtInPresets;
      final socialIds = [
        'builtin_tiktok',
        'builtin_instagram_reels',
        'builtin_youtube_shorts',
        'builtin_facebook_reels',
        'builtin_general_vertical',
      ];

      for (final id in socialIds) {
        final p = presets.firstWhere((preset) => preset.id == id);
        expect(p.targetWidth, equals(1080));
        expect(p.targetHeight, equals(1920));
        expect(p.aspectRatio, equals(AspectRatioOption.ar9_16));
        expect(p.fitPolicy, equals(VideoFitPolicy.fitPadding));
        expect(p.videoCodec, equals(VideoCodecOption.h264));
        expect(p.container, equals(ContainerOption.mp4));
      }
    });
  });

  group('SettingsValidator with Aspect Ratio & Fit Policy', () {
    final videoStream = StreamInfo(
      index: 0,
      codecType: 'video',
      codecName: 'h264',
      width: 1920,
      height: 1080,
      frameRate: 30.0,
      bitRate: 8000000,
    );
    final media = MediaInfo(
      formatName: 'mov,mp4,m4a,3gp,3g2,mj2',
      durationSeconds: 60.0,
      sizeBytes: 60 * 1024 * 1024,
      bitRate: 8000000,
      streams: [videoStream],
      tags: {},
    );

    test('exactLossless rejects modifying aspect ratio or fit policy', () {
      final s1 = const CompressionSettings(
        mode: CompressionMode.exactLossless,
        aspectRatio: AspectRatioOption.ar9_16,
      );
      final r1 = SettingsValidator.validate(s1, media);
      expect(r1.canStart, isFalse);
      expect(r1.errors.any((e) => e.message.contains('aspect ratio')), isTrue);

      final s2 = const CompressionSettings(
        mode: CompressionMode.exactLossless,
        fitPolicy: VideoFitPolicy.cropFill,
      );
      final r2 = SettingsValidator.validate(s2, media);
      expect(r2.canStart, isFalse);
      expect(r2.errors.any((e) => e.message.contains('crop, pad, or stretch')), isTrue);
    });

    test('custom stream copy rejects aspect ratio or fit policy', () {
      final s = const CompressionSettings(
        mode: CompressionMode.custom,
        videoCodec: VideoCodecOption.copySource,
        aspectRatio: AspectRatioOption.ar16_9,
        fitPolicy: VideoFitPolicy.fitPadding,
      );
      final r = SettingsValidator.validate(s, media);
      expect(r.canStart, isFalse);
      expect(r.errors.any((e) => e.message.contains('Stream copy (no re-encode)')), isTrue);
    });

    test('custom aspect ratio requires valid positive numbers', () {
      final s = const CompressionSettings(
        mode: CompressionMode.highEfficiency,
        aspectRatio: AspectRatioOption.custom,
        customAspectRatioWidth: null,
        customAspectRatioHeight: null,
      );
      final r = SettingsValidator.validate(s, media);
      expect(r.canStart, isFalse);
      expect(r.errors.any((e) => e.message.contains('Custom aspect ratio requires valid')), isTrue);
    });

    test('warns when using stretch or crop fit policy', () {
      final sStretch = const CompressionSettings(
        mode: CompressionMode.highEfficiency,
        fitPolicy: VideoFitPolicy.stretch,
      );
      final rStretch = SettingsValidator.validate(sStretch, media);
      expect(rStretch.canStart, isTrue);
      expect(rStretch.warnings.any((w) => w.message.contains('Stretch to Fill')), isTrue);

      final sCrop = const CompressionSettings(
        mode: CompressionMode.highEfficiency,
        fitPolicy: VideoFitPolicy.cropFill,
      );
      final rCrop = SettingsValidator.validate(sCrop, media);
      expect(rCrop.canStart, isTrue);
      expect(rCrop.warnings.any((w) => w.message.contains('Crop to Fill')), isTrue);
    });
  });

  group('JobPlanner geometry filter ordering & description', () {
    final videoStream = StreamInfo(
      index: 0,
      codecType: 'video',
      codecName: 'h264',
      width: 1920,
      height: 1080,
      frameRate: 60.0,
      bitRate: 10000000,
    );
    final media = MediaInfo(
      formatName: 'mov,mp4,m4a,3gp,3g2,mj2',
      durationSeconds: 30.0,
      sizeBytes: 37500000,
      bitRate: 10000000,
      streams: [videoStream],
      tags: {},
    );
    const caps = FfmpegCapabilitiesLike(
      h264Software: true,
      hevcSoftware: true,
      av1Software: true,
      h264Hardware: false,
      hevcHardware: false,
    );

    test('places geometry filters (scale/pad) before fps and color filters in -vf', () {
      final settings = const CompressionSettings(
        mode: CompressionMode.highEfficiency,
        videoCodec: VideoCodecOption.h264,
        aspectRatio: AspectRatioOption.ar9_16,
        targetWidth: 1080,
        targetHeight: 1920,
        fitPolicy: VideoFitPolicy.fitPadding,
        frameRate: 30.0,
        hdrMode: HdrMode.hdrEffect,
      );

      final plan = JobPlanner.plan(
        settings: settings,
        media: media,
        caps: caps,
        sourcePath: '/tmp/input.mp4',
        outputPath: '/tmp/output.mp4',
      );

      final args = plan.stages.first;
      final vfIndex = args.indexOf('-vf');
      expect(vfIndex, isNot(-1));

      final vfFilterString = args[vfIndex + 1];
      final filterList = vfFilterString.split(',');

      // Geometry filters scale & pad must be first
      expect(filterList[0], startsWith('scale='));
      expect(filterList[1], startsWith('pad='));
      // Framerate filter fps must follow geometry
      expect(filterList[2], equals('fps=30.0'));
      // HDR effect filter eq & unsharp must follow fps
      expect(filterList[3], startsWith('eq='));
      expect(filterList[4], startsWith('unsharp='));

      // Plan description includes geometry tag
      expect(plan.description, contains('1080×1920'));
      expect(plan.description, contains('9:16'));
    });
  });
}
