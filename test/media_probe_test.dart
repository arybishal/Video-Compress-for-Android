import 'package:flutter_test/flutter_test.dart';
import 'package:pure_compress/services/media_probe.dart';

void main() {
  test('parses an H.264 + AAC MP4 with display-matrix rotation', () {
    const json = '''
{
  "format": {
    "format_name": "mov,mp4,m4a,3gp,3g2,mj2",
    "duration": "12.512000",
    "size": "10485760",
    "bit_rate": "6703021",
    "tags": {"major_brand": "isom", "com.android.version": "14"}
  },
  "streams": [
    {
      "index": 0,
      "codec_name": "h264",
      "codec_type": "video",
      "width": 1920,
      "height": 1080,
      "pix_fmt": "yuv420p",
      "r_frame_rate": "30000/1001",
      "bit_rate": "6000000",
      "color_space": "bt709",
      "side_data_list": [{"side_data_type": "Display Matrix", "rotation": -90}]
    },
    {
      "index": 1,
      "codec_name": "aac",
      "codec_type": "audio",
      "sample_rate": "48000",
      "channels": 2,
      "bit_rate": "128000",
      "tags": {"language": "eng"}
    }
  ]
}''';
    final media = MediaProbe.parse(json, fallbackSizeBytes: 1);

    expect(media.formatName, contains('mp4'));
    expect(media.durationSeconds, closeTo(12.512, 0.001));
    expect(media.sizeBytes, 10485760);
    expect(media.videoStream!.codecName, 'h264');
    expect(media.videoStream!.width, 1920);
    expect(media.videoStream!.height, 1080);
    expect(media.videoStream!.pixFmt, 'yuv420p');
    // 30000/1001 ≈ 29.97
    expect(media.videoStream!.frameRate, closeTo(29.97, 0.01));
    // display matrix rotation -90 is reported as +90 after sign flip
    expect(media.videoStream!.rotationDegrees, 90);
    expect(media.audioStream!.codecName, 'aac');
    expect(media.audioStream!.channels, 2);
    expect(media.audioStream!.language, 'eng');
    expect(media.isHighBitDepth, isFalse);
  });

  test('parses a Matroska VP9/Opus file with tags.rotate fallback', () {
    const json = '''
{
  "format": {"format_name": "matroska,webm", "duration": "60", "size": "5000"},
  "streams": [
    {"index": 0, "codec_name": "vp9", "codec_type": "video", "width": 1280,
     "height": 720, "r_frame_rate": "24/1", "tags": {"rotate": "180"}},
    {"index": 1, "codec_name": "opus", "codec_type": "audio",
     "sample_rate": "48000", "channels": 6}
  ]
}''';
    final media = MediaProbe.parse(json);
    expect(media.videoStream!.codecName, 'vp9');
    expect(media.videoStream!.frameRate, 24);
    expect(media.videoStream!.rotationDegrees, 180);
    expect(media.formatName, contains('matroska'));
  });

  test('parses a 10-bit source as high bit depth', () {
    const json = '''
{
  "format": {"format_name": "mov,mp4", "duration": "5", "size": "1000"},
  "streams": [
    {"index": 0, "codec_name": "hevc", "codec_type": "video", "width": 3840,
     "height": 2160, "pix_fmt": "yuv420p10le", "r_frame_rate": "60/1"}
  ]
}''';
    final media = MediaProbe.parse(json);
    expect(media.isHighBitDepth, isTrue);
    expect(media.audioStream, isNull);
  });

  test('handles missing duration and zero-rate streams gracefully', () {
    const json = '''
{
  "format": {"format_name": "unknown"},
  "streams": [
    {"index": 0, "codec_name": "h264", "codec_type": "video",
     "r_frame_rate": "0/0"}
  ]
}''';
    final media = MediaProbe.parse(json, fallbackSizeBytes: 42);
    expect(media.durationSeconds, 0);
    expect(media.sizeBytes, 42);
    expect(media.videoStream!.frameRate, isNull);
  });

  test('parses subtitle streams and reports them separately', () {
    const json = '''
{
  "format": {"format_name": "matroska", "duration": "10", "size": "2000"},
  "streams": [
    {"index": 0, "codec_name": "h264", "codec_type": "video", "width": 640, "height": 360},
    {"index": 1, "codec_name": "subrip", "codec_type": "subtitle"}
  ]
}''';
    final media = MediaProbe.parse(json);
    expect(media.subtitleStreams, hasLength(1));
    expect(media.subtitleStreams.first.codecName, 'subrip');
  });
}
