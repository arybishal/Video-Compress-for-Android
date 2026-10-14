import 'package:flutter/material.dart';

/// Central branding & identity. Change these values to rebrand the app.
class AppConfig {
  AppConfig._();

  static const String appName = 'PureCompress';
  static const String androidApplicationId = 'com.pvideocompress.smedia';
  static const String version = '1.0.0';

  /// Privacy statement shown on the Home screen.
  static const String privacyStatement =
      'Videos are processed entirely on this device. '
      'Nothing is uploaded — no cloud, no accounts, no analytics.';

  /// Sub-folder created in the device Movies collection on export.
  static const String exportDirName = 'PureCompress';

  /// Base folder inside the app cache used for job working directories.
  static const String tempDirName = 'purecompress_jobs';

  /// Cache sub-folder holding copies of SAF-picked source videos.
  static const String pickDirName = 'purecompress_pick';

  /// Temp results older than this are removed at startup. Gives the user a
  /// day to save/share a finished result before the working copy is reclaimed.
  static const Duration tempMaxAge = Duration(hours: 24);

  /// Cap for the locally stored job history.
  static const int maxHistoryEntries = 20;

  // Brand colors (Material 3 seed).
  static const Color brandColor = Color(0xFF00696B); // deep teal
  static const Color brandColorDark = Color(0xFF4FD8EB);
}
