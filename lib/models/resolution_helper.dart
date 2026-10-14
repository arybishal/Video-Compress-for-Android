import 'dart:math' as math;

import 'aspect_ratio_options.dart';

/// Standard target resolution definition with aspect-ratio preservation.
class ResolutionPreset {
  const ResolutionPreset({
    required this.name,
    required this.standardWidth,
    required this.standardHeight,
    required this.maxDimension,
    this.isPortrait = false,
  });

  final String name;
  final int standardWidth;
  final int standardHeight;
  final int maxDimension;
  final bool isPortrait;

  static const p4k = ResolutionPreset(
    name: '4K (3840 × 2160)',
    standardWidth: 3840,
    standardHeight: 2160,
    maxDimension: 3840,
  );

  static const p3_5k = ResolutionPreset(
    name: '3.5K (3440 × 1440)',
    standardWidth: 3440,
    standardHeight: 1440,
    maxDimension: 3440,
  );

  static const p2k = ResolutionPreset(
    name: '2K (2560 × 1440)',
    standardWidth: 2560,
    standardHeight: 1440,
    maxDimension: 2560,
  );

  static const p1080 = ResolutionPreset(
    name: 'Full HD (1920 × 1080)',
    standardWidth: 1920,
    standardHeight: 1080,
    maxDimension: 1920,
  );

  static const p720 = ResolutionPreset(
    name: 'HD (1280 × 720)',
    standardWidth: 1280,
    standardHeight: 720,
    maxDimension: 1280,
  );

  static const p480 = ResolutionPreset(
    name: 'SD (854 × 480)',
    standardWidth: 854,
    standardHeight: 480,
    maxDimension: 854,
  );

  static const p1080Portrait = ResolutionPreset(
    name: '1080 × 1920 (Portrait)',
    standardWidth: 1080,
    standardHeight: 1920,
    maxDimension: 1920,
    isPortrait: true,
  );

  static const p720Portrait = ResolutionPreset(
    name: '720 × 1280 (Portrait)',
    standardWidth: 720,
    standardHeight: 1280,
    maxDimension: 1280,
    isPortrait: true,
  );

  static const List<ResolutionPreset> all = [
    p4k,
    p3_5k,
    p2k,
    p1080,
    p720,
    p480,
    p1080Portrait,
    p720Portrait,
  ];

  static ResolutionPreset? findByDimensions(int? w, int? h) {
    if (w == null || h == null) return null;
    for (final p in all) {
      if (p.standardWidth == w && p.standardHeight == h) {
        return p;
      }
    }
    return null;
  }

  /// Calculates scaled (width, height) preserving aspect ratio without upscaling.
  (int, int) calculateDimensions(int sourceWidth, int sourceHeight) {
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      return (standardWidth, standardHeight);
    }

    final sourceIsPortrait = sourceHeight > sourceWidth;
    final int maxW;
    final int maxH;
    if (isPortrait) {
      maxW = sourceIsPortrait ? standardWidth : standardHeight;
      maxH = sourceIsPortrait ? standardHeight : standardWidth;
    } else {
      maxW = sourceIsPortrait ? standardHeight : standardWidth;
      maxH = sourceIsPortrait ? standardWidth : standardHeight;
    }

    if (sourceWidth <= maxW && sourceHeight <= maxH) {
      // Source already fits within bounds — do not upscale
      return (
        ResolutionHelper.makeEven(sourceWidth),
        ResolutionHelper.makeEven(sourceHeight),
      );
    }

    final scale = math.min(
      maxW / sourceWidth,
      maxH / sourceHeight,
    );
    final newW = ResolutionHelper.makeEven((sourceWidth * scale).round());
    final newH = ResolutionHelper.makeEven((sourceHeight * scale).round());

    return (newW, newH);
  }
}

/// Result of geometry calculation.
class GeometryResult {
  const GeometryResult({
    required this.outputWidth,
    required this.outputHeight,
    required this.filters,
    required this.isCropped,
    required this.isPadded,
    required this.isStretched,
    this.warning,
    this.explanation,
  });

  final int outputWidth;
  final int outputHeight;
  final List<String> filters;
  final bool isCropped;
  final bool isPadded;
  final bool isStretched;
  final String? warning;
  final String? explanation;

  String get outputAspectRatioStr =>
      AspectRatioHelper.formatAspectRatio(outputWidth, outputHeight);
}

/// Helper methods for resolution and aspect ratio processing.
class ResolutionHelper {
  ResolutionHelper._();

  static int makeEven(int n) {
    var v = n - (n % 2);
    if (v < 2) v = 2;
    return v;
  }

  /// Resolves the intended target ratio as a double.
  static double? resolveTargetRatio({
    required AspectRatioOption aspectRatio,
    int? customAspectWidth,
    int? customAspectHeight,
    int? targetWidth,
    int? targetHeight,
  }) {
    if (aspectRatio == AspectRatioOption.custom &&
        customAspectWidth != null &&
        customAspectHeight != null &&
        customAspectHeight > 0) {
      return customAspectWidth / customAspectHeight;
    }
    if (aspectRatio.ratio != null) {
      return aspectRatio.ratio;
    }
    if (targetWidth != null && targetHeight != null && targetHeight > 0) {
      return targetWidth / targetHeight;
    }
    return null;
  }

  /// Calculates the complete geometry plan and FFmpeg filters for video scaling,
  /// padding, and cropping.
  static GeometryResult calculateGeometry({
    required int sourceWidth,
    required int sourceHeight,
    AspectRatioOption aspectRatio = AspectRatioOption.original,
    int? customAspectWidth,
    int? customAspectHeight,
    int? targetWidth,
    int? targetHeight,
    VideoFitPolicy fitPolicy = VideoFitPolicy.preserveOriginal,
  }) {
    final srcW = makeEven(sourceWidth);
    final srcH = makeEven(sourceHeight);
    final srcRatio = srcW / srcH;

    // Resolve target ratio if an explicit aspect ratio is requested
    final targetRatio = resolveTargetRatio(
      aspectRatio: aspectRatio,
      customAspectWidth: customAspectWidth,
      customAspectHeight: customAspectHeight,
    );

    // Determine target canvas dimensions
    int targetCanvasW;
    int targetCanvasH;

    if (targetWidth != null && targetHeight != null) {
      targetCanvasW = makeEven(targetWidth);
      targetCanvasH = makeEven(targetHeight);
    } else if (targetRatio != null) {
      // No resolution selected, but aspect ratio specified
      if (targetRatio >= srcRatio) {
        targetCanvasH = srcH;
        targetCanvasW = makeEven((srcH * targetRatio).round());
      } else {
        targetCanvasW = srcW;
        targetCanvasH = makeEven((srcW / targetRatio).round());
      }
    } else {
      // Both original
      targetCanvasW = srcW;
      targetCanvasH = srcH;
    }

    final canvasRatio = targetCanvasW / targetCanvasH;
    final hasTargetAspectMismatch = targetRatio != null && (targetRatio - srcRatio).abs() > 0.01;
    final hasCanvasMismatch = (srcRatio - canvasRatio).abs() > 0.01;
    final ratioDiffers = hasTargetAspectMismatch || hasCanvasMismatch;

    // Check compatibility between selected aspect ratio and resolution
    String? explanation;
    String? warning;

    if (targetRatio != null && targetWidth != null && targetHeight != null) {
      final resRatio = targetWidth / targetHeight;
      if ((targetRatio - resRatio).abs() > 0.02) {
        final arStr = AspectRatioHelper.formatAspectRatio(
            (targetRatio * 100).round(), 100);
        final resStr = AspectRatioHelper.formatAspectRatio(targetWidth, targetHeight);
        warning = 'Aspect ratio ($arStr) differs from container resolution ($resStr). '
            'Content will be ${fitPolicy == VideoFitPolicy.cropFill ? 'cropped' : 'padded'} to fit.';
      }
    }

    // If source matches canvas and no aspect ratio conversion is needed:
    if (srcW == targetCanvasW && srcH == targetCanvasH && !ratioDiffers && warning == null) {
      return GeometryResult(
        outputWidth: targetCanvasW,
        outputHeight: targetCanvasH,
        filters: const [],
        isCropped: false,
        isPadded: false,
        isStretched: false,
        explanation: 'Source dimensions and aspect ratio match target.',
      );
    }

    // Preserve original aspect ratio without padding/crop (standard scale)
    if (fitPolicy == VideoFitPolicy.preserveOriginal || !ratioDiffers) {
      if (targetWidth == null && targetHeight == null && !ratioDiffers && warning == null) {
        return GeometryResult(
          outputWidth: srcW,
          outputHeight: srcH,
          filters: const [],
          isCropped: false,
          isPadded: false,
          isStretched: false,
          explanation: 'Original resolution & aspect ratio preserved.',
        );
      }

      // Scale proportionally within targetCanvas bounds
      final scale = math.min(
        targetCanvasW / srcW,
        targetCanvasH / srcH,
      );
      final outW = makeEven((srcW * scale).round());
      final outH = makeEven((srcH * scale).round());

      return GeometryResult(
        outputWidth: outW,
        outputHeight: outH,
        filters: ['scale=$outW:$outH'],
        isCropped: false,
        isPadded: false,
        isStretched: false,
        warning: warning,
        explanation: 'Scaled proportionally to fit within $targetCanvasW×$targetCanvasH.',
      );
    }

    // Fit with Padding
    if (fitPolicy == VideoFitPolicy.fitPadding) {
      final double frameW;
      final double frameH;
      if (targetRatio != null && (targetRatio - canvasRatio).abs() > 0.02) {
        if (targetRatio <= canvasRatio) {
          frameH = targetCanvasH.toDouble();
          frameW = makeEven((targetCanvasH * targetRatio).round()).toDouble();
        } else {
          frameW = targetCanvasW.toDouble();
          frameH = makeEven((targetCanvasW / targetRatio).round()).toDouble();
        }
      } else {
        frameW = targetCanvasW.toDouble();
        frameH = targetCanvasH.toDouble();
      }

      final scale = math.min(
        frameW / srcW,
        frameH / srcH,
      );
      final scaledW = makeEven((srcW * scale).round());
      final scaledH = makeEven((srcH * scale).round());

      if (scaledW == targetCanvasW && scaledH == targetCanvasH && warning == null) {
        return GeometryResult(
          outputWidth: targetCanvasW,
          outputHeight: targetCanvasH,
          filters: ['scale=$targetCanvasW:$targetCanvasH'],
          isCropped: false,
          isPadded: false,
          isStretched: false,
          warning: warning,
          explanation: 'Scaled to fit exactly $targetCanvasW×$targetCanvasH.',
        );
      }

      final padX = makeEven(((targetCanvasW - scaledW) / 2).round());
      final padY = makeEven(((targetCanvasH - scaledH) / 2).round());

      explanation = scaledW < targetCanvasW
          ? 'Padded with pillarbox bars on left and right ($targetCanvasW×$targetCanvasH).'
          : 'Padded with letterbox bars on top and bottom ($targetCanvasW×$targetCanvasH).';

      return GeometryResult(
        outputWidth: targetCanvasW,
        outputHeight: targetCanvasH,
        filters: ['scale=$scaledW:$scaledH', 'pad=$targetCanvasW:$targetCanvasH:$padX:$padY:black'],
        isCropped: false,
        isPadded: true,
        isStretched: false,
        warning: warning,
        explanation: explanation,
      );
    }

    // Crop to Fill
    if (fitPolicy == VideoFitPolicy.cropFill) {
      final scale = math.max(
        targetCanvasW / srcW,
        targetCanvasH / srcH,
      );
      final scaledW = makeEven((srcW * scale).round());
      final scaledH = makeEven((srcH * scale).round());

      if (scaledW == targetCanvasW && scaledH == targetCanvasH && warning == null) {
        return GeometryResult(
          outputWidth: targetCanvasW,
          outputHeight: targetCanvasH,
          filters: ['scale=$targetCanvasW:$targetCanvasH'],
          isCropped: false,
          isPadded: false,
          isStretched: false,
          warning: warning,
          explanation: 'Scaled to fill $targetCanvasW×$targetCanvasH without cropping.',
        );
      }

      final cropX = makeEven(((scaledW - targetCanvasW) / 2).round());
      final cropY = makeEven(((scaledH - targetCanvasH) / 2).round());

      warning ??= 'Crop to Fill removes edges of original content to fill $targetCanvasW×$targetCanvasH.';
      explanation = 'Center-cropped to $targetCanvasW×$targetCanvasH (edges removed).';

      return GeometryResult(
        outputWidth: targetCanvasW,
        outputHeight: targetCanvasH,
        filters: ['scale=$scaledW:$scaledH', 'crop=$targetCanvasW:$targetCanvasH:$cropX:$cropY'],
        isCropped: true,
        isPadded: false,
        isStretched: false,
        warning: warning,
        explanation: explanation,
      );
    }

    // Stretch to Fill
    warning = 'Stretch fit will distort people and objects in the video.';
    explanation = 'Stretched to $targetCanvasW×$targetCanvasH (distorted).';

    return GeometryResult(
      outputWidth: targetCanvasW,
      outputHeight: targetCanvasH,
      filters: ['scale=$targetCanvasW:$targetCanvasH'],
      isCropped: false,
      isPadded: false,
      isStretched: true,
      warning: warning,
      explanation: explanation,
    );
  }
}
