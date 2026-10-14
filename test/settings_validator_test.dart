import 'package:flutter_test/flutter_test.dart';
import 'package:pure_compress/models/models.dart';
import 'package:pure_compress/services/settings_validator.dart';

MediaInfo _media({
  String videoCodec = 'h264',
  String? audioCodec = 'aac',
  String pixFmt = 'yuv420p',
  int? videoBitrate = 8000000,
  double? fps = 30,
  List<StreamInfo> extra = const [],
}) {
  return MediaInfo(
    formatName: 'mov,mp4,m4a',
    durationSeconds: 60,
    sizeBytes: 60000000,
    bitRate: 8200000,
    streams: [
      StreamInfo(
        index: 0,
        codecType: 'video',
        codecName: videoCodec,
        width: 1920,
        height: 1080,
        pixFmt: pixFmt,
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
      ...extra,
    ],
    tags: const {},
  );
}

const _fullCaps = FfmpegCapabilitiesLike(
  h264Software: true,
  hevcSoftware: true,
  av1Software: true,
  h264Hardware: true,
  hevcHardware: true,
  av1Libaom: true,
  av1SvtAv1: false,
);

void main() {
  group('Exact Lossless validation', () {
    test('remux into MP4 is valid for H.264/AAC', () {
      final v = SettingsValidator.validate(
        const CompressionSettings(mode: CompressionMode.exactLossless),
        _media(),
        caps: _fullCaps,
      );
      expect(v.canStart, isTrue);
    });

    test('VP9 in MP4 remux is rejected with actionable message', () {
      final v = SettingsValidator.validate(
        const CompressionSettings(mode: CompressionMode.exactLossless),
        _media(videoCodec: 'vp9'),
        caps: _fullCaps,
      );
      expect(v.canStart, isFalse);
      expect(v.errors.first.message, contains('MKV'));
    });

    test('lossless mode rejects resolution/fps/bitrate changes', () {
      final v = SettingsValidator.validate(
        const CompressionSettings(
          mode: CompressionMode.exactLossless,
          targetWidth: 1280,
          targetHeight: 720,
        ),
        _media(),
        caps: _fullCaps,
      );
      expect(v.canStart, isFalse);
    });

    test('high bit depth forbids lossless re-encode', () {
      final v = SettingsValidator.validate(
        const CompressionSettings(
            mode: CompressionMode.exactLossless,
            losslessEncoder: LosslessEncoder.x264),
        _media(pixFmt: 'yuv420p10le'),
        caps: _fullCaps,
      );
      expect(v.canStart, isFalse);
    });

    test('x265 lossless accepts yuv420p but rejects yuv444p', () {
      final ok = SettingsValidator.validate(
        const CompressionSettings(
            mode: CompressionMode.exactLossless,
            losslessEncoder: LosslessEncoder.x265),
        _media(pixFmt: 'yuv420p'),
        caps: _fullCaps,
      );
      expect(ok.canStart, isTrue);
      final bad = SettingsValidator.validate(
        const CompressionSettings(
            mode: CompressionMode.exactLossless,
            losslessEncoder: LosslessEncoder.x265,
            container: ContainerOption.mkv),
        _media(pixFmt: 'yuv444p'),
        caps: _fullCaps,
      );
      expect(bad.canStart, isFalse);
      expect(bad.errors.first.message, contains('yuv444p'));
    });

    test('lossless encoder absent from the build is an error', () {
      const noAv1 = FfmpegCapabilitiesLike(
        h264Software: true,
        hevcSoftware: true,
        av1Software: false,
        h264Hardware: false,
        hevcHardware: false,
      );
      final v = SettingsValidator.validate(
        const CompressionSettings(
            mode: CompressionMode.exactLossless,
            losslessEncoder: LosslessEncoder.av1,
            container: ContainerOption.mkv),
        _media(),
        caps: noAv1,
      );
      expect(v.canStart, isFalse);
      expect(v.errors.first.message, contains('libaom-av1'));
    });

    test('MP4 + subtitles produces a non-blocking warning', () {
      final v = SettingsValidator.validate(
        const CompressionSettings(mode: CompressionMode.exactLossless),
        _media(extra: const [
          StreamInfo(index: 2, codecType: 'subtitle', codecName: 'subrip')
        ]),
        caps: _fullCaps,
      );
      expect(v.canStart, isTrue);
      expect(v.warnings.any((w) => w.message.contains('Subtitles')), isTrue);
    });
  });

  group('High Efficiency / Custom validation', () {
    test('target bitrate at/above source warns about size increase', () {
      final v = SettingsValidator.validate(
        const CompressionSettings(
            mode: CompressionMode.custom, targetBitrateKbps: 8000),
        _media(videoBitrate: 8000000),
        caps: _fullCaps,
      );
      expect(v.canStart, isTrue);
      expect(v.warnings.any((w) => w.message.contains('larger')), isTrue);
    });

    test('frame rate above source is an error', () {
      final v = SettingsValidator.validate(
        const CompressionSettings(mode: CompressionMode.custom, frameRate: 60),
        _media(fps: 30),
        caps: _fullCaps,
      );
      expect(v.canStart, isFalse);
    });

    test('frame rate below source warns but allows', () {
      final v = SettingsValidator.validate(
        const CompressionSettings(mode: CompressionMode.custom, frameRate: 24),
        _media(fps: 30),
        caps: _fullCaps,
      );
      expect(v.canStart, isTrue);
      expect(v.warnings, isNotEmpty);
    });

    test('missing requested codec is an error', () {
      const noHevc = FfmpegCapabilitiesLike(
        h264Software: true,
        hevcSoftware: false,
        av1Software: false,
        h264Hardware: false,
        hevcHardware: false,
      );
      final v = SettingsValidator.validate(
        const CompressionSettings(
            mode: CompressionMode.highEfficiency,
            videoCodec: VideoCodecOption.hevc),
        _media(),
        caps: noHevc,
      );
      expect(v.canStart, isFalse);
    });

    test('stream copy custom cannot change resolution', () {
      final v = SettingsValidator.validate(
        const CompressionSettings(
          mode: CompressionMode.custom,
          videoCodec: VideoCodecOption.copySource,
          targetWidth: 1280,
          targetHeight: 720,
        ),
        _media(),
        caps: _fullCaps,
      );
      expect(v.canStart, isFalse);
    });

    test('file without video stream is always rejected', () {
      final v = SettingsValidator.validate(
        const CompressionSettings(mode: CompressionMode.highEfficiency),
        MediaInfo(
          formatName: 'mp3',
          durationSeconds: 10,
          sizeBytes: 100,
          bitRate: 128000,
          streams: const [
            StreamInfo(index: 0, codecType: 'audio', codecName: 'mp3')
          ],
          tags: const {},
        ),
        caps: _fullCaps,
      );
      expect(v.canStart, isFalse);
    });

    test('hardware preference warning appears only when forcing hardware', () {
      final forced = SettingsValidator.validate(
        const CompressionSettings(
            mode: CompressionMode.highEfficiency,
            hardware: HardwarePreference.hardware),
        _media(),
        caps: _fullCaps,
      );
      final auto = SettingsValidator.validate(
        const CompressionSettings(mode: CompressionMode.highEfficiency),
        _media(),
        caps: _fullCaps,
      );
      expect(
          forced.warnings.any((w) => w.message.contains('hardware')), isTrue);
      expect(auto.warnings.any((w) => w.message.contains('hardware')), isFalse);
    });

    test('CRF above the codec maximum is an error', () {
      final h264 = SettingsValidator.validate(
        const CompressionSettings(
            mode: CompressionMode.highEfficiency, crf: 52),
        _media(),
        caps: _fullCaps,
      );
      expect(h264.canStart, isFalse);
      // AV1 (libaom/libsvtav1) supports CRF up to 63.
      final av1 = SettingsValidator.validate(
        const CompressionSettings(
            mode: CompressionMode.highEfficiency,
            videoCodec: VideoCodecOption.av1,
            crf: 63),
        _media(),
        caps: _fullCaps,
      );
      expect(av1.canStart, isTrue);
    });

    test('very low CRF warns about size increase', () {
      final v = SettingsValidator.validate(
        const CompressionSettings(
            mode: CompressionMode.highEfficiency,
            videoCodec: VideoCodecOption.hevc,
            crf: 12),
        _media(),
        caps: _fullCaps,
      );
      expect(v.canStart, isTrue);
      expect(v.warnings.any((w) => w.message.contains('larger')), isTrue);
    });

    test('CRF mode with missing software encoder is an error', () {
      const noAv1 = FfmpegCapabilitiesLike(
        h264Software: true,
        hevcSoftware: true,
        av1Software: false,
        h264Hardware: true,
        hevcHardware: true,
      );
      final v = SettingsValidator.validate(
        const CompressionSettings(
            mode: CompressionMode.highEfficiency,
            videoCodec: VideoCodecOption.av1,
            crf: 30),
        _media(),
        caps: noAv1,
      );
      expect(v.canStart, isFalse);
    });
  });

  group('container codec matrix', () {
    test('mp4 fits', () {
      expect(
          SettingsValidator.videoCodecFitsContainer(
              'h264', ContainerOption.mp4),
          isTrue);
      expect(
          SettingsValidator.audioCodecFitsContainer(
              'flac', ContainerOption.mp4),
          isFalse);
    });
    test('mkv fits nearly everything', () {
      expect(
          SettingsValidator.videoCodecFitsContainer(
              'ffv1', ContainerOption.mkv),
          isTrue);
      expect(
          SettingsValidator.audioCodecFitsContainer(
              'flac', ContainerOption.mkv),
          isTrue);
      expect(
          SettingsValidator.audioCodecFitsContainer(
              'pcm_s24le', ContainerOption.mkv),
          isTrue);
    });
  });
}
