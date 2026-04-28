// HLS VOD manifest (.m3u8) reader and writer.
//
// This is a minimal, pure-Dart HLS implementation. It only needs to handle
// the VOD playlist shape that DriveCam produces and consumes locally:
//   - a single media playlist (no master / variant playlists)
//   - one #EXTINF per segment, followed by the relative segment URI
//   - #EXT-X-ENDLIST when the recording is finalised
//
// References:
//   https://datatracker.ietf.org/doc/html/rfc8216  (HLS spec)
//
// Keeping this dependency-free means students can read the whole thing and
// see exactly what a manifest looks like on disk.

import 'dart:convert' show LineSplitter;
import 'dart:io';

/// One entry in a manifest: a relative URI to a segment file and the
/// segment's duration (from the manifest's own `#EXTINF` line, not from
/// inspecting the .mp4).
class SegmentRef {
  final String uri;
  final double durationSecs;

  const SegmentRef({required this.uri, required this.durationSecs});

  @override
  String toString() => 'SegmentRef($uri, ${durationSecs}s)';

  @override
  bool operator ==(Object other) =>
      other is SegmentRef &&
      other.uri == uri &&
      other.durationSecs == durationSecs;

  @override
  int get hashCode => Object.hash(uri, durationSecs);
}

/// Pure functions for building and parsing manifests. Methods that touch the
/// filesystem are kept separate (see [appendSegment], [closeManifest]).
class HlsManifest {
  /// Build a complete manifest string from a list of segments.
  ///
  /// [targetDurationSecs] is the max segment duration that players should be
  /// prepared to buffer. HLS requires this be >= every `#EXTINF`, so pass a
  /// value that comfortably covers the largest real segment (we use
  /// `ceil(segmentTargetDuration)` rounded up by 1 to avoid edge cases where
  /// a segment runs slightly long).
  ///
  /// When [closed] is true the manifest ends with `#EXT-X-ENDLIST`, which is
  /// what we want for finalised recordings. A mid-recording manifest is
  /// written without it so a player can still play what exists so far.
  static String buildManifest(
    List<SegmentRef> segments, {
    required int targetDurationSecs,
    bool closed = true,
  }) {
    final b = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:3')
      ..writeln('#EXT-X-PLAYLIST-TYPE:VOD')
      ..writeln('#EXT-X-TARGETDURATION:$targetDurationSecs')
      ..writeln('#EXT-X-MEDIA-SEQUENCE:0');
    for (final seg in segments) {
      // `,` after the duration is required by the spec (title field, empty).
      b
        ..writeln('#EXTINF:${_formatDuration(seg.durationSecs)},')
        ..writeln(seg.uri);
    }
    if (closed) {
      b.writeln('#EXT-X-ENDLIST');
    }
    return b.toString();
  }

  /// Append one segment entry to an existing open (not closed) manifest file.
  /// Used by [HlsRecordingSession] to keep the on-disk manifest playable
  /// after every rotation — survives app crashes.
  static Future<void> appendSegment(
    File manifestFile,
    SegmentRef segment,
  ) async {
    final line =
        '#EXTINF:${_formatDuration(segment.durationSecs)},\n${segment.uri}\n';
    await manifestFile.writeAsString(line, mode: FileMode.append, flush: true);
  }

  /// Write an initial empty (open) manifest header. Used when a recording
  /// session starts, before any segments exist.
  static Future<void> writeHeader(
    File manifestFile, {
    required int targetDurationSecs,
  }) async {
    final header = '#EXTM3U\n'
        '#EXT-X-VERSION:3\n'
        '#EXT-X-PLAYLIST-TYPE:VOD\n'
        '#EXT-X-TARGETDURATION:$targetDurationSecs\n'
        '#EXT-X-MEDIA-SEQUENCE:0\n';
    await manifestFile.writeAsString(header, flush: true);
  }

  /// Seal a manifest by appending `#EXT-X-ENDLIST`. Safe to call even if it
  /// was already closed (duplicates an endlist line, which players tolerate).
  static Future<void> closeManifest(File manifestFile) async {
    await manifestFile.writeAsString(
      '#EXT-X-ENDLIST\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// Parse a manifest file into an ordered list of segment references.
  /// Lines that aren't #EXTINF/URI pairs are ignored, so we can round-trip
  /// manifests that include standard tags we don't care about.
  static Future<List<SegmentRef>> parseFile(File manifestFile) async {
    final text = await manifestFile.readAsString();
    return parseString(text);
  }

  /// Same as [parseFile] but takes the raw manifest text. Factored out so
  /// the math can be unit-tested without touching the filesystem.
  static List<SegmentRef> parseString(String text) {
    final lines = const LineSplitter().convert(text);
    final out = <SegmentRef>[];
    double? pendingDuration;
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF:')) {
        // #EXTINF:<duration>,<title>  — we only read the duration.
        final after = line.substring('#EXTINF:'.length);
        final commaIdx = after.indexOf(',');
        final durStr = commaIdx >= 0 ? after.substring(0, commaIdx) : after;
        pendingDuration = double.tryParse(durStr);
        continue;
      }
      if (line.startsWith('#')) {
        // Any other tag (#EXT-X-*, comments) is ignored.
        continue;
      }
      // Non-tag line: a segment URI. Only accept it if it was preceded by
      // an #EXTINF, otherwise it's malformed.
      if (pendingDuration != null) {
        out.add(SegmentRef(uri: line, durationSecs: pendingDuration));
        pendingDuration = null;
      }
    }
    return out;
  }

  /// Format a float duration the way HLS expects: a decimal with up to 3
  /// digits after the point, trailing zeros trimmed. Avoids exponent form
  /// that players don't parse.
  static String _formatDuration(double secs) {
    var s = secs.toStringAsFixed(3);
    // Trim trailing zeros and a trailing dot.
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '');
      if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    }
    return s;
  }
}

/// Helpers for segment-range math shared between clip saving and export.
/// Given a list of segments with known durations, these functions map
/// wall-clock session offsets to segment indices and back.
class HlsSegmentMath {
  /// Return the cumulative start offset (in seconds) of each segment in the
  /// list. The first segment starts at 0; segment N starts at the sum of
  /// durations of segments [0..N-1].
  static List<double> cumulativeStarts(List<SegmentRef> segments) {
    final starts = <double>[];
    var acc = 0.0;
    for (final seg in segments) {
      starts.add(acc);
      acc += seg.durationSecs;
    }
    return starts;
  }

  /// Total duration of all segments.
  static double totalDuration(List<SegmentRef> segments) {
    var acc = 0.0;
    for (final seg in segments) {
      acc += seg.durationSecs;
    }
    return acc;
  }

  /// Find the first segment whose end is strictly greater than [timeSecs].
  /// Returns a clamped index in [0, segments.length - 1]; an empty list
  /// returns 0.
  ///
  /// Example: with three 5s segments (ends at 5, 10, 15) the call for t=7
  /// returns 1 (the segment covering [5, 10)).
  static int segmentContaining(List<SegmentRef> segments, double timeSecs) {
    if (segments.isEmpty) return 0;
    if (timeSecs <= 0) return 0;
    var acc = 0.0;
    for (var i = 0; i < segments.length; i++) {
      acc += segments[i].durationSecs;
      if (timeSecs < acc) return i;
    }
    return segments.length - 1;
  }

  /// Given a session-time interval [startSecs, endSecs], return the inclusive
  /// [firstIdx, lastIdx] range of segments that cover it. Endpoints are
  /// snapped outward to whole-segment boundaries — this is the
  /// segment-granular clipping the app has committed to.
  ///
  /// Returns null if the segment list is empty or the requested range is
  /// entirely negative (no overlap).
  static ({int firstIdx, int lastIdx})? rangeCovering(
    List<SegmentRef> segments,
    double startSecs,
    double endSecs,
  ) {
    if (segments.isEmpty) return null;
    if (endSecs <= 0) return null;
    final clampedStart = startSecs < 0 ? 0.0 : startSecs;
    final total = totalDuration(segments);
    final clampedEnd = endSecs > total ? total : endSecs;
    if (clampedEnd <= clampedStart) return null;
    final firstIdx = segmentContaining(segments, clampedStart);
    // For the end, we want the segment whose *start* is strictly less than
    // clampedEnd — i.e. the last segment that overlaps the range.
    // segmentContaining with a value just below clampedEnd gives us that.
    final endProbe = clampedEnd - 1e-6;
    final lastIdx = segmentContaining(segments, endProbe);
    return (firstIdx: firstIdx, lastIdx: lastIdx);
  }
}

