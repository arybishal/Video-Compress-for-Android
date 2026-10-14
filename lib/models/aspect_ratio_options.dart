/// Selectable aspect ratio presets and custom option.
enum AspectRatioOption {
  original('Original', 'Preserve original aspect ratio', null, null),
  ar9_16('9:16 Portrait', 'Standard vertical video for TikTok, Reels, Shorts', 9, 16),
  ar16_9('16:9 Landscape', 'Widescreen video for YouTube, TV, Desktop', 16, 9),
  ar1_1('1:1 Square', 'Square format for Instagram Feed, Facebook', 1, 1),
  ar4_5('4:5 Portrait Social', 'Optimal vertical feed portrait for Instagram', 4, 5),
  ar3_4('3:4 Portrait', 'Classic portrait photo/video format', 3, 4),
  ar4_3('4:3 Landscape', 'Standard classic TV and monitor format', 4, 3),
  custom('Custom', 'User-defined aspect ratio', null, null);

  const AspectRatioOption(this.label, this.description, this.ratioWidth, this.ratioHeight);
  final String label;
  final String description;
  final int? ratioWidth;
  final int? ratioHeight;

  double? get ratio => (ratioWidth != null && ratioHeight != null && ratioHeight! > 0)
      ? ratioWidth! / ratioHeight!
      : null;
}

/// Explicit output-fit policy when source aspect ratio differs from target frame.
enum VideoFitPolicy {
  preserveOriginal('Preserve Original', 'Maintain source dimensions & aspect ratio without padding or cropping'),
  fitPadding('Fit with Padding', 'Fit full video inside the frame; add black bars where needed (safe for all content)'),
  cropFill('Crop to Fill', 'Fill entire frame by center-cropping excess edges (no black bars, may trim edges)'),
  stretch('Stretch to Fill', 'Distort/stretch image to match target frame (causes distortion)');

  const VideoFitPolicy(this.label, this.description);
  final String label;
  final String description;
}

/// Helper methods for aspect ratio calculations and formatting.
class AspectRatioHelper {
  AspectRatioHelper._();

  static int gcd(int a, int b) {
    var x = a.abs();
    var y = b.abs();
    while (y != 0) {
      final t = y;
      y = x % y;
      x = t;
    }
    return x == 0 ? 1 : x;
  }

  /// Formats (w, h) into a standard ratio string (e.g. "16:9", "9:16", "1:1", "4:3").
  static String formatAspectRatio(int width, int height) {
    if (width <= 0 || height <= 0) return 'Unknown';
    final d = gcd(width, height);
    final w = width ~/ d;
    final h = height ~/ d;

    // Detect common standard aspect ratios with tolerance for non-exact pixel counts
    final r = width / height;
    if ((r - 16 / 9).abs() < 0.02) return '16:9';
    if ((r - 9 / 16).abs() < 0.02) return '9:16';
    if ((r - 1.0).abs() < 0.02) return '1:1';
    if ((r - 4 / 3).abs() < 0.02) return '4:3';
    if ((r - 3 / 4).abs() < 0.02) return '3:4';
    if ((r - 4 / 5).abs() < 0.02) return '4:5';
    if ((r - 21 / 9).abs() < 0.03) return '21:9';

    if (w <= 32 && h <= 32) return '$w:$h';
    return '${(r).toStringAsFixed(2)}:1';
  }
}
