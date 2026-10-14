/// High Dynamic Range (HDR) modes supported across PureCompress.
enum HdrMode {
  /// Preserves the original video's color appearance without enhancement filters.
  off('Off', 'Preserve original color appearance without HDR enhancement'),

  /// Visual enhancement filter applying dynamic contrast, highlights, and shadow tone mapping.
  hdrEffect('HDR Effect', 'Enhanced dynamic range & contrast (visual simulation)'),

  /// Converts SDR video to genuine 10-bit HDR10 (BT.2020 PQ) output.
  sdrToHdr('SDR to HDR', 'Convert SDR to genuine 10-bit HDR10 (BT.2020 PQ)'),

  /// Detects and preserves source 10-bit HDR color gamut, transfer, and metadata.
  preserveHdr('Preserve Original HDR', 'Preserve source 10-bit HDR color gamut & metadata');

  const HdrMode(this.label, this.description);
  final String label;
  final String description;
}

/// Helper for HDR classification and color characteristics.
class HdrCharacteristics {
  HdrCharacteristics._();

  /// Determines whether the given color transfer function indicates HDR.
  static bool isHdrTransfer(String? transfer) {
    if (transfer == null) return false;
    final lower = transfer.toLowerCase();
    return lower == 'smpte2084' ||
        lower == 'arib-std-b67' ||
        lower.contains('2084') ||
        lower.contains('hlg');
  }

  /// Determines whether the given color primaries indicate wide color gamut (BT.2020 / DCI-P3).
  static bool isWideGamut(String? primaries) {
    if (primaries == null) return false;
    final lower = primaries.toLowerCase();
    return lower == 'bt2020' || lower == 'smpte432' || lower.contains('2020');
  }

  /// Determines whether a stream qualifies as HDR content.
  static bool isHdrStream({
    String? transfer,
    String? primaries,
    String? pixFmt,
  }) {
    if (isHdrTransfer(transfer)) return true;
    if (isWideGamut(primaries) && pixFmt != null && pixFmt.contains('10')) {
      return true;
    }
    return false;
  }

  /// Human-friendly description of color transfer function.
  static String formatTransfer(String? transfer) {
    if (transfer == null || transfer.isEmpty) return 'SDR (BT.709)';
    return switch (transfer.toLowerCase()) {
      'smpte2084' => 'PQ (SMPTE ST 2084)',
      'arib-std-b67' => 'HLG (Hybrid Log-Gamma)',
      'bt709' => 'BT.709',
      'iec61966-2-1' => 'sRGB',
      'linear' => 'Linear',
      _ => transfer,
    };
  }

  /// Human-friendly description of color primaries.
  static String formatPrimaries(String? primaries) {
    if (primaries == null || primaries.isEmpty) return 'BT.709';
    return switch (primaries.toLowerCase()) {
      'bt2020' => 'BT.2020 (Wide Gamut)',
      'bt709' => 'BT.709 (Standard)',
      'smpte432' => 'Display P3',
      _ => primaries,
    };
  }
}
