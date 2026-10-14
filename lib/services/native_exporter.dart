import 'package:flutter/services.dart';

import '../config/app_config.dart';

/// A video chosen through the system document picker (SAF). [path] points to
/// an app-cache copy; the original document is untouched.
class PickedVideo {
  const PickedVideo({required this.path, required this.name, required this.size});
  final String path;
  final String name;
  final int size;
}

/// Bridges to small native helpers implemented in MainActivity.kt:
///  - SAF video picking (copied to app cache for FFmpeg)
///  - MediaStore export into Movies/PureCompress (no storage permission)
///  - ACTION_VIEW open with an external player
///  - free-space query
class NativeExporter {
  static const _channel = MethodChannel('purecompress/native');

  /// Opens the system picker for any video. Returns null if the user
  /// cancelled.
  Future<PickedVideo?> pickVideo() async {
    final map = await _channel.invokeMapMethod<String, dynamic>('pickVideo');
    if (map == null) return null;
    return PickedVideo(
      path: map['path'] as String,
      name: map['name'] as String,
      size: (map['size'] as num?)?.toInt() ?? 0,
    );
  }

  /// Copies [srcPath] into the device Movies/PureCompress collection via
  /// MediaStore. Returns the content Uri of the saved video.
  Future<String> exportToMovies(String srcPath, String displayName) async {
    final uri = await _channel.invokeMethod<String>('exportToMovies', {
      'srcPath': srcPath,
      'displayName': displayName,
      'dirName': AppConfig.exportDirName,
      'mimeType': _mimeTypeFor(displayName),
    });
    if (uri == null) {
      throw const ExportException('Could not save the video to your device.');
    }
    return uri;
  }

  /// Opens [path] with an installed video player (ACTION_VIEW).
  Future<void> openWith(String path) async {
    await _channel.invokeMethod<void>('openWith', {
      'path': path,
      'mimeType': _mimeTypeFor(path),
    });
  }

  /// Free bytes available for the app (data + cache volume).
  Future<int?> freeBytes() =>
      _channel.invokeMethod<int>('freeBytes', {'path': ''}).catchError((_) => null);

  static String _mimeTypeFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.avi')) return 'video/x-msvideo';
    return 'video/mp4';
  }
}

class ExportException implements Exception {
  const ExportException(this.message);
  final String message;
  @override
  String toString() => message;
}
