import 'dart:convert';

import '../models/models.dart';

/// Parses ffprobe `-print_format json -show_format -show_streams` output into
/// [MediaInfo]. Pure Dart so it is unit-testable with fixture JSON.
class MediaProbe {
  MediaProbe._();

  static MediaInfo parse(String ffprobeJson, {int fallbackSizeBytes = 0}) {
    final Map<String, dynamic> root = jsonDecode(ffprobeJson) as Map<String, dynamic>;
    final format = (root['format'] ?? <String, dynamic>{}) as Map<String, dynamic>;
    final rawStreams = (root['streams'] ?? const []) as List<dynamic>;

    final streams = <StreamInfo>[];
    for (final s in rawStreams) {
      final m = s as Map<String, dynamic>;
      streams.add(_parseStream(m));
    }

    final tags = <String, String>{};
    final rawTags = (format['tags'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    rawTags.forEach((k, v) => tags[k.toLowerCase()] = '$v');

    final size = int.tryParse('${format['size'] ?? ''}') ?? fallbackSizeBytes;

    return MediaInfo(
      formatName: (format['format_name'] ?? 'unknown') as String,
      durationSeconds: double.tryParse('${format['duration'] ?? ''}') ?? 0,
      sizeBytes: size,
      bitRate: int.tryParse('${format['bit_rate'] ?? ''}') ?? 0,
      streams: streams,
      tags: tags,
      probeScore: int.tryParse('${format['probe_score'] ?? ''}') ?? 0,
    );
  }

  static StreamInfo _parseStream(Map<String, dynamic> m) {
    final sideData = (m['side_data_list'] ?? const []) as List<dynamic>;
    var rotation = 0;
    for (final sd in sideData) {
      final sdMap = sd as Map<String, dynamic>;
      final r = sdMap['rotation'];
      if (r != null) {
        final val = (r is num) ? r.toInt() : int.tryParse('$r') ?? 0;
        // ffprobe reports rotation in a display-matrix with inverted sign.
        rotation = -val;
        if (rotation % 90 != 0) rotation = val;
      }
    }
    if (rotation == 0) {
      final tagRot = m['tags'] is Map ? (m['tags'] as Map)['rotate'] : null;
      if (tagRot != null) rotation = int.tryParse('$tagRot') ?? 0;
    }

    final tags = m['tags'] is Map
        ? (m['tags'] as Map).map((k, v) => MapEntry('$k'.toLowerCase(), '$v'))
        : <String, String>{};

    return StreamInfo(
      index: int.tryParse('${m['index'] ?? 0}') ?? 0,
      codecType: '${m['codec_type'] ?? 'unknown'}',
      codecName: '${m['codec_name'] ?? 'unknown'}',
      width: (m['width'] as num?)?.toInt(),
      height: (m['height'] as num?)?.toInt(),
      pixFmt: m['pix_fmt'] as String?,
      frameRate: _parseRate(m['r_frame_rate'] as String?),
      bitRate: int.tryParse('${m['bit_rate'] ?? ''}'),
      sampleRate: int.tryParse('${m['sample_rate'] ?? ''}'),
      channels: (m['channels'] as num?)?.toInt(),
      colorSpace: m['color_space'] as String?,
      colorTransfer: m['color_transfer'] as String?,
      colorPrimaries: m['color_primaries'] as String?,
      colorRange: m['color_range'] as String?,
      rotationDegrees: rotation % 360,
      language: tags['language'],
      title: tags['title'],
    );
  }

  /// Parses '30000/1001' style rates; returns null for 0/0.
  static double? _parseRate(String? rate) {
    if (rate == null || rate.isEmpty) return null;
    final parts = rate.split('/');
    if (parts.length == 2) {
      final nume = double.tryParse(parts[0]);
      final deno = double.tryParse(parts[1]);
      if (nume == null || deno == null || deno == 0) return null;
      final v = nume / deno;
      return v == 0 ? null : v;
    }
    final v = double.tryParse(rate);
    return (v == null || v == 0) ? null : v;
  }
}
