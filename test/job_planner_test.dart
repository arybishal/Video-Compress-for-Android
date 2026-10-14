import 'package:flutter_test/flutter_test.dart';
import 'package:pure_compress/models/models.dart';
import 'package:pure_compress/services/job_planner.dart';
import 'package:pure_compress/services/settings_validator.dart';

MediaInfo _media({
  String videoCodec = 'h264',
  String? audioCodec = 'aac',
  int width = 1920,
  int height = 1080,
  double fps = 30,
  int videoBitrate = 8000000,
}) {
  return MediaInfo(
    formatName: 'mov,mp4',
    durationSeconds: 60,
    sizeBytes: 60000000,
    bitRate: 8200000,
    streams: [
      StreamInfo(
        index: 0,
        codecType: 'video',
        codecName: videoCodec,
        width: width,
        height: height,
        pixFmt: 'yuv420p',
        frameRate: fps,
        bitRate: videoBitrate,
      ),
      if (audioCodec != null)
        StreamInfo(
          index: 1,
          codecType: 'audio',
          codecName: audioCodec,
          sampleRate: 48000,
          channels: 2,
        ),
    ],
    tags: const {},
  );
}

const _caps = FfmpegCapabilitiesLike(
  h264Software: true,
  hevcSoftware: true,
  av1Software: true,
  h264Hardware: true,
  hevcHardware: true,
  av1Libaom: true,
  av1SvtAv1: false,
);

const _swOnly = FfmpegCapabilitiesLike(
  h264Software: true,
  hevcSoftware: true,
  av1Software: true,
  h264Hardware: false,
  hevcHardware: false,
  av1Libaom: true,
  av1SvtAv1: false,
);

List<String> firstStage(CompressionPlan plan) => plan.stages.single;

void main() {
  group('Exact Lossless remux plan', () {
    test('stream copy uses -c copy, maps streams, keeps metadata', () {
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(mode: CompressionMode.exactLossless),
        media: _media(),
        caps: _caps,
        sourcePath: '/in.mp4',
        outputPath: '/out.mp4',
      );
      final args = firstStage(plan);
      expect(plan.isLossless, isTrue);
      expect(plan.expectedVerification, VerificationExpectation.decodedEquality);
      expect(args, containsAllInOrder(['-i', '/in.mp4']));
      expect(args, containsAllInOrder(['-c', 'copy']));
      expect(args, containsAllInOrder(['-map_metadata', '0']));
      expect(args, contains('-movflags')); // mp4 faststart
      expect(args.last, '/out.mp4');
      expect(args, isNot(contains('-c:v')));
    });

    test('mkv remux keeps subtitles, mp4 keeps mov_text conversion', () {
      final media = _media();
      final withSubs = MediaInfo(
        formatName: media.formatName,
        durationSeconds: media.durationSeconds,
        sizeBytes: media.sizeBytes,
        bitRate: media.bitRate,
        streams: [
          ...media.streams,
          const StreamInfo(
              index: 2, codecType: 'subtitle', codecName: 'subrip'),
        ],
        tags: const {},
      );
      final mkv = JobPlanner.plan(
        settings: const CompressionSettings(
            mode: CompressionMode.exactLossless, container: ContainerOption.mkv),
        media: withSubs,
        caps: _caps,
        sourcePath: '/in.mp4',
        outputPath: '/out.mkv',
      );
      expect(firstStage(mkv), containsAllInOrder(['-map', '0:s?']));
      final mp4 = JobPlanner.plan(
        settings: const CompressionSettings(mode: CompressionMode.exactLossless),
        media: withSubs,
        caps: _caps,
        sourcePath: '/in.mp4',
        outputPath: '/out.mp4',
      );
      expect(firstStage(mp4), containsAllInOrder(['-c:s', 'mov_text']));
    });

    test('lossless re-encode uses libx264 crf 0 and flags verification type', () {
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(
            mode: CompressionMode.exactLossless,
            losslessEncoder: LosslessEncoder.x264),
        media: _media(),
        caps: _caps,
        sourcePath: '/in.mp4',
        outputPath: '/out.mkv',
      );
      final args = firstStage(plan);
      expect(args, containsAllInOrder(['-c:v', 'libx264']));
      expect(args, containsAllInOrder(['-crf', '0']));
      expect(args, containsAllInOrder(['-pix_fmt', 'yuv420p']));
      expect(plan.expectedVerification,
          VerificationExpectation.decodedEqualityReencode);
    });

    test('HEVC lossless uses libx265 lossless=1 (mode D)', () {
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(
            mode: CompressionMode.exactLossless,
            losslessEncoder: LosslessEncoder.x265,
            container: ContainerOption.mkv),
        media: _media(),
        caps: _caps,
        sourcePath: '/in.mp4',
        outputPath: '/out.mkv',
      );
      final args = firstStage(plan);
      expect(args, containsAllInOrder(
          ['-c:v', 'libx265', '-x265-params', 'lossless=1']));
      expect(args, isNot(contains('libx264')));
      expect(plan.isLossless, isTrue);
    });

    test('AV1 lossless uses libaom-av1 -lossless 1 (mode F)', () {
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(
            mode: CompressionMode.exactLossless,
            losslessEncoder: LosslessEncoder.av1,
            container: ContainerOption.mkv),
        media: _media(),
        caps: _caps,
        sourcePath: '/in.mp4',
        outputPath: '/out.mkv',
      );
      final args = firstStage(plan);
      expect(args, containsAllInOrder(
          ['-c:v', 'libaom-av1', '-lossless', '1', '-b:v', '0']));
      expect(args, contains('-cpu-used')); // aom speed knob, not -preset
      expect(args, isNot(contains('-preset')));
      expect(args, containsAllInOrder(['-pix_fmt', 'yuv420p']));
    });

    test('lossless re-encode throws when the encoder is not in the build', () {
      const noHevc = FfmpegCapabilitiesLike(
        h264Software: true,
        hevcSoftware: false,
        av1Software: false,
        h264Hardware: false,
        hevcHardware: false,
      );
      expect(
        () => JobPlanner.plan(
          settings: const CompressionSettings(
              mode: CompressionMode.exactLossless,
              losslessEncoder: LosslessEncoder.x265,
              container: ContainerOption.mkv),
          media: _media(),
          caps: noHevc,
          sourcePath: '/in.mp4',
          outputPath: '/out.mkv',
        ),
        throwsArgumentError,
      );
    });
  });

  group('High Efficiency plan', () {
    test('auto prefers hardware H.264 when available', () {
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(mode: CompressionMode.highEfficiency),
        media: _media(),
        caps: _caps,
        sourcePath: '/in.mp4',
        outputPath: '/out.mp4',
      );
      final args = firstStage(plan);
      expect(args, containsAllInOrder(['-c:v', 'h264_mediacodec']));
      expect(args, isNot(contains('libx264')));
    });

    test('auto falls back to software when hardware is absent', () {
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(mode: CompressionMode.highEfficiency),
        media: _media(),
        caps: _swOnly,
        sourcePath: '/in.mp4',
        outputPath: '/out.mp4',
      );
      expect(firstStage(plan), containsAllInOrder(['-c:v', 'libx264']));
    });

    test('forced software never emits a mediacodec encoder', () {
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(
            mode: CompressionMode.highEfficiency,
            hardware: HardwarePreference.software),
        media: _media(),
        caps: _caps,
        sourcePath: '/in.mp4',
        outputPath: '/out.mp4',
      );
      expect(firstStage(plan), isNot(contains('mediacodec')));
    });

    test('estimated bitrate is capped below source bitrate', () {
      // 1080p30 highQuality factor would exceed source; must be capped to
      // 85% of the 8 Mbps source video bitrate.
      final kbps = JobPlanner.debugEstimatedBitrateKbps(
          1920, 1080, 30, QualityPreset.highQuality,
          sourceVideoBitrate: 8000000);
      expect(kbps, 6800);
    });

    test('tiny resolutions get a sane floor', () {
      final kbps = JobPlanner.debugEstimatedBitrateKbps(
          128, 96, 15, QualityPreset.smaller);
      expect(kbps, 200);
    });

    test('explicit downscale adds an even-dimension scale filter', () {
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(
          mode: CompressionMode.highEfficiency,
          targetWidth: 1280,
          targetHeight: 721, // odd height must be corrected to even
        ),
        media: _media(),
        caps: _swOnly,
        sourcePath: '/in.mp4',
        outputPath: '/out.mp4',
      );
      expect(firstStage(plan), containsAllInOrder(['-vf', 'scale=1280:720']));
    });

    test('audio options map correctly; none removes audio', () {
      final aac = JobPlanner.plan(
        settings: const CompressionSettings(
            mode: CompressionMode.highEfficiency, audio: AudioAction.aac64),
        media: _media(),
        caps: _swOnly,
        sourcePath: '/in.mp4',
        outputPath: '/out.mp4',
      );
      expect(firstStage(aac), containsAllInOrder(['-c:a', 'aac', '-b:a', '64k']));
      final none = JobPlanner.plan(
        settings: const CompressionSettings(
            mode: CompressionMode.highEfficiency, audio: AudioAction.none),
        media: _media(),
        caps: _swOnly,
        sourcePath: '/in.mp4',
        outputPath: '/out.mp4',
      );
      expect(firstStage(none), contains('-an'));
    });

    test('video without audio stream always gets -an', () {
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(mode: CompressionMode.highEfficiency),
        media: _media(audioCodec: null),
        caps: _swOnly,
        sourcePath: '/in.mp4',
        outputPath: '/out.mp4',
      );
      expect(firstStage(plan), contains('-an'));
    });

    test('lossless mode never silently converts incompatible audio to lossy', () {
      // opus audio cannot be copied into mp4 and mp4 has no lossless audio
      // here -> planner must throw rather than pick AAC.
      expect(
        () => JobPlanner.plan(
          settings: const CompressionSettings(
              mode: CompressionMode.exactLossless,
              losslessEncoder: LosslessEncoder.x264,
              container: ContainerOption.mp4),
          media: _media(audioCodec: 'opus'),
          caps: _caps,
          sourcePath: '/in.mp4',
          outputPath: '/out.mp4',
        ),
        throwsArgumentError,
      );
    });
  });

  group('High Efficiency CRF plans (modes A/C/G/E)', () {
    test('mode A: H.264 CRF 23 with x264 preset', () {
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(
            mode: CompressionMode.highEfficiency, crf: 23),
        media: _media(),
        caps: _caps,
        sourcePath: '/in.mp4',
        outputPath: '/out.mp4',
      );
      final args = firstStage(plan);
      expect(args, containsAllInOrder(
          ['-c:v', 'libx264', '-preset', 'medium', '-crf', '23']));
      expect(args, isNot(contains('-b:v'))); // CRF rate control only
      expect(plan.isLossless, isFalse);
      expect(plan.description.toLowerCase(), contains('lossy'));
      expect(plan.description, contains('Not lossless'));
    });

    test('mode C: HEVC CRF 26 with libx265', () {
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(
            mode: CompressionMode.highEfficiency,
            videoCodec: VideoCodecOption.hevc,
            crf: 26),
        media: _media(),
        caps: _caps,
        sourcePath: '/in.mp4',
        outputPath: '/out.mp4',
      );
      expect(firstStage(plan), containsAllInOrder(
          ['-c:v', 'libx265', '-preset', 'medium', '-crf', '26']));
    });

    test('mode G: HEVC low CRF 18 keeps the requested value', () {
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(
            mode: CompressionMode.highEfficiency,
            videoCodec: VideoCodecOption.hevc,
            crf: 18),
        media: _media(),
        caps: _caps,
        sourcePath: '/in.mp4',
        outputPath: '/out.mp4',
      );
      expect(firstStage(plan), containsAllInOrder(['-crf', '18']));
    });

    test('mode E: AV1 uses libaom-av1 with -b:v 0 and -cpu-used', () {
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(
            mode: CompressionMode.highEfficiency,
            videoCodec: VideoCodecOption.av1,
            crf: 30),
        media: _media(),
        caps: _caps,
        sourcePath: '/in.mp4',
        outputPath: '/out.mkv',
      );
      final args = firstStage(plan);
      expect(args, containsAllInOrder(
          ['-c:v', 'libaom-av1', '-crf', '30', '-b:v', '0']));
      expect(args, containsAllInOrder(['-cpu-used', '5'])); // medium speed
      expect(args, isNot(contains('libsvtav1'))); // not in this build
      expect(args, isNot(contains('-preset')));
    });

    test('CRF request forces software even with hardware available', () {
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(
            mode: CompressionMode.highEfficiency,
            hardware: HardwarePreference.auto,
            crf: 23),
        media: _media(),
        caps: _caps, // hardware present
        sourcePath: '/in.mp4',
        outputPath: '/out.mp4',
      );
      expect(firstStage(plan), isNot(contains('mediacodec')));
      expect(firstStage(plan), containsAllInOrder(['-c:v', 'libx264']));
    });

    test('speed preset maps to x265 preset names and aom cpu-used', () {
      final slow = JobPlanner.plan(
        settings: const CompressionSettings(
            mode: CompressionMode.highEfficiency,
            videoCodec: VideoCodecOption.hevc,
            crf: 26,
            speedPreset: SpeedPreset.slow),
        media: _media(),
        caps: _caps,
        sourcePath: '/in.mp4',
        outputPath: '/out.mkv',
      );
      expect(firstStage(slow), containsAllInOrder(['-preset', 'slow']));
      final aom = JobPlanner.plan(
        settings: const CompressionSettings(
            mode: CompressionMode.highEfficiency,
            videoCodec: VideoCodecOption.av1,
            crf: 30,
            speedPreset: SpeedPreset.slow),
        media: _media(),
        caps: _caps,
        sourcePath: '/in.mp4',
        outputPath: '/out.mkv',
      );
      expect(firstStage(aom), containsAllInOrder(['-cpu-used', '3']));
    });

    test('libsvtav1-only builds still get a working AV1 encoder', () {
      const svtOnly = FfmpegCapabilitiesLike(
        h264Software: true,
        hevcSoftware: true,
        av1Software: true,
        h264Hardware: false,
        hevcHardware: false,
        av1Libaom: false,
        av1SvtAv1: true,
      );
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(
            mode: CompressionMode.highEfficiency,
            videoCodec: VideoCodecOption.av1,
            crf: 30),
        media: _media(),
        caps: svtOnly,
        sourcePath: '/in.mp4',
        outputPath: '/out.mkv',
      );
      final args = firstStage(plan);
      expect(args, containsAllInOrder(['-c:v', 'libsvtav1', '-crf', '30']));
      expect(args, isNot(contains('libaom-av1')));
    });
  });

  group('Custom stream copy', () {
    test('copySource produces remux without lossless verification', () {
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(
            mode: CompressionMode.custom, videoCodec: VideoCodecOption.copySource),
        media: _media(),
        caps: _caps,
        sourcePath: '/in.mp4',
        outputPath: '/out.mp4',
      );
      expect(firstStage(plan), containsAllInOrder(['-c', 'copy']));
      expect(plan.isLossless, isFalse);
      expect(plan.expectedVerification, VerificationExpectation.none);
    });

    test('AV1 custom bitrate uses libaom-av1 with -cpu-used', () {
      final plan = JobPlanner.plan(
        settings: const CompressionSettings(
            mode: CompressionMode.custom, videoCodec: VideoCodecOption.av1),
        media: _media(),
        caps: _caps,
        sourcePath: '/in.mp4',
        outputPath: '/out.mkv',
      );
      final args = firstStage(plan);
      expect(args, containsAllInOrder(['-c:v', 'libaom-av1', '-b:v']));
      expect(args, contains('-cpu-used'));
      expect(args, isNot(contains('libsvtav1'))); // absent from this build
    });
  });

  group('output naming', () {
    test('sanitizes names and appends mode suffix + extension', () {
      final name = JobPlanner.outputName(
        'My: Video?.MOV',
        const CompressionSettings(mode: CompressionMode.highEfficiency),
        jobId: 'x1',
      );
      expect(name, 'My_ Video_compressed_x1.mp4');
    });

    test('mkv container yields mkv extension; lossless suffixes differ', () {
      final remux = JobPlanner.outputName(
        'a.mp4',
        const CompressionSettings(mode: CompressionMode.exactLossless),
      );
      expect(remux, 'a_remux.mp4');
      final enc = JobPlanner.outputName(
        'a.mp4',
        const CompressionSettings(
            mode: CompressionMode.exactLossless,
            losslessEncoder: LosslessEncoder.x264,
            container: ContainerOption.mkv),
      );
      expect(enc, 'a_lossless.mkv');
      final hevc = JobPlanner.outputName(
        'a.mp4',
        const CompressionSettings(
            mode: CompressionMode.exactLossless,
            losslessEncoder: LosslessEncoder.x265,
            container: ContainerOption.mkv),
      );
      expect(hevc, 'a_hevc_lossless.mkv');
      final av1 = JobPlanner.outputName(
        'a.mp4',
        const CompressionSettings(
            mode: CompressionMode.exactLossless,
            losslessEncoder: LosslessEncoder.av1,
            container: ContainerOption.mkv),
      );
      expect(av1, 'a_av1_lossless.mkv');
    });

    test('empty base name falls back to "video"', () {
      final name = JobPlanner.outputName(
          '', const CompressionSettings(mode: CompressionMode.custom));
      expect(name, 'video_custom.mp4');
    });
  });
}
