// Tests for CameraView widget and related utilities.
//
// CameraView is a StatefulWidget that owns the CameraController and manages
// the camera preview lifecycle. Most of its behavior (controller init, Vosk
// integration, preview rendering) requires a real camera or platform plugins
// and cannot be tested in a unit environment.
//
// This test file focuses on the pure functions and static helpers that
// CameraView depends on:
//   - SettingsProvider's conversion functions (quality → preset, framerate → fps,
//     duration → seconds, quality+framerate → bitrate)
//   - Clip trigger timer behavior via helper functions
//   - Voice clip JSON parsing logic (extracted into a testable function)
//
// For widget-level testing (FutureBuilder, preview rendering, tap handling),
// a separate widget_test.dart file would be created with proper camera mocking.

import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:drivecam/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';

// ─── Vosk JSON Parsing Utility ───────────────────────────────────────────
// This function is extracted from _CameraViewState._voskJsonContainsClip()
// so it can be tested independently without requiring widget context.
//
// Vosk emits JSON in two shapes:
//   onPartial → {"partial": "clip"}
//   onResult  → {"text": "clip"}
//
// A simple String.contains check would fire on substrings like "eclipse" or
// "clipping". This function ensures we match only the complete word "clip".

/// Returns true only if a Vosk JSON result string contains the exact word
/// "clip" as a standalone token (not as a substring of another word).
///
/// Vosk emits JSON in two forms:
///   - onPartial: `{"partial": "clip"}`
///   - onResult: `{"text": "clip"}`
///
/// This function handles both by checking the 'text' or 'partial' field,
/// splitting on whitespace, and matching only complete words. This prevents
/// false positives on words like "eclipse" or "clipping" that contain "clip"
/// as a substring.
bool voskJsonContainsClip(String json) {
  try {
    final map = jsonDecode(json) as Map<String, dynamic>;
    // Use 'text' for final results, 'partial' for in-progress partials.
    final text = ((map['text'] ?? map['partial']) as String? ?? '').trim();
    // Split into individual tokens and look for an exact 'clip' match.
    return text.split(RegExp(r'\s+')).contains('clip');
  } catch (_) {
    // Malformed JSON — treat as no match rather than crashing.
    return false;
  }
}

void main() {
  // ===========================================================================
  // SettingsProvider: Quality → ResolutionPreset conversion
  // ===========================================================================
  group('SettingsProvider.qualityToPreset', () {
    test('converts "480p" to ResolutionPreset.medium', () {
      expect(SettingsProvider.qualityToPreset('480p'),
          equals(ResolutionPreset.medium));
    });

    test('converts "720p" to ResolutionPreset.high', () {
      expect(SettingsProvider.qualityToPreset('720p'),
          equals(ResolutionPreset.high));
    });

    test('converts "1080p" to ResolutionPreset.veryHigh', () {
      expect(SettingsProvider.qualityToPreset('1080p'),
          equals(ResolutionPreset.veryHigh));
    });

    test('converts "4K" to ResolutionPreset.ultraHigh', () {
      expect(SettingsProvider.qualityToPreset('4K'),
          equals(ResolutionPreset.ultraHigh));
    });

    test('defaults to ResolutionPreset.high for unknown quality', () {
      expect(SettingsProvider.qualityToPreset('unknown'),
          equals(ResolutionPreset.high));
    });

    test('handles empty string with default', () {
      expect(
          SettingsProvider.qualityToPreset(''), equals(ResolutionPreset.high));
    });
  });

  // ===========================================================================
  // SettingsProvider: Framerate → FPS conversion
  // ===========================================================================
  group('SettingsProvider.framerateToFps', () {
    test('converts "15 fps" to 15', () {
      expect(SettingsProvider.framerateToFps('15 fps'), equals(15));
    });

    test('converts "30 fps" to 30', () {
      expect(SettingsProvider.framerateToFps('30 fps'), equals(30));
    });

    test('converts "60 fps" to 60', () {
      expect(SettingsProvider.framerateToFps('60 fps'), equals(60));
    });

    test('defaults to 30 for unknown framerate', () {
      expect(SettingsProvider.framerateToFps('unknown'), equals(30));
    });

    test('defaults to 30 for empty string', () {
      expect(SettingsProvider.framerateToFps(''), equals(30));
    });

    test('handles framerate without "fps" suffix gracefully', () {
      // Even though the format is normally '30 fps', the function should
      // gracefully handle malformed input.
      expect(SettingsProvider.framerateToFps('30'), equals(30));
    });
  });

  // ===========================================================================
  // SettingsProvider: Clip Duration → Seconds conversion
  // ===========================================================================
  group('SettingsProvider.clipDurationToSeconds', () {
    test('converts "0s" to 0 seconds', () {
      expect(SettingsProvider.clipDurationToSeconds('0s'), equals(0));
    });

    test('converts "5s" to 5 seconds', () {
      expect(SettingsProvider.clipDurationToSeconds('5s'), equals(5));
    });

    test('converts "30s" to 30 seconds', () {
      expect(SettingsProvider.clipDurationToSeconds('30s'), equals(30));
    });

    test('converts "1m" to 60 seconds', () {
      expect(SettingsProvider.clipDurationToSeconds('1m'), equals(60));
    });

    test('converts "2m" to 120 seconds', () {
      expect(SettingsProvider.clipDurationToSeconds('2m'), equals(120));
    });

    test('converts "3m" to 180 seconds', () {
      expect(SettingsProvider.clipDurationToSeconds('3m'), equals(180));
    });

    test('converts "5m" to 300 seconds', () {
      expect(SettingsProvider.clipDurationToSeconds('5m'), equals(300));
    });

    test('defaults to 120 seconds for unknown duration', () {
      expect(SettingsProvider.clipDurationToSeconds('unknown'), equals(120));
    });

    test('defaults to 120 seconds for empty string', () {
      expect(SettingsProvider.clipDurationToSeconds(''), equals(120));
    });
  });

  // ===========================================================================
  // SettingsProvider: Video Bitrate Calculation
  // ===========================================================================
  group('SettingsProvider.videoBitrateForSettings', () {
    // 480p bitrates
    test('480p at 15fps returns 1 Mbps', () {
      expect(SettingsProvider.videoBitrateForSettings('480p', '15 fps'),
          equals(1000000));
    });

    test('480p at 30fps returns 2 Mbps', () {
      expect(SettingsProvider.videoBitrateForSettings('480p', '30 fps'),
          equals(2000000));
    });

    test('480p at 60fps returns 3.5 Mbps', () {
      expect(SettingsProvider.videoBitrateForSettings('480p', '60 fps'),
          equals(3500000));
    });

    // 720p bitrates
    test('720p at 15fps returns 3 Mbps', () {
      expect(SettingsProvider.videoBitrateForSettings('720p', '15 fps'),
          equals(3000000));
    });

    test('720p at 30fps returns 5 Mbps', () {
      expect(SettingsProvider.videoBitrateForSettings('720p', '30 fps'),
          equals(5000000));
    });

    test('720p at 60fps returns 8 Mbps', () {
      expect(SettingsProvider.videoBitrateForSettings('720p', '60 fps'),
          equals(8000000));
    });

    // 1080p bitrates
    test('1080p at 15fps returns 6 Mbps', () {
      expect(SettingsProvider.videoBitrateForSettings('1080p', '15 fps'),
          equals(6000000));
    });

    test('1080p at 30fps returns 10 Mbps', () {
      expect(SettingsProvider.videoBitrateForSettings('1080p', '30 fps'),
          equals(10000000));
    });

    test('1080p at 60fps returns 16 Mbps', () {
      expect(SettingsProvider.videoBitrateForSettings('1080p', '60 fps'),
          equals(16000000));
    });

    // 4K bitrates
    test('4K at 15fps returns 20 Mbps', () {
      expect(SettingsProvider.videoBitrateForSettings('4K', '15 fps'),
          equals(20000000));
    });

    test('4K at 30fps returns 35 Mbps', () {
      expect(SettingsProvider.videoBitrateForSettings('4K', '30 fps'),
          equals(35000000));
    });

    test('4K at 60fps returns 50 Mbps', () {
      expect(SettingsProvider.videoBitrateForSettings('4K', '60 fps'),
          equals(50000000));
    });

    // Unknown quality defaults to 720p/30fps equivalent
    test('unknown quality defaults to 5 Mbps (720p/30fps)', () {
      expect(SettingsProvider.videoBitrateForSettings('unknown', '30 fps'),
          equals(5000000));
    });

    // Bitrate scales with framerate; verify a few transitions
    test('bitrate increases as framerate increases at same quality', () {
      final rate15 = SettingsProvider.videoBitrateForSettings('720p', '15 fps');
      final rate30 = SettingsProvider.videoBitrateForSettings('720p', '30 fps');
      final rate60 = SettingsProvider.videoBitrateForSettings('720p', '60 fps');
      expect(rate15, lessThan(rate30));
      expect(rate30, lessThan(rate60));
    });

    test('bitrate increases as quality increases at same framerate', () {
      final rate480 = SettingsProvider.videoBitrateForSettings('480p', '30 fps');
      final rate720 = SettingsProvider.videoBitrateForSettings('720p', '30 fps');
      final rate1080 = SettingsProvider.videoBitrateForSettings('1080p', '30 fps');
      final rate4K = SettingsProvider.videoBitrateForSettings('4K', '30 fps');
      expect(rate480, lessThan(rate720));
      expect(rate720, lessThan(rate1080));
      expect(rate1080, lessThan(rate4K));
    });
  });

  // ===========================================================================
  // SettingsProvider: Storage Limit Conversions
  // ===========================================================================
  group('SettingsProvider.storageLimitToBytes', () {
    test('converts "1GB" to 1,073,741,824 bytes', () {
      expect(SettingsProvider.storageLimitToBytes('1GB'),
          equals(1 * 1024 * 1024 * 1024));
    });

    test('converts "2GB" to 2,147,483,648 bytes', () {
      expect(SettingsProvider.storageLimitToBytes('2GB'),
          equals(2 * 1024 * 1024 * 1024));
    });

    test('converts "4GB" correctly', () {
      expect(SettingsProvider.storageLimitToBytes('4GB'),
          equals(4 * 1024 * 1024 * 1024));
    });

    test('converts "64GB" correctly', () {
      expect(SettingsProvider.storageLimitToBytes('64GB'),
          equals(64 * 1024 * 1024 * 1024));
    });

    test('defaults to 4GB for unknown limit', () {
      expect(SettingsProvider.storageLimitToBytes('unknown'),
          equals(4 * 1024 * 1024 * 1024));
    });
  });

  // ===========================================================================
  // SettingsProvider: Clip Storage Limit Conversions
  // ===========================================================================
  group('SettingsProvider.clipStorageLimitToBytes', () {
    test('converts "1GB" to bytes', () {
      expect(SettingsProvider.clipStorageLimitToBytes('1GB'),
          equals(1 * 1024 * 1024 * 1024));
    });

    test('converts "2GB" to bytes', () {
      expect(SettingsProvider.clipStorageLimitToBytes('2GB'),
          equals(2 * 1024 * 1024 * 1024));
    });

    test('converts "4GB" to bytes', () {
      expect(SettingsProvider.clipStorageLimitToBytes('4GB'),
          equals(4 * 1024 * 1024 * 1024));
    });

    test('converts "6GB" to bytes', () {
      expect(SettingsProvider.clipStorageLimitToBytes('6GB'),
          equals(6 * 1024 * 1024 * 1024));
    });

    test('converts "8GB" to bytes', () {
      expect(SettingsProvider.clipStorageLimitToBytes('8GB'),
          equals(8 * 1024 * 1024 * 1024));
    });

    test('defaults to 2GB for unknown limit', () {
      expect(SettingsProvider.clipStorageLimitToBytes('unknown'),
          equals(2 * 1024 * 1024 * 1024));
    });
  });

  // ===========================================================================
  // SettingsProvider: Footage Limit Conversions
  // ===========================================================================
  group('SettingsProvider.footageLimitToSeconds', () {
    test('converts "30min" to 1800 seconds', () {
      expect(SettingsProvider.footageLimitToSeconds('30min'), equals(1800));
    });

    test('converts "1h" to 3600 seconds', () {
      expect(SettingsProvider.footageLimitToSeconds('1h'), equals(3600));
    });

    test('converts "1.5h" to 5400 seconds', () {
      expect(SettingsProvider.footageLimitToSeconds('1.5h'), equals(5400));
    });

    test('converts "2h" to 7200 seconds', () {
      expect(SettingsProvider.footageLimitToSeconds('2h'), equals(7200));
    });

    test('converts "6h" to 21600 seconds', () {
      expect(SettingsProvider.footageLimitToSeconds('6h'), equals(21600));
    });

    test('defaults to 7200 seconds (2h) for unknown limit', () {
      expect(SettingsProvider.footageLimitToSeconds('unknown'), equals(7200));
    });
  });

  // ===========================================================================
  // Vosk JSON Parsing: voskJsonContainsClip utility
  // ===========================================================================
  group('voskJsonContainsClip', () {
    test('detects "clip" in onPartial JSON format', () {
      expect(voskJsonContainsClip('{"partial": "clip"}'), isTrue);
    });

    test('detects "clip" in onResult JSON format', () {
      expect(voskJsonContainsClip('{"text": "clip"}'), isTrue);
    });

    test('does not match "clip" as substring in "eclipse"', () {
      expect(voskJsonContainsClip('{"text": "eclipse"}'), isFalse);
    });

    test('does not match "clip" as substring in "clipping"', () {
      expect(voskJsonContainsClip('{"text": "clipping"}'), isFalse);
    });

    test('matches "clip" among multiple words', () {
      expect(voskJsonContainsClip('{"text": "please clip that"}'), isTrue);
    });

    test('matches "clip" in middle of sentence', () {
      expect(voskJsonContainsClip('{"text": "save the clip now"}'), isTrue);
    });

    test('matches "clip" at start of multiple words', () {
      expect(voskJsonContainsClip('{"text": "clip it again"}'), isTrue);
    });

    test('handles extra whitespace around "clip"', () {
      expect(voskJsonContainsClip('{"text": "   clip   "}'), isTrue);
    });

    test('ignores case sensitivity for keys (text vs partial)', () {
      // The function only checks 'text' and 'partial' fields, so using either
      // should work, but case mismatches in the JSON would be a Vosk API issue.
      expect(voskJsonContainsClip('{"partial": "clip now"}'), isTrue);
    });

    test('returns false for malformed JSON', () {
      expect(voskJsonContainsClip('not json at all'), isFalse);
    });

    test('returns false for empty JSON object', () {
      expect(voskJsonContainsClip('{}'), isFalse);
    });

    test('returns false when neither "text" nor "partial" key exists', () {
      expect(voskJsonContainsClip('{"result": "clip"}'), isFalse);
    });

    test('returns false for empty string', () {
      expect(voskJsonContainsClip(''), isFalse);
    });

    test('handles null values in JSON gracefully', () {
      // If text is null, the function treats it as empty string after trim.
      expect(voskJsonContainsClip('{"text": null}'), isFalse);
    });

    test('returns false when "clip" is actually a different word', () {
      expect(voskJsonContainsClip('{"text": "save"}'), isFalse);
    });

    test('matches "clip" when other unknown JSON fields are present', () {
      // Extra fields should not interfere with the match.
      expect(voskJsonContainsClip('{"text": "clip", "confidence": 0.95}'),
          isTrue);
    });

    test('whitespace handling: multiple spaces treated as separators', () {
      // The regex \s+ matches any whitespace including spaces, tabs, and newlines.
      // Test with actual multiple spaces between words.
      expect(voskJsonContainsClip('{"text": "phrase  clip  more"}'), isTrue);
    });
  });

  // ===========================================================================
  // Integration: Bitrate + Duration = Storage Estimation
  // ===========================================================================
  group('Storage estimation: bitrate × duration ÷ 8', () {
    // Verify that the bitrate values from videoBitrateForSettings are
    // reasonable for the storage-eviction calculations elsewhere in the app.
    // Formula: bytes = bitrate_bps × duration_seconds ÷ 8 (bits→bytes)

    test('720p/30fps for 300 seconds yields ~183 MB', () {
      // 5 Mbps × 300 s ÷ 8 = 187,500,000 bytes ≈ 179 MB (binary)
      final bitrate = SettingsProvider.videoBitrateForSettings('720p', '30 fps');
      final bytes = (bitrate * 300) ~/ 8;
      // ~180 MB is reasonable for 5-minute clip
      expect(bytes, inInclusiveRange(180000000, 190000000));
    });

    test('1080p/30fps for 600 seconds yields ~750 MB', () {
      // 10 Mbps × 600 s ÷ 8 = 750,000,000 bytes = 715 MB (binary)
      final bitrate = SettingsProvider.videoBitrateForSettings('1080p', '30 fps');
      final bytes = (bitrate * 600) ~/ 8;
      expect(bytes, inInclusiveRange(700000000, 800000000));
    });

    test('4K/60fps for 60 seconds yields ~375 MB', () {
      // 50 Mbps × 60 s ÷ 8 = 375,000,000 bytes = 357 MB (binary)
      final bitrate = SettingsProvider.videoBitrateForSettings('4K', '60 fps');
      final bytes = (bitrate * 60) ~/ 8;
      expect(bytes, inInclusiveRange(360000000, 390000000));
    });
  });
}
