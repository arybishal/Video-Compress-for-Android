import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_compress/models/models.dart';
import 'package:pure_compress/services/ffmpeg_service.dart';
import 'package:pure_compress/services/verification_service.dart';

void main() {
  group('framemd5 parsing', () {
    test('classifies video (stream 0) and audio (stream 1+) hashes', () async {
      final f = File('${Directory.systemTemp.path}/pc_test_parse.framemd5');
      await f.writeAsString('''
# ffversion version 6.0
# command,framemd5,-i,test
0, 0, 0, 1, 460800, aaaaaa
0, 1, 1, 1, 460800, bbbbbb
1, 0, 0, 1, 2048, cccccc
1, 1, 1, 1, 2048, dddddd
''');
      final data = await VerificationService.parseFramemd5File(f);
      expect(data.video, ['aaaaaa', 'bbbbbb']);
      expect(data.audio, ['cccccc', 'dddddd']);
      await f.delete();
    });

    test('tolerates short files and garbage lines', () async {
      final f = File('${Directory.systemTemp.path}/pc_test_parse2.framemd5');
      await f.writeAsString('random noise\n0, 1\n0, 0, 0, 1, 5, abc\n');
      final data = await VerificationService.parseFramemd5File(f);
      expect(data.video, ['abc']);
      await f.delete();
    });
  });

  group('hash sequence comparison', () {
    List<String> seq(List<String> hashes) => hashes;

    test('identical sequences are equal', () {
      expect(
        VerificationService.compareHashSequences(
            seq(['a', 'b']), seq(['a', 'b']), maxExtraFrames: 0),
        isTrue,
      );
    });

    test('any video frame difference is NOT equal', () {
      expect(
        VerificationService.compareHashSequences(
            seq(['a', 'b', 'c']), seq(['a', 'X', 'c']), maxExtraFrames: 0),
        isFalse,
      );
    });

    test('different lengths are not equal for video', () {
      expect(
        VerificationService.compareHashSequences(
            seq(['a', 'b', 'c']), seq(['a', 'b']), maxExtraFrames: 0),
        isFalse,
      );
    });

    test('small audio priming difference is tolerated and counted', () {
      var diff = 0;
      expect(
        VerificationService.compareHashSequences(
          seq(['p', 'a', 'b', 'c']),
          seq(['a', 'b', 'c']),
          maxExtraFrames: 8,
          diffCount: (n) => diff = n,
        ),
        isTrue,
      );
      expect(diff, 1);
    });

    test('large audio differences are not tolerated', () {
      expect(
        VerificationService.compareHashSequences(
          seq(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j']),
          seq(['a']),
          maxExtraFrames: 8,
        ),
        isFalse,
      );
    });
  });

  group('ffmpeg failure mapping', () {
    FfmpegResult result(String err) => FfmpegResult(
          returnCode: 1,
          isSuccess: false,
          output: '',
          errorOutput: err,
          cancelled: false,
        );

    test('maps storage exhaustion', () {
      final e = mapFfmpegFailure(result('Error writing trailer: No space left on device'));
      expect(e.kind, FfmpegErrorKind.noSpace);
      expect(e.userMessage, contains('free storage'));
    });

    test('maps unknown encoder', () {
      final e = mapFfmpegFailure(result('Unknown encoder \'libx265\''));
      expect(e.kind, FfmpegErrorKind.unsupportedCodec);
    });

    test('maps hardware encoder init failure distinctly', () {
      final e = mapFfmpegFailure(
          result('h264_mediacodec encoder init failed'),
          hardwareWasUsed: true);
      expect(e.kind, FfmpegErrorKind.hardwareEncoderFailed);
    });

    test('maps corrupt input', () {
      final e = mapFfmpegFailure(result('moov atom not found'));
      expect(e.kind, FfmpegErrorKind.corruptInput);
    });

    test('maps permission loss', () {
      final e = mapFfmpegFailure(result('...: Permission denied'));
      expect(e.kind, FfmpegErrorKind.ioError);
    });

    test('unknown failures keep a safe generic message', () {
      final e = mapFfmpegFailure(result('something bizarre happened'));
      expect(e.kind, FfmpegErrorKind.unknown);
      expect(e.userMessage, contains('original file was not modified'));
    });
  });

  group('lossy output integrity check', () {
    MediaInfo media({
      double duration = 60,
      int width = 1920,
      int height = 1080,
      bool audio = true,
    }) =>
        MediaInfo(
          formatName: 'mov,mp4',
          durationSeconds: duration,
          sizeBytes: 1000,
          bitRate: 1000,
          streams: [
            StreamInfo(
                index: 0,
                codecType: 'video',
                codecName: 'h264',
                width: width,
                height: height,
                pixFmt: 'yuv420p',
                frameRate: 30),
            if (audio)
              const StreamInfo(
                  index: 1,
                  codecType: 'audio',
                  codecName: 'aac',
                  sampleRate: 48000,
                  channels: 2),
          ],
          tags: const {},
        );

    /// Fake engine: probe() returns a canned "output file" description.
    FakeFfmpeg probeReturning(MediaInfo output) => FakeFfmpeg(output);

    test('matching output passes all checks', () async {
      final svc = VerificationService(probeReturning(media(duration: 59.4)));
      final r = await svc.verifyLossyIntegrity(
        source: media(),
        outputPath: '/out.mp4',
        expectAudio: true,
      );
      expect(r.ok, isTrue);
      expect(r.detail, isNull);
    });

    test('duration far off is reported', () async {
      final svc = VerificationService(probeReturning(media(duration: 30)));
      final r = await svc.verifyLossyIntegrity(
        source: media(),
        outputPath: '/out.mp4',
        expectAudio: true,
      );
      expect(r.ok, isFalse);
      expect(r.durationMatches, isFalse);
      expect(r.detail, contains('duration'));
    });

    test('missing expected audio is reported', () async {
      final svc =
          VerificationService(probeReturning(media(audio: false)));
      final r = await svc.verifyLossyIntegrity(
        source: media(),
        outputPath: '/out.mp4',
        expectAudio: true,
      );
      expect(r.ok, isFalse);
      expect(r.audioMatches, isFalse);
      expect(r.detail, contains('audio missing'));
    });

    test('downscaled output matches the requested resolution only', () async {
      final svc =
          VerificationService(probeReturning(media(width: 1280, height: 720)));
      final asRequested = await svc.verifyLossyIntegrity(
        source: media(),
        outputPath: '/out.mp4',
        expectedWidth: 1280,
        expectedHeight: 720,
        expectAudio: true,
      );
      expect(asRequested.resolutionMatches, isTrue);
      final unexpected = await svc.verifyLossyIntegrity(
        source: media(),
        outputPath: '/out.mp4',
        expectAudio: true, // no downscale requested, but output shrank
      );
      expect(unexpected.resolutionMatches, isFalse);
    });
  });
}

/// Test double: answers probe() with a canned result, no FFmpeg involved.
class FakeFfmpeg extends FfmpegService {
  FakeFfmpeg(this.output);
  final MediaInfo output;

  @override
  Future<MediaInfo> probe(String path, {int fallbackSizeBytes = 0}) async =>
      output;
}
