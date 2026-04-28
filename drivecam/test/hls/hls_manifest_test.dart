// Unit tests for the pure-Dart HLS manifest builder/parser and segment
// range math. These are the tightest possible check on the core primitives
// behind HLS recording, clip-saving, and export — all pure functions with
// no Flutter or filesystem dependencies, so they run in milliseconds.

import 'package:drivecam/hls/hls_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildManifest', () {
    test('writes all required tags plus endlist when closed', () {
      final text = HlsManifest.buildManifest(const [
        SegmentRef(uri: 'seg_00000.mp4', durationSecs: 5.0),
        SegmentRef(uri: 'seg_00001.mp4', durationSecs: 4.8),
      ], targetDurationSecs: 6);

      expect(text, contains('#EXTM3U'));
      expect(text, contains('#EXT-X-VERSION:3'));
      expect(text, contains('#EXT-X-PLAYLIST-TYPE:VOD'));
      expect(text, contains('#EXT-X-TARGETDURATION:6'));
      expect(text, contains('#EXTINF:5,'));
      expect(text, contains('seg_00000.mp4'));
      expect(text, contains('#EXTINF:4.8,'));
      expect(text, contains('seg_00001.mp4'));
      expect(text, contains('#EXT-X-ENDLIST'));
    });

    test('omits endlist when closed is false (mid-recording playable)', () {
      final text = HlsManifest.buildManifest(
        const [SegmentRef(uri: 'seg_00000.mp4', durationSecs: 5.0)],
        targetDurationSecs: 6,
        closed: false,
      );
      expect(text.contains('#EXT-X-ENDLIST'), isFalse);
    });
  });

  group('parseString', () {
    test('round-trips a manifest we wrote ourselves', () {
      final input = HlsManifest.buildManifest(const [
        SegmentRef(uri: 'a.mp4', durationSecs: 5.0),
        SegmentRef(uri: 'b.mp4', durationSecs: 4.321),
        SegmentRef(uri: 'c.mp4', durationSecs: 0.1),
      ], targetDurationSecs: 6);
      final segments = HlsManifest.parseString(input);
      expect(segments, hasLength(3));
      expect(segments[0].uri, 'a.mp4');
      expect(segments[0].durationSecs, closeTo(5.0, 1e-9));
      expect(segments[1].uri, 'b.mp4');
      expect(segments[1].durationSecs, closeTo(4.321, 1e-9));
      expect(segments[2].uri, 'c.mp4');
      expect(segments[2].durationSecs, closeTo(0.1, 1e-9));
    });

    test('ignores unrelated tags between EXTINF/URI pairs', () {
      const raw = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-DISCONTINUITY
#EXTINF:5.0,some title
seg0.mp4
# a comment we should ignore
#EXTINF:4.5,
seg1.mp4
#EXT-X-ENDLIST
''';
      final segments = HlsManifest.parseString(raw);
      expect(segments, hasLength(2));
      expect(segments[0].uri, 'seg0.mp4');
      expect(segments[1].durationSecs, closeTo(4.5, 1e-9));
    });

    test('malformed EXTINF lines are skipped rather than crashing', () {
      const raw = '''
#EXTM3U
#EXTINF:not-a-number,
bad.mp4
#EXTINF:3.2,
good.mp4
''';
      final segments = HlsManifest.parseString(raw);
      expect(segments, hasLength(1));
      expect(segments.single.uri, 'good.mp4');
    });
  });

  group('HlsSegmentMath', () {
    const fiveSec = [
      SegmentRef(uri: 's0.mp4', durationSecs: 5.0),
      SegmentRef(uri: 's1.mp4', durationSecs: 5.0),
      SegmentRef(uri: 's2.mp4', durationSecs: 5.0),
      SegmentRef(uri: 's3.mp4', durationSecs: 5.0),
    ];

    test('cumulativeStarts and totalDuration', () {
      expect(HlsSegmentMath.cumulativeStarts(fiveSec), [0.0, 5.0, 10.0, 15.0]);
      expect(HlsSegmentMath.totalDuration(fiveSec), 20.0);
    });

    test('segmentContaining clamps negatives and over-range values', () {
      expect(HlsSegmentMath.segmentContaining(fiveSec, -3), 0);
      expect(HlsSegmentMath.segmentContaining(fiveSec, 0), 0);
      expect(HlsSegmentMath.segmentContaining(fiveSec, 4.999), 0);
      expect(HlsSegmentMath.segmentContaining(fiveSec, 5.0), 1);
      expect(HlsSegmentMath.segmentContaining(fiveSec, 7.5), 1);
      expect(HlsSegmentMath.segmentContaining(fiveSec, 19.9), 3);
      // Past the end: clamps to the last segment.
      expect(HlsSegmentMath.segmentContaining(fiveSec, 999), 3);
    });

    test('rangeCovering picks segments covering [start, end]', () {
      final r1 = HlsSegmentMath.rangeCovering(fiveSec, 3, 12);
      expect(r1?.firstIdx, 0);
      expect(r1?.lastIdx, 2);

      // Exact boundary: start at a segment edge picks that segment, not
      // the one before.
      final r2 = HlsSegmentMath.rangeCovering(fiveSec, 5, 15);
      expect(r2?.firstIdx, 1);
      expect(r2?.lastIdx, 2);

      // Degenerate/empty range returns null.
      expect(HlsSegmentMath.rangeCovering(fiveSec, 5, 5), isNull);
      expect(HlsSegmentMath.rangeCovering(fiveSec, 999, 9999), isNull);
      expect(HlsSegmentMath.rangeCovering(const [], 0, 5), isNull);
    });

    test('rangeCovering clamps out-of-bounds endpoints', () {
      final r = HlsSegmentMath.rangeCovering(fiveSec, -5, 9999);
      expect(r?.firstIdx, 0);
      expect(r?.lastIdx, 3);
    });
  });
}
