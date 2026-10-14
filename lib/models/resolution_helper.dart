import 'dart:math' as math;

/// Standard target resolution definition with aspect-ratio preservation.
class ResolutionPreset {
  const ResolutionPreset({
    required this.name,
    required this.standardWidth,
    required this.standardHeight,
    required this.maxDimension,
  });

  final String name;
  final int standardWidth;
  final int standardHeight;
  final int maxDimension;

  static const p4k = ResolutionPreset(
    name: '4K',
    standardWidth: 3840,
    standardHeight: 2160,
    maxDimension: 3840,
  );

  static const p3_5k = ResolutionPreset(
    name: '3.5K',
    standardWidth: 3200,
    standardHeight: 1800,
    maxDimension: 3200,
  );

  static const p2k = ResolutionPreset(
    name: '2K',
    standardWidth: 2560,
    standardHeight: 1440,
    maxDimension: 2560,
  );

  static const p1080 = ResolutionPreset(
    name: '1080p',
    standardWidth: 1920,
    standardHeight: 1080,
    maxDimension: 1920,
  );

  static const p720 = ResolutionPreset(
    name: '720p',
    standardWidth: 1280,
    standardHeight: 720,
    maxDimension: 1280,
  );

  static const p480 = ResolutionPreset(
    name: '480p',
    standardWidth: 854,
    standardHeight: 480,
    maxDimension: 854,
  );

  static const List<ResolutionPreset> all = [
    p4k,
    p3_5k,
    p2k,
    p1080,
    p720,
    p480,
  ];

  /// Calculates scaled (width, height) for [sourceWidth] and [sourceHeight],
  /// preserving aspect ratio, preventing upscaling, and ensuring even dimensions.
  (int, int) calculateDimensions(int sourceWidth, int sourceHeight) {
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      return (standardWidth, standardHeight);
    }

    final isPortrait = sourceHeight > sourceWidth;
    final maxW = isPortrait ? standardHeight : standardWidth;
    final maxH = isPortrait ? standardWidth : standardHeight;

    if (sourceWidth <= maxW && sourceHeight <= maxH) {
      // Source is already within bounds — do not upscale!
      return (
        sourceWidth - (sourceWidth % 2),
        sourceHeight - (sourceHeight % 2),
      );
    }

    final scale = math.min(maxW / sourceWidth, maxH / sourceHeight);
    var newW = (sourceWidth * scale).round();
    var newH = (sourceHeight * scale).round();

    // Ensure even dimensions for YUV formats
    newW = newW - (newW % 2);
    newH = newH - (newH % 2);
    if (newW < 2) newW = 2;
    if (newH < 2) newH = 2;

    return (newW, newH);
  }
}
