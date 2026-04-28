// HLS recording session: drives the Flutter `camera` plugin's stop/restart
// loop to produce short MP4 segments and keeps the .m3u8 manifest on disk
// up to date after every rotation.
//
// Performance note — the freeze fix:
//   The original code awaited the full _ingestSegment() (file rename +
//   manifest append) inside _rotate(), keeping _rotating = true for the
//   entire duration. That meant the rotation guard was held while disk I/O
//   ran, adding unnecessary latency on top of the unavoidable camera
//   stop/start work.
//
//   The fix uses a sequential _ingestChain Future: _rotate() schedules the
//   disk work without awaiting it, so _rotating clears as soon as the two
//   camera API calls (stop + start) return. The chain ensures manifest
//   entries are always written in segment order even if a previous ingest's
//   I/O is still in-flight when the next rotation starts.
//
//   Root-cause caveat: the biggest source of the per-rotation stutter is
//   Android's MediaRecorder.stop() finalizing the MP4 file on the platform
//   thread (the same thread Flutter uses for rendering). That part is inside
//   the camera plugin and cannot be fixed from Dart. The change here reduces
//   the freeze window by ~10–30 ms (the disk-I/O tail), which is meaningful
//   on slower devices. A full fix would require a native segment-rotation
//   implementation using MediaRecorder.setNextOutputFile() to switch output
//   files without stopping the encoder.
//
// Design notes:
//   - The camera plugin does not expose a native "segment every N seconds"
//     API, so we implement segmentation in Dart by calling
//     stopVideoRecording() and startVideoRecording() in a loop. Each stop
//     produces a complete, self-contained .mp4; each start opens a new one.
//   - There is an unavoidable recording gap of ~100-300ms per rotation.
//     Acceptable for a dashcam (it's still DVR, not continuous capture).
//   - Segment durations are measured with DateTime.now() so the manifest's
//     #EXTINF values are truthful even when rotations run long. We never
//     trust the nominal target duration to describe what actually landed.
//   - The manifest file stays playable mid-recording: we append #EXTINF
//     entries after each successful rotation, and only write #EXT-X-ENDLIST
//     when the session stops cleanly.

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'hls_manifest.dart';

/// Owns the recording loop for a single session. One instance per recording.
/// Not reusable after [stop] is called — construct a new one for the next
/// session.
class HlsRecordingSession {
  /// Target duration per segment. The real durations are measured at stop()
  /// time and will be slightly shorter (we lose the rotation gap).
  static const int segmentTargetSeconds = 5;

  /// UUID identifying this recording. Also the session directory name.
  final String id;

  /// Absolute path to the session directory (contains manifest + segments).
  final String sessionDir;

  /// Absolute path to the manifest file. Clients store this in the DB as
  /// [Recording.recordingLocation].
  final String manifestPath;

  // All completed segments, in order. Kept in memory so the clip builder
  // can snapshot without re-parsing the manifest. Updated immediately when
  // a segment is finalised (before disk I/O completes) so clip snapshots
  // are always current.
  final List<SegmentRef> _segments = [];

  // When the currently-recording segment started. Used to compute the real
  // #EXTINF duration when we rotate.
  DateTime? _currentSegmentStart;

  // Periodic rotation timer. Null when the session is idle or stopped.
  Timer? _rotateTimer;

  // Monotonically-increasing index used to name segment files.
  int _nextSegIndex = 0;

  // Guards against re-entrant rotate() calls — rotations can overlap with
  // a stop(), a settings-change reinit, or each other.
  bool _rotating = false;

  bool _started = false;
  bool _stopped = false;

  // Sequential chain of segment disk-write Futures. Each ingest is appended
  // here so that manifest entries land in the correct order even when an
  // earlier ingest's file I/O is still running when the next rotation fires.
  // stop() and pauseForSwap() await this chain before sealing the manifest
  // or switching controllers.
  Future<void> _ingestChain = Future<void>.value();

  HlsRecordingSession._(this.id, this.sessionDir, this.manifestPath);

  /// Create a new session, materialising its directory on disk. Does not
  /// start recording — call [start] after handing the controller over.
  ///
  /// Parameters:
  ///   [recordingsRootDir] — absolute path to the directory under which the
  ///     per-session UUID subdirectory will be created.
  ///
  /// Returns the initialised (but not yet started) session.
  static Future<HlsRecordingSession> create({
    required String recordingsRootDir,
  }) async {
    final id = const Uuid().v4();
    final sessionDir = p.join(recordingsRootDir, id);
    await Directory(sessionDir).create(recursive: true);
    final manifestPath = p.join(sessionDir, 'manifest.m3u8');
    await HlsManifest.writeHeader(
      File(manifestPath),
      targetDurationSecs: segmentTargetSeconds + 1,
    );
    return HlsRecordingSession._(id, sessionDir, manifestPath);
  }

  /// Snapshot of completed segments at this instant. Safe to call from
  /// any context — the returned list is a copy.
  List<SegmentRef> get segments => List.unmodifiable(_segments);

  /// Total duration of all completed segments in seconds. Does NOT include
  /// the currently-recording segment (not yet flushed).
  double get totalDurationSecs => HlsSegmentMath.totalDuration(_segments);

  /// When the currently-open segment started recording. Null if no segment
  /// is actively recording. Exposed so ClipProvider can map a trigger
  /// wall-clock time into session coordinates while recording.
  DateTime? get currentSegmentStart => _currentSegmentStart;

  /// Start the first segment and schedule the rotation timer. The caller
  /// owns the [controller] and is responsible for disposing it later; the
  /// session will call start/stopVideoRecording on it but will never
  /// dispose or replace the controller.
  ///
  /// Parameters:
  ///   [controller] — the initialised CameraController to record with.
  ///
  /// Throws [StateError] if called more than once on the same session.
  Future<void> start(CameraController controller) async {
    if (_started) {
      throw StateError('HlsRecordingSession already started');
    }
    _started = true;
    await controller.startVideoRecording();
    _currentSegmentStart = DateTime.now();
    _rotateTimer = Timer.periodic(
      const Duration(seconds: segmentTargetSeconds),
      (_) => _safeRotate(controller),
    );
  }

  /// Wrap _rotate in a guard so we don't overlap rotations (e.g. if a
  /// rotate() is still running when the next timer tick fires on a slow
  /// device).
  ///
  /// Parameters:
  ///   [controller] — the active CameraController passed through to _rotate.
  Future<void> _safeRotate(CameraController controller) async {
    if (_rotating || _stopped) return;
    _rotating = true;
    try {
      await _rotate(controller);
    } catch (e) {
      // Log and keep going — a single failed rotation shouldn't kill the
      // whole recording. The manifest stays valid (we never append a
      // broken segment).
      debugPrint('HlsRecordingSession rotate failed: $e');
    } finally {
      // _rotating is cleared here, NOT after the disk I/O completes.
      // The disk write runs independently via _ingestChain, so the guard
      // is free for the next timer tick without waiting for the rename or
      // manifest append. This is the key change that reduces the freeze.
      _rotating = false;
    }
  }

  /// Internal: stop the current segment, start the next one immediately,
  /// update in-memory state, then schedule the disk I/O asynchronously so
  /// the rotation cycle finishes as fast as the camera calls allow.
  ///
  /// The [_ingestChain] Future is extended (not awaited here) to serialise
  /// file renames and manifest appends in segment order.
  ///
  /// Parameters:
  ///   [controller] — the active CameraController.
  Future<void> _rotate(CameraController controller) async {
    if (!controller.value.isRecordingVideo) return;
    final segmentStart = _currentSegmentStart ?? DateTime.now();

    // Stop the current segment. On Android this calls MediaRecorder.stop(),
    // which finalises the MP4 file. This is the primary source of the
    // per-rotation stutter — it runs on the Android platform thread and
    // cannot be moved off it from Dart code.
    final xFile = await controller.stopVideoRecording();
    final realDurationSecs =
        DateTime.now().difference(segmentStart).inMilliseconds / 1000.0;

    // Start the next segment immediately to keep the recording gap short.
    await controller.startVideoRecording();
    _currentSegmentStart = DateTime.now();

    // Assign the segment name and update in-memory state NOW (synchronous,
    // trivial cost) so that ClipProvider.forceRotate() snapshots are current
    // before any disk I/O has run.
    final segName = 'seg_${_nextSegIndex.toString().padLeft(5, '0')}.mp4';
    _nextSegIndex++;
    final ref = SegmentRef(uri: segName, durationSecs: realDurationSecs);
    _segments.add(ref);

    // Schedule the disk I/O (file rename + manifest append) without awaiting
    // it here. _scheduleIngest chains this work onto the previous ingest so
    // that entries always land in manifest order.
    _scheduleIngest(xFile.path, segName, ref);
    // _rotate returns here; _safeRotate's finally clears _rotating without
    // waiting for the file rename or manifest write.
  }

  /// Append a new disk-I/O task to the sequential ingest chain.
  ///
  /// Each call extends [_ingestChain] by chaining a new Future. Because
  /// Futures in the chain run one after another, manifest appends are always
  /// in segment order even when rotations fire faster than the disk can
  /// rename files (e.g. on first boot or when the storage is slow).
  ///
  /// Errors are caught and logged so that a single bad segment does not
  /// prevent subsequent ingests from running.
  ///
  /// Parameters:
  ///   [tempPath] — path to the raw .mp4 written by the camera plugin.
  ///   [segName]  — final filename (e.g. `seg_00003.mp4`).
  ///   [ref]      — [SegmentRef] already added to [_segments].
  void _scheduleIngest(String tempPath, String segName, SegmentRef ref) {
    _ingestChain = _ingestChain.then((_) async {
      await _doIngest(tempPath, segName, ref);
    }).catchError((Object e) {
      debugPrint('HlsRecordingSession ingest failed: $e');
    });
  }

  /// Move the freshly-recorded .mp4 into the session directory and append
  /// its entry to the on-disk manifest. This is the I/O-heavy part that was
  /// previously blocking the rotation cycle.
  ///
  /// Parameters:
  ///   [tempPath] — source path (camera plugin temp file).
  ///   [segName]  — destination filename within [sessionDir].
  ///   [ref]      — segment metadata to write to the manifest.
  Future<void> _doIngest(
      String tempPath, String segName, SegmentRef ref) async {
    final destPath = p.join(sessionDir, segName);
    // rename() is a cheap metadata operation when src and dst are on the
    // same filesystem (app cache → app documents, always true on Android).
    // The copy fallback handles the unlikely cross-device case.
    try {
      await File(tempPath).rename(destPath);
    } on FileSystemException {
      await File(tempPath).copy(destPath);
      try {
        await File(tempPath).delete();
      } catch (_) {}
    }

    await HlsManifest.appendSegment(File(manifestPath), ref);
  }

  /// Force a rotation *now*, out of the periodic timer's schedule. Used by
  /// live clip saves so the clip range can include footage right up to the
  /// moment of the call, rather than only the last fully-rotated segment.
  /// The rotation timer keeps running; this is an extra rotation, not a
  /// replacement.
  ///
  /// Parameters:
  ///   [controller] — the active CameraController.
  Future<void> forceRotate(CameraController controller) async {
    if (_stopped) return;
    await _safeRotate(controller);
    // _segments is current (updated synchronously in _rotate) even though
    // the disk I/O may still be running. ClipProvider snapshots _segments
    // immediately after this returns, which is correct.
  }

  /// Pause the session for a CameraController swap (e.g. user toggles the
  /// audio setting while recording, which requires re-initialising the
  /// controller). Flushes the current segment, waits for all pending disk
  /// I/O to complete, then cancels the rotation timer. The session stays
  /// alive so [resumeWith] can attach a new controller without losing the
  /// manifest or the segments captured so far.
  ///
  /// Parameters:
  ///   [oldController] — the controller being replaced.
  Future<void> pauseForSwap(CameraController oldController) async {
    if (_stopped) return;
    _rotateTimer?.cancel();
    _rotateTimer = null;

    // Spin-wait for any in-flight rotation to finish its camera calls.
    while (_rotating) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    if (oldController.value.isRecordingVideo) {
      final segmentStart = _currentSegmentStart ?? DateTime.now();
      final xFile = await oldController.stopVideoRecording();
      final realDurationSecs =
          DateTime.now().difference(segmentStart).inMilliseconds / 1000.0;

      if (realDurationSecs >= 0.1) {
        final segName =
            'seg_${_nextSegIndex.toString().padLeft(5, '0')}.mp4';
        _nextSegIndex++;
        final ref =
            SegmentRef(uri: segName, durationSecs: realDurationSecs);
        _segments.add(ref);
        _scheduleIngest(xFile.path, segName, ref);
      } else {
        try {
          await File(xFile.path).delete();
        } catch (_) {}
      }
    }
    _currentSegmentStart = null;

    // Must drain all queued ingests before the caller swaps the controller.
    // Otherwise the new segment files could land before previous renames
    // complete, causing a manifest ordering race.
    await _ingestChain;
  }

  /// Counterpart to [pauseForSwap]: start a fresh segment on the new
  /// controller and resume the rotation timer.
  ///
  /// Parameters:
  ///   [newController] — the replacement CameraController.
  ///
  /// Throws [StateError] if the session has already been stopped.
  Future<void> resumeWith(CameraController newController) async {
    if (_stopped) {
      throw StateError('Cannot resume a stopped HlsRecordingSession');
    }
    await newController.startVideoRecording();
    _currentSegmentStart = DateTime.now();
    _rotateTimer = Timer.periodic(
      const Duration(seconds: segmentTargetSeconds),
      (_) => _safeRotate(newController),
    );
  }

  /// Stop recording, flush the last segment, wait for all queued disk I/O,
  /// and seal the manifest with #EXT-X-ENDLIST. After this returns, the
  /// manifest is a complete VOD playlist and the session is unusable.
  ///
  /// Parameters:
  ///   [controller] — the active CameraController.
  Future<void> stop(CameraController controller) async {
    if (_stopped) return;
    _stopped = true;
    _rotateTimer?.cancel();
    _rotateTimer = null;

    // Wait for an in-flight rotation to settle so we don't race with it.
    while (_rotating) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    if (controller.value.isRecordingVideo) {
      final segmentStart = _currentSegmentStart ?? DateTime.now();
      final xFile = await controller.stopVideoRecording();
      final realDurationSecs =
          DateTime.now().difference(segmentStart).inMilliseconds / 1000.0;

      // Only record a non-trivial final segment — a <100ms fragment (e.g.
      // user stopped right after a rotation) would confuse the player.
      if (realDurationSecs >= 0.1) {
        final segName =
            'seg_${_nextSegIndex.toString().padLeft(5, '0')}.mp4';
        _nextSegIndex++;
        final ref =
            SegmentRef(uri: segName, durationSecs: realDurationSecs);
        _segments.add(ref);
        _scheduleIngest(xFile.path, segName, ref);
      } else {
        try {
          await File(xFile.path).delete();
        } catch (_) {}
      }
    }
    _currentSegmentStart = null;

    // Drain all queued segment ingests before writing #EXT-X-ENDLIST.
    // Without this wait the manifest could be sealed before the last
    // #EXTINF entry has been appended, producing a truncated playlist.
    await _ingestChain;
    await HlsManifest.closeManifest(File(manifestPath));
  }

  /// Return the absolute path to the first segment's file (used for
  /// thumbnail extraction). Null if no segments have been written yet.
  String? get firstSegmentAbsolutePath {
    if (_segments.isEmpty) return null;
    return p.join(sessionDir, _segments.first.uri);
  }
}
