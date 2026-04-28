// ClipProvider — owns clip saving, clip-notification state, and the
// pre/post duration countdown.
//
// In the HLS world a clip is not a new video file. It is a *sub-manifest*
// that references a contiguous range of segments from an existing
// recording (or from the live in-progress recording). No re-encoding
// happens; the clip directory holds only a manifest.m3u8 that points at
// the source segments via relative paths.
//
// This gives us:
//   - zero extra disk cost per clip (aside from the manifest + thumbnail)
//   - instant clip saves (no FFmpeg transcode)
//   - clip precision rounded to the source's segment boundaries (±5s with
//     the current segment target)
//
// Tradeoff: deleting a recording invalidates any clips that reference its
// segments. FootageViewer handles missing segments gracefully rather than
// cascade-deleting; that matches the app's intent — clips are the user's
// saved footage and shouldn't disappear silently.

import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../export/hls_export_channel.dart';
import '../hls/hls_manifest.dart';
import '../hls/hls_session.dart';
import '../models/clip.dart';
import '../models/recording.dart';
import 'recording_provider.dart';

class ClipProvider extends ChangeNotifier {
  final RecordingProvider _recordingProvider;

  ClipProvider(this._recordingProvider);

  bool clipSaved = false;
  bool clipInProgress = false;
  DateTime? clipProgressEndTime;
  // A clip request queued while recording was busy stopping. Processed by
  // [processPendingClip] once the recording has been saved.
  ({int secondsPre, String triggerType})? _pendingClip;

  void dismissClipNotification() {
    clipSaved = false;
    notifyListeners();
  }

  /// Mark that a clip was saved and notify listeners. Exposed publicly so
  /// screens that save clips outside the normal trigger flow (e.g. the
  /// FootageEditor Save Clip button) can light up the "Clip Saved" UI too.
  void markClipSaved() {
    clipSaved = true;
    notifyListeners();
  }

  void startClipProgress(int postDurationSeconds) {
    clipInProgress = true;
    clipSaved = false;
    clipProgressEndTime =
        DateTime.now().add(Duration(seconds: postDurationSeconds));
    notifyListeners();
  }

  void _clearClipProgress() {
    clipInProgress = false;
    clipProgressEndTime = null;
  }

  /// Save a clip from the live recording, ending at roughly the moment of
  /// this call and spanning [clipDurationSeconds] (pre + post). If the
  /// recording has already stopped (user released the button then stopped
  /// recording right after), the request is queued via [_pendingClip] and
  /// fulfilled from disk once the recording has been saved.
  Future<void> saveClipFromLive({
    required int clipDurationSeconds,
    required int secondsPre,
    String triggerType = 'manual',
  }) async {
    if (_recordingProvider.isBusy || !_recordingProvider.isRecording) {
      _pendingClip = (secondsPre: secondsPre, triggerType: triggerType);
      if (!_recordingProvider.isBusy) await processPendingClip();
      return;
    }
    final session = _recordingProvider.session;
    final controller = _recordingProvider.controller;
    if (session == null || controller == null) return;

    _recordingProvider.lockBusy();
    try {
      await _saveClipFromLiveSession(
        session,
        controller,
        clipDurationSeconds,
        triggerType,
      );
      notifyListeners();
    } catch (e) {
      debugPrint('Clip save failed: $e');
    } finally {
      _recordingProvider.unlockBusy();
    }
  }

  /// Process a clip that was queued while recording was stopping. Uses the
  /// most-recent saved recording on disk.
  Future<void> processPendingClip() async {
    final pending = _pendingClip;
    _pendingClip = null;
    if (pending == null) return;
    final recording = await Recording.openRecordingDB();
    if (recording == null) return;
    final end = recording.recordingLength;
    if (end == 0) return;
    final start = (end - pending.secondsPre).clamp(0, end).toDouble();
    await _saveClipFromManifest(
      sourceManifestPath: recording.recordingLocation,
      startSecs: start,
      endSecs: end.toDouble(),
      triggerType: pending.triggerType,
    );
    notifyListeners();
  }

  /// Save a clip from an already-completed recording between two wall-clock
  /// offsets. Used by FootageEditor's Save Clip and by
  /// [processPendingClip]. The [sourceManifestPath] must be the full path
  /// to the source manifest (as stored in Recording.recordingLocation or
  /// Clip.clipLocation — you can derive a clip from another clip too).
  Future<void> saveClipFromRange({
    required String sourceManifestPath,
    required double startSecs,
    required double endSecs,
    String triggerType = 'manual',
  }) async {
    if (_recordingProvider.isRecording) return;
    if (_recordingProvider.isBusy) return;
    assert(endSecs > startSecs, 'endSecs must be after startSecs');
    _recordingProvider.lockBusy();
    try {
      await _saveClipFromManifest(
        sourceManifestPath: sourceManifestPath,
        startSecs: startSecs,
        endSecs: endSecs,
        triggerType: triggerType,
      );
      notifyListeners();
    } catch (e) {
      debugPrint('Clip save failed: $e');
    } finally {
      _recordingProvider.unlockBusy();
    }
  }

  /// Live-session path: force a rotation so the session has written every
  /// captured second up to "now" to disk, then build a sub-manifest that
  /// covers the last [clipDurationSeconds].
  Future<void> _saveClipFromLiveSession(
    HlsRecordingSession session,
    CameraController controller,
    int clipDurationSeconds,
    String triggerType,
  ) async {
    await session.forceRotate(controller);
    final segments = session.segments;
    if (segments.isEmpty) return;
    final total = HlsSegmentMath.totalDuration(segments);
    final startSecs = (total - clipDurationSeconds).clamp(0.0, total);
    await _writeSubManifestClip(
      sourceManifestPath: session.manifestPath,
      sourceSegments: segments,
      sourceSegmentsDir: session.sessionDir,
      startSecs: startSecs,
      endSecs: total,
      triggerType: triggerType,
    );
  }

  /// Disk-only path: parse the source manifest, find the covering range,
  /// and build a sub-manifest.
  Future<void> _saveClipFromManifest({
    required String sourceManifestPath,
    required double startSecs,
    required double endSecs,
    required String triggerType,
  }) async {
    final sourceFile = File(sourceManifestPath);
    if (!await sourceFile.exists()) return;
    final sourceSegments = await HlsManifest.parseFile(sourceFile);
    if (sourceSegments.isEmpty) return;
    await _writeSubManifestClip(
      sourceManifestPath: sourceManifestPath,
      sourceSegments: sourceSegments,
      sourceSegmentsDir: sourceFile.parent.path,
      startSecs: startSecs,
      endSecs: endSecs,
      triggerType: triggerType,
    );
  }

  /// Shared clip-writer used by both the live and disk paths. Produces
  /// `<appDocuments>/clips/<clip_uuid>/manifest.m3u8` with relative URIs
  /// (like `../../recordings/<rec_uuid>/seg_NN.mp4`) that point back at
  /// the source's segment files.
  Future<void> _writeSubManifestClip({
    required String sourceManifestPath,
    required List<SegmentRef> sourceSegments,
    required String sourceSegmentsDir,
    required double startSecs,
    required double endSecs,
    required String triggerType,
  }) async {
    final range =
        HlsSegmentMath.rangeCovering(sourceSegments, startSecs, endSecs);
    if (range == null) return;

    final selected =
        sourceSegments.sublist(range.firstIdx, range.lastIdx + 1);
    if (selected.isEmpty) return;

    final appDir = await getApplicationDocumentsDirectory();
    final clipsDir = Directory(p.join(appDir.path, 'clips'));
    final thumbnailsDir = Directory(p.join(appDir.path, 'thumbnails'));
    await Future.wait([
      clipsDir.create(recursive: true),
      thumbnailsDir.create(recursive: true),
    ]);

    final id = const Uuid().v4();
    final clipSessionDir = Directory(p.join(clipsDir.path, id));
    await clipSessionDir.create(recursive: true);
    final clipManifestPath = p.join(clipSessionDir.path, 'manifest.m3u8');
    final thumbnailPath = p.join(thumbnailsDir.path, '$id.jpg');

    // Rewrite segment URIs as relative paths from the clip dir to the
    // source segment dir. path.relative handles all the tricky cases
    // (siblings, different depths) without us doing string math.
    final rewrittenSegments = <SegmentRef>[];
    var totalClipSize = 0;
    var totalClipDurationSecs = 0.0;
    for (final seg in selected) {
      final absoluteSegPath = p.join(sourceSegmentsDir, seg.uri);
      final relative = p.relative(absoluteSegPath, from: clipSessionDir.path);
      // Normalize to forward slashes — the HLS spec uses URI-style paths
      // and AVPlayer/ExoPlayer both prefer them on all platforms.
      final relUri = relative.replaceAll(r'\', '/');
      rewrittenSegments.add(
        SegmentRef(uri: relUri, durationSecs: seg.durationSecs),
      );
      totalClipDurationSecs += seg.durationSecs;
      final segFile = File(absoluteSegPath);
      if (await segFile.exists()) {
        totalClipSize += await segFile.length();
      }
    }

    final manifestText = HlsManifest.buildManifest(
      rewrittenSegments,
      targetDurationSecs: HlsRecordingSession.segmentTargetSeconds + 1,
      closed: true,
    );
    await File(clipManifestPath).writeAsString(manifestText, flush: true);

    // Generate a thumbnail from the first referenced segment. Done last
    // because it's the slowest step and we want the manifest written
    // even if thumbnailing fails.
    String? savedThumbnailPath;
    final firstSegAbsolute =
        p.join(sourceSegmentsDir, selected.first.uri);
    try {
      await HlsExportChannel.extractFirstFrame(
        videoPath: firstSegAbsolute,
        outputPath: thumbnailPath,
      );
      if (await File(thumbnailPath).exists()) {
        savedThumbnailPath = thumbnailPath;
      }
    } catch (e) {
      debugPrint('Clip thumbnail failed: $e');
    }

    final now = DateTime.now();
    await Clip(
      id: id,
      dateTime: now.toIso8601String(),
      dateTimePretty: DateFormat('yyyy-MM-dd HH:mm').format(now),
      clipLength: totalClipDurationSecs.round(),
      clipSize: totalClipSize,
      triggerType: triggerType,
      isFlagged: false,
      clipLocation: clipManifestPath,
      thumbnailLocation: savedThumbnailPath ?? '',
    ).insertClipDB();

    _clearClipProgress();
    clipSaved = true;
  }
}
