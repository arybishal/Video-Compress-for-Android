import 'package:flutter_test/flutter_test.dart';
import 'package:pure_compress/services/ffmpeg_service.dart';
import 'package:pure_compress/services/settings_validator.dart';

/// Realistic `ffmpeg -encoders` output (abridged) as printed by the
/// packaged full-GPL build.
const _sample = '''
Encoders:
 V..... = Video
 A..... = Audio
 S..... = Subtitle
 .F.... = Frame-level multithreading
 ..S... = Slice-level multithreading
 ...X.. = Codec is experimental
 ....B. = Supports draw_horiz_band
 ------
 V....D libx264              libx264 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (codec h264)
 V....D libx265              libx265 H.265 / HEVC (codec hevc)
 V....D libaom-av1           libaom AV1 (codec av1)
 VF...D h264_mediacodec      H.264 Android mediacodec
 VF...D hevc_mediacodec      HEVC Android mediacodec
 VF...D av1_mediacodec       AV1 Android mediacodec
 A....D aac                  AAC (Advanced Audio Coding)
 A....D flac                 FLAC (Free Lossless Audio Codec)
''';

void main() {
  group('ffmpeg -encoders parsing', () {
    test('extracts encoder names from the name column', () {
      final names = FfmpegService.parseEncoderNames(_sample);
      expect(names, containsAll([
        'libx264',
        'libx265',
        'libaom-av1',
        'h264_mediacodec',
        'hevc_mediacodec',
        'av1_mediacodec',
        'aac',
        'flac',
      ]));
    });

    test('legend rows and separators never leak into the set', () {
      final names = FfmpegService.parseEncoderNames(_sample);
      expect(names, isNot(contains('Video')));
      expect(names, isNot(contains('Audio')));
      expect(names, isNot(contains('=')));
      expect(names, isNot(contains('------')));
    });

    test('this app build has no libsvtav1 — libaom is the AV1 encoder', () {
      final names = FfmpegService.parseEncoderNames(_sample);
      expect(names, isNot(contains('libsvtav1')));
      expect(names, contains('libaom-av1'));
    });

    test('empty output yields an empty set (no crashes)', () {
      expect(FfmpegService.parseEncoderNames(''), isEmpty);
      expect(FfmpegService.parseEncoderNames('garbage\nno rows here'), isEmpty);
    });
  });

  group('capability mirror', () {
    const caps = FfmpegCapabilitiesLike(
      h264Software: true,
      hevcSoftware: true,
      av1Software: true,
      h264Hardware: true,
      hevcHardware: true,
      av1Libaom: true,
      av1SvtAv1: false,
    );

    test('supportsEncoder answers per exact encoder name', () {
      expect(caps.supportsEncoder('libx264'), isTrue);
      expect(caps.supportsEncoder('libx265'), isTrue);
      expect(caps.supportsEncoder('libaom-av1'), isTrue);
      expect(caps.supportsEncoder('libsvtav1'), isFalse);
      expect(caps.supportsEncoder('hevc_mediacodec'), isTrue);
      expect(caps.supportsEncoder('librav1e'), isFalse);
    });
  });
}
