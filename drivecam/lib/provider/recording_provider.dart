// RecordingProvider — owns the camera recording lifecycle.
//
// After the switch to HLS, the single-MP4 + ffmpeg-concat pipeline has
// been replaced by an [HlsRecordingSession], which drives the camera
// plugin's stop/restart loop to produce short MP4 segments and maintains
// a .m3u8 manifest as it goes.
//
// The public API here stays close to what ClipProvider and CameraView
// already consumed: toggleRecording(), isRecording, isBusy, the camera
// controller, and an onRecordingSaved callback. The segment-tracking
// surface that existed before (_segments / addSegment / setSegmentStartTime)
// is gone — that state lives inside [HlsRecordingSession] now.

import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../export/hls_export_channel.dart';
import '../hls/hls_session.dart';
import '../models/recording.dart';

class RecordingProvider extends ChangeNotifier {
  bool isRecording = false;
  CameraController? _controller;
  CameraController? get controller => _controller;

  // When the currently-active recording session began, in wall-clock time.
  // Used by the UI's "Recording MM:SS" indicator.
  DateTime? _recordingStartTime;
  DateTime? get recordingStartTime => _recordingStartTime;

  // Cross-provider mutex: prevents ClipProvider, CameraView settings-swap,
  // and toggleRecording from stepping on each other while one of them is
  // manipulating the camera.
  bool _isBusy = false;
  bool get isBusy => _isBusy;

  // The active HLS recording session, if any. ClipProvider reads this to
  // take a live snapshot of segment metadata while recording is ongoing.
  HlsRecordingSession? _session;
  HlsRecordingSession? get session => _session;

  /// Callback invoked after a recording is saved; used by ClipProvider to
  /// process any pending clip that was queued while recording was stopping.
  Future<void> Function()? onRecordingSaved;

  void lockBusy() => _isBusy = true;
  void unlockBusy() => _isBusy = false;

  void setCameraController(CameraController controller) {
    _controller = controller;
  }

  /// Flip recording state: start if currently idle, stop and save if
  /// currently recording. Guarded by [_isBusy] so that taps during a
  /// save/restart window are ignored rather than producing a race.
  Future<void> toggleRecording() async {
    if (_isBusy) return;
    if (_controller == null || !_controller!.value.isInitialized) return;

    _isBusy = true;
    isRecording = !isRecording;
    notifyListeners();

    try {
      if (isRecording) {
        await _startSession();
      } else {
        await _stopSessionAndSave();
      }
    } catch (e) {
      // Revert the optimistic UI flip so the user isn't stuck with a wrong
      // recording indicator if the camera fails us.
      isRecording = !isRecording;
      notifyListeners();
      debugPrint('Recording toggle failed: $e');
    } finally {
      _isBusy = false;
    }
  }

  Future<void> _startSession() async {
    final appDir = await getApplicationDocumentsDirectory();
    final recordingsRoot = Directory(p.join(appDir.path, 'recordings'));
    await recordingsRoot.create(recursive: true);

    _session =
        await HlsRecordingSession.create(recordingsRootDir: recordingsRoot.path);
    await _session!.start(_controller!);
    _recordingStartTime = DateTime.now();
  }

  Future<void> _stopSessionAndSave() async {
    final session = _session;
    if (session == null) return;

    await session.stop(_controller!);
    final duration = _recordingStartTime != null
        ? DateTime.now().difference(_recordingStartTime!).inSeconds
        : session.totalDurationSecs.round();
    _recordingStartTime = null;
    _session = null;

    // Compute total size by summing segment file sizes — the manifest is
    // small enough to ignore, and we want a cheap answer without parsing
    // MP4 headers.
    var fileSize = 0;
    for (final seg in session.segments) {
      final f = File(p.join(session.sessionDir, seg.uri));
      if (await f.exists()) {
        fileSize += await f.length();
      }
    }

    // Generate a thumbnail from the first segment. If there are no
    // segments (zero-duration recording), skip the thumbnail.
    final appDir = await getApplicationDocumentsDirectory();
    final thumbnailsDir = Directory(p.join(appDir.path, 'thumbnails'));
    await thumbnailsDir.create(recursive: true);
    final thumbnailPath = p.join(thumbnailsDir.path, '${session.id}.jpg');
    String? savedThumbnailPath;
    final firstSegmentPath = session.firstSegmentAbsolutePath;
    if (firstSegmentPath != null) {
      try {
        await HlsExportChannel.extractFirstFrame(
          videoPath: firstSegmentPath,
          outputPath: thumbnailPath,
        );
        if (await File(thumbnailPath).exists()) {
          savedThumbnailPath = thumbnailPath;
        }
      } catch (e) {
        debugPrint('Thumbnail generation failed: $e');
      }
    }

    // Delete the previous recording's directory + thumbnail (single-row
    // recording table — only one is ever kept).
    final existing = await Recording.openRecordingDB();
    if (existing != null) {
      await _deleteRecordingArtifacts(existing);
      await existing.deleteRecordingDB();
    }

    final recording = Recording(
      id: session.id,
      recordingLocation: session.manifestPath,
      recordingLength: duration,
      recordingSize: fileSize,
      thumbnailLocation: savedThumbnailPath,
    );
    await recording.insertRecordingDB();

    await onRecordingSaved?.call();
  }

  /// Best-effort cleanup of a recording's on-disk artifacts. The recording
  /// location used to be a single .mp4; it's now a manifest sitting inside
  /// a session directory, so we delete the whole directory.
  Future<void> _deleteRecordingArtifacts(Recording recording) async {
    final manifestFile = File(recording.recordingLocation);
    final sessionDir = manifestFile.parent;
    try {
      if (await sessionDir.exists()) {
        await sessionDir.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('Failed to delete recording dir: $e');
    }
    if (recording.thumbnailLocation != null) {
      try {
        await File(recording.thumbnailLocation!).delete();
      } catch (_) {}
    }
  }

  /// Called by CameraView when the camera controller is being swapped
  /// mid-recording (e.g. the audio toggle changed). Stops the current
  /// segment on [oldController] but keeps the session alive.
  Future<void> pauseSessionForSwap(CameraController oldController) async {
    await _session?.pauseForSwap(oldController);
  }

  /// Counterpart to [pauseSessionForSwap]: resume recording on a new
  /// controller after the swap completes.
  Future<void> resumeSessionWith(CameraController newController) async {
    await _session?.resumeWith(newController);
  }
}
