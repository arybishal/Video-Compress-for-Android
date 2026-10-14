import 'package:flutter_test/flutter_test.dart';
import 'package:pure_compress/models/models.dart';
import 'package:pure_compress/services/bitrate_calculator.dart';
import 'package:pure_compress/services/job_planner.dart';
import 'package:pure_compress/services/job_repository.dart';
import 'package:pure_compress/services/settings_validator.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const capsFull = FfmpegCapabilitiesLike(
    h264Software: true,
    hevcSoftware: true,
    av1Software: true,
    h264Hardware: true,
    hevcHardware: true,
    av1Libaom: true,
  );

  MediaInfo makeSdrMedia() => const MediaInfo(
        formatName: 'mov,mp4,m4a,3gp,3g2,mj2',
        durationSeconds: 60.0,
        sizeBytes: 100 * 1024 * 1024,
        bitRate: 13333333,
        streams: [
          StreamInfo(
            index: 0,
            codecType: 'video',
            codecName: 'h264',
            width: 1920,
            height: 1080,
            pixFmt: 'yuv420p',
            frameRate: 30.0,
            colorSpace: 'bt709',
            colorTransfer: 'bt709',
            colorPrimaries: 'bt709',
          ),
          StreamInfo(
            index: 1,
            codecType: 'audio',
            codecName: 'aac',
            sampleRate: 48000,
            channels: 2,
            bitRate: 128000,
          ),
        ],
        tags: {},
      );

  MediaInfo makeHdrMedia() => const MediaInfo(
        formatName: 'mov,mp4,m4a,3gp,3g2,mj2',
        durationSeconds: 30.0,
        sizeBytes: 200 * 1024 * 1024,
        bitRate: 53333333,
        streams: [
          StreamInfo(
            index: 0,
            codecType: 'video',
            codecName: 'hevc',
            width: 3840,
            height: 2160,
            pixFmt: 'yuv420p10le',
            frameRate: 60.0,
            colorSpace: 'bt2020nc',
            colorTransfer: 'smpte2084',
            colorPrimaries: 'bt2020',
          ),
          StreamInfo(
            index: 1,
            codecType: 'audio',
            codecName: 'aac',
            sampleRate: 48000,
            channels: 2,
            bitRate: 192000,
          ),
        ],
        tags: {},
      );

  group('HdrCharacteristics and StreamInfo Color Detection', () {
    test('detects HDR transfer characteristics', () {
      expect(HdrCharacteristics.isHdrTransfer('smpte2084'), isTrue);
      expect(HdrCharacteristics.isHdrTransfer('SMPTE2084'), isTrue);
      expect(HdrCharacteristics.isHdrTransfer('arib-std-b67'), isTrue);
      expect(HdrCharacteristics.isHdrTransfer('hlg'), isTrue);
      expect(HdrCharacteristics.isHdrTransfer('bt709'), isFalse);
      expect(HdrCharacteristics.isHdrTransfer(null), isFalse);
    });

    test('detects wide gamut primaries', () {
      expect(HdrCharacteristics.isWideGamut('bt2020'), isTrue);
      expect(HdrCharacteristics.isWideGamut('BT2020'), isTrue);
      expect(HdrCharacteristics.isWideGamut('smpte432'), isTrue);
      expect(HdrCharacteristics.isWideGamut('bt709'), isFalse);
      expect(HdrCharacteristics.isWideGamut(null), isFalse);
    });

    test('determines HDR stream and bit depth', () {
      final sdrMedia = makeSdrMedia();
      final hdrMedia = makeHdrMedia();

      expect(sdrMedia.isHdrSource, isFalse);
      expect(sdrMedia.videoStream!.isHdr, isFalse);
      expect(sdrMedia.videoStream!.bitDepth, 8);
      expect(sdrMedia.videoStream!.colorSummary, contains('BT.709'));

      expect(hdrMedia.isHdrSource, isTrue);
      expect(hdrMedia.videoStream!.isHdr, isTrue);
      expect(hdrMedia.videoStream!.bitDepth, 10);
      expect(hdrMedia.videoStream!.colorSummary, contains('BT.2020'));
      expect(hdrMedia.videoStream!.colorSummary, contains('10-bit'));
    });

    test('formats primaries and transfer nicely', () {
      expect(HdrCharacteristics.formatTransfer('smpte2084'), contains('PQ'));
      expect(HdrCharacteristics.formatTransfer('arib-std-b67'), contains('HLG'));
      expect(HdrCharacteristics.formatPrimaries('bt2020'), contains('BT.2020'));
    });
  });

  group('SettingsValidator HDR Rules', () {
    test('Exact Lossless rejects SDR to HDR and HDR Effect', () {
      final sdr = makeSdrMedia();

      final sdrToHdrLossless = SettingsValidator.validate(
        const CompressionSettings(
          mode: CompressionMode.exactLossless,
          hdrMode: HdrMode.sdrToHdr,
        ),
        sdr,
        caps: capsFull,
      );
      expect(sdrToHdrLossless.canStart, isFalse);
      expect(sdrToHdrLossless.errors.first.message,
          contains('Exact Lossless mode cannot apply HDR'));

      final hdrEffectLossless = SettingsValidator.validate(
        const CompressionSettings(
          mode: CompressionMode.exactLossless,
          hdrMode: HdrMode.hdrEffect,
        ),
        sdr,
        caps: capsFull,
      );
      expect(hdrEffectLossless.canStart, isFalse);
    });

    test('SDR to HDR requires HEVC video codec and rejects H.264', () {
      final sdr = makeSdrMedia();

      final h264SdrToHdr = SettingsValidator.validate(
        const CompressionSettings(
          mode: CompressionMode.highEfficiency,
          videoCodec: VideoCodecOption.h264,
          hdrMode: HdrMode.sdrToHdr,
        ),
        sdr,
        caps: capsFull,
      );
      expect(h264SdrToHdr.canStart, isFalse);
      expect(h264SdrToHdr.errors.first.message,
          contains('SDR to HDR conversion requires HEVC (H.265) 10-bit encoding'));

      final hevcSdrToHdr = SettingsValidator.validate(
        const CompressionSettings(
          mode: CompressionMode.highEfficiency,
          videoCodec: VideoCodecOption.hevc,
          hdrMode: HdrMode.sdrToHdr,
        ),
        sdr,
        caps: capsFull,
      );
      expect(hevcSdrToHdr.canStart, isTrue);
    });

    test('SDR to HDR rejects stream copy', () {
      final sdr = makeSdrMedia();
      final copySdrToHdr = SettingsValidator.validate(
        const CompressionSettings(
          mode: CompressionMode.custom,
          videoCodec: VideoCodecOption.copySource,
          hdrMode: HdrMode.sdrToHdr,
        ),
        sdr,
        caps: capsFull,
      );
      expect(copySdrToHdr.canStart, isFalse);
      expect(copySdrToHdr.errors.first.message,
          contains('Stream copy cannot convert SDR to HDR'));
    });

    test('HDR Effect rejects stream copy in custom mode', () {
      final sdr = makeSdrMedia();
      final copyHdrEffect = SettingsValidator.validate(
        const CompressionSettings(
          mode: CompressionMode.custom,
          videoCodec: VideoCodecOption.copySource,
          hdrMode: HdrMode.hdrEffect,
        ),
        sdr,
        caps: capsFull,
      );
      expect(copyHdrEffect.canStart, isFalse);
      expect(copyHdrEffect.errors.first.message,
          contains('HDR Effect visual filters cannot be applied in stream copy mode'));
    });

    test('Preserve HDR warns when source is SDR or when using 8-bit H.264', () {
      final sdr = makeSdrMedia();
      final hdr = makeHdrMedia();

      final sdrPreserve = SettingsValidator.validate(
        const CompressionSettings(
          mode: CompressionMode.highEfficiency,
          videoCodec: VideoCodecOption.hevc,
          hdrMode: HdrMode.preserveHdr,
        ),
        sdr,
        caps: capsFull,
      );
      expect(sdrPreserve.canStart, isTrue);
      expect(sdrPreserve.warnings.any((w) => w.message.contains('does not appear to be HDR')),
          isTrue);

      final hdrH264Preserve = SettingsValidator.validate(
        const CompressionSettings(
          mode: CompressionMode.highEfficiency,
          videoCodec: VideoCodecOption.h264,
          hdrMode: HdrMode.preserveHdr,
        ),
        hdr,
        caps: capsFull,
      );
      expect(hdrH264Preserve.canStart, isTrue);
      expect(
          hdrH264Preserve.warnings
              .any((w) => w.message.contains('H.264 standard profile is 8-bit')),
          isTrue);
    });
  });

  group('JobPlanner HDR Argument Generation', () {
    test('HDR Effect generates eq and unsharp filters with intensity scaling', () {
      final sdr = makeSdrMedia();
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(
          mode: CompressionMode.highEfficiency,
          videoCodec: VideoCodecOption.h264,
          hdrMode: HdrMode.hdrEffect,
          hdrIntensity: 0.8,
        ),
        media: sdr,
        caps: capsFull,
        sourcePath: '/tmp/input.mp4',
        outputPath: '/tmp/output.mp4',
      );

      final args = plan.stages.first;
      expect(args, contains('-vf'));
      final vfIdx = args.indexOf('-vf');
      final filterString = args[vfIdx + 1];
      expect(filterString, contains('eq='));
      expect(filterString, contains('contrast='));
      expect(filterString, contains('unsharp='));
      expect(plan.description, contains('HDR Effect (80%)'));
    });

    test('SDR to HDR generates 10-bit yuv420p10le and BT.2020 PQ color parameters', () {
      final sdr = makeSdrMedia();
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(
          mode: CompressionMode.highEfficiency,
          videoCodec: VideoCodecOption.hevc,
          hardware: HardwarePreference.software,
          hdrMode: HdrMode.sdrToHdr,
        ),
        media: sdr,
        caps: capsFull,
        sourcePath: '/tmp/input.mp4',
        outputPath: '/tmp/output.mp4',
      );

      final args = plan.stages.first;
      expect(args, contains('-pix_fmt'));
      expect(args[args.indexOf('-pix_fmt') + 1], 'yuv420p10le');
      expect(args, contains('-color_primaries'));
      expect(args[args.indexOf('-color_primaries') + 1], 'bt2020');
      expect(args, contains('-color_trc'));
      expect(args[args.indexOf('-color_trc') + 1], 'smpte2084');
      expect(args, contains('-colorspace'));
      expect(args[args.indexOf('-colorspace') + 1], 'bt2020nc');
      expect(args, contains('-x265-params'));
      final x265Params = args[args.indexOf('-x265-params') + 1];
      expect(x265Params, contains('hdr10-opt=1'));
      expect(x265Params, contains('colorprim=bt2020'));
      expect(x265Params, contains('transfer=smpte2084'));
      expect(plan.description, contains('HDR10 10-bit conversion'));
    });

    test('Preserve HDR passes through source HDR color characteristics', () {
      final hdr = makeHdrMedia();
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(
          mode: CompressionMode.highEfficiency,
          videoCodec: VideoCodecOption.hevc,
          hardware: HardwarePreference.software,
          hdrMode: HdrMode.preserveHdr,
        ),
        media: hdr,
        caps: capsFull,
        sourcePath: '/tmp/input.mp4',
        outputPath: '/tmp/output.mp4',
      );

      final args = plan.stages.first;
      expect(args, contains('-pix_fmt'));
      expect(args[args.indexOf('-pix_fmt') + 1], 'yuv420p10le');
      expect(args, contains('-color_primaries'));
      expect(args[args.indexOf('-color_primaries') + 1], 'bt2020');
      expect(args, contains('-color_trc'));
      expect(args[args.indexOf('-color_trc') + 1], 'smpte2084');
      expect(args, contains('-colorspace'));
      expect(args[args.indexOf('-colorspace') + 1], 'bt2020nc');
      expect(plan.description, contains('HDR preserved'));
    });
  });

  group('Bitrate Budgeting with HDR Modes', () {
    test('calculateVideoBitrateKbps enforces higher quality floor for 10-bit HDR', () {
      final sdrKbps = BitrateCalculator.calculateVideoBitrateKbps(
        targetSizeBytes: 500 * 1024, // very small target
        durationSeconds: 120.0,
        audioAction: AudioAction.none,
        hdrMode: HdrMode.off,
      );
      final hdrKbps = BitrateCalculator.calculateVideoBitrateKbps(
        targetSizeBytes: 500 * 1024,
        durationSeconds: 120.0,
        audioAction: AudioAction.none,
        hdrMode: HdrMode.sdrToHdr,
      );

      expect(sdrKbps, 100); // 100 kbps minimum floor for 8-bit SDR
      expect(hdrKbps, 250); // 250 kbps minimum floor for 10-bit HDR
    });
  });

  group('Model and Preset Serialization with HDR', () {
    test('CompressionSettings copyWith preserves and modifies HDR options', () {
      const s1 = CompressionSettings(mode: CompressionMode.highEfficiency);
      expect(s1.hdrMode, HdrMode.off);
      expect(s1.hdrIntensity, 0.5);

      final s2 = s1.copyWith(hdrMode: HdrMode.hdrEffect, hdrIntensity: 0.75);
      expect(s2.hdrMode, HdrMode.hdrEffect);
      expect(s2.hdrIntensity, 0.75);

      // copyWith without specifying hdrMode preserves current value
      final s3 = s2.copyWith(videoCodec: VideoCodecOption.hevc);
      expect(s3.hdrMode, HdrMode.hdrEffect);
      expect(s3.hdrIntensity, 0.75);
    });

    test('CompressionPreset preserves HDR settings in toJson and fromJson', () {
      const preset = CompressionPreset(
        id: 'hdr_preset_1',
        name: 'HDR10 Cinema',
        description: 'Converts SDR to HDR10 4K',
        videoCodec: VideoCodecOption.hevc,
        hdrMode: HdrMode.sdrToHdr,
        hdrIntensity: 0.65,
      );

      final json = preset.toJson();
      expect(json['hdrMode'], 'sdrToHdr');
      expect(json['hdrIntensity'], 0.65);

      final loaded = CompressionPreset.fromJson(json);
      expect(loaded.hdrMode, HdrMode.sdrToHdr);
      expect(loaded.hdrIntensity, 0.65);
    });

    test('JobRepository preserves HDR fields when adding and loading records', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = JobRepository();
      final record = JobRecord(
        id: 'hdr_job_1',
        createdAt: DateTime.now(),
        sourceName: 'video.mp4',
        originalBytes: 1000000,
        outputBytes: 500000,
        durationMs: 15000,
        mode: CompressionMode.highEfficiency,
        videoCodec: 'HEVC',
        outputPixFmt: 'yuv420p10le',
        outputColorPrimaries: 'bt2020',
        outputColorTransfer: 'smpte2084',
        outputColorSpace: 'bt2020nc',
        outputBitDepth: 10,
        hdrMode: HdrMode.sdrToHdr,
        hdrStatus: 'HDR10 (10-bit BT.2020)',
      );
      await repo.add(record);
      final loaded = await repo.load();
      expect(loaded, hasLength(1));
      expect(loaded.first.hdrMode, HdrMode.sdrToHdr);
      expect(loaded.first.outputBitDepth, 10);
      expect(loaded.first.outputPixFmt, 'yuv420p10le');
      expect(loaded.first.outputColorPrimaries, 'bt2020');
      expect(loaded.first.hdrStatus, 'HDR10 (10-bit BT.2020)');
    });
  });
}
