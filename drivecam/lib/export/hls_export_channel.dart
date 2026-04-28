// Dart-side wrapper around the Android MediaMuxer-based HLS export.
//
// This is a thin MethodChannel client — all the real work is in
// android/app/src/main/kotlin/com/example/drivecam/HlsExportHandler.kt.
// Keeping the platform call behind a typed Dart API means call sites
// don't need to know the channel name or argument shapes, and they get
// compile-time checking for the argument types.

import 'package:flutter/services.dart';

class HlsExportChannel {
  // Must match HlsExportHandler.CHANNEL on the Kotlin side.
  static const MethodChannel _channel = MethodChannel('drivecam/hls_export');

  /// Remux a list of MP4 segment files into a single MP4 at [outputPath].
  /// No re-encoding happens; the inputs must share codec/format (which all
  /// segments from a single camera session do).
  ///
  /// Throws [PlatformException] on the Kotlin side's error paths, which
  /// callers should catch and present as a user-visible export failure.
  static Future<void> remuxSegments({
    required List<String> segmentPaths,
    required String outputPath,
  }) async {
    await _channel.invokeMethod<void>('remuxSegments', {
      'segmentPaths': segmentPaths,
      'outputPath': outputPath,
    });
  }

  /// Extract the first keyframe from [videoPath] and write it as a JPEG
  /// at [outputPath]. Backed by Android's MediaMetadataRetriever — no
  /// FFmpeg, no third-party packages. [quality] is the JPEG quality 1-100.
  ///
  /// Throws [PlatformException] if the source file is missing or has no
  /// decodable frame.
  static Future<void> extractFirstFrame({
    required String videoPath,
    required String outputPath,
    int quality = 75,
  }) async {
    await _channel.invokeMethod<void>('extractFirstFrame', {
      'videoPath': videoPath,
      'outputPath': outputPath,
      'quality': quality,
    });
  }
}
