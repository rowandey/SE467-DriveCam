// clip_provider.dart
// Owns clip saving logic, clip notification state, and clip storage enforcement.
//
// Clip storage enforcement (from main branch):
//   After each clip is saved the provider checks whether the total size of all
//   stored clips exceeds SettingsProvider.clipStorageLimit. If so it deletes
//   the oldest clip(s) — FIFO, by date_time ascending — until the total is
//   back within the limit. This mirrors how RecordingProvider evicts old
//   recording segments.
//
// Analytics (from KPI branch):
//   Each saved clip fires a trackClipSaved event via AnalyticsController,
//   recording the clip duration, trigger type, and whether it was taken from
//   a live recording or a previously saved file.

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../analytics/analytics_controller.dart';
import '../models/clip.dart';
import '../models/recording.dart';
import 'recording_provider.dart';
import 'settings_provider.dart';

class ClipProvider extends ChangeNotifier {
  final RecordingProvider _recordingProvider;
  final SettingsProvider _settingsProvider;
  final AnalyticsController _analytics;

  // _settingsProvider is needed to read clipStorageLimit during eviction.
  // _analytics is needed to track clip save events.
  ClipProvider(this._recordingProvider, this._settingsProvider, this._analytics);

  bool clipSaved = false;
  bool clipInProgress = false;
  DateTime? clipProgressEndTime;
  // Pending clip request to process after recording stops.
  ({int secondsPre, String triggerType})? _pendingClip;

  /// Clears the clip-saved notification flag and notifies listeners.
  void dismissClipNotification() {
    clipSaved = false;
    notifyListeners();
  }

  /// Mark that a clip was saved and notify listeners.
  void markClipSaved() {
    clipSaved = true;
    notifyListeners();
  }

  /// Starts the post-duration countdown and marks a clip as in progress.
  /// [postDurationSeconds] sets the countdown end time shown in the UI.
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

  /// Enforces the clip storage limit by deleting the oldest clips first.
  ///
  /// Loads all clips from the database, sums their sizes, then removes the
  /// oldest clip (lowest date_time) repeatedly until the total is within
  /// SettingsProvider.clipStorageLimit. Both the video file and its thumbnail
  /// are deleted from disk before the DB row is removed.
  ///
  /// Exposed without a leading underscore so that unit tests can call it
  /// directly after seeding the database. Do not call this from production
  /// code outside of the two save methods below.
  @visibleForTesting
  Future<void> enforceClipStorageLimit() async {
    final limitBytes = SettingsProvider.clipStorageLimitToBytes(
        _settingsProvider.clipStorageLimit);

    // loadAllClips returns clips ordered date_time DESC (newest first),
    // so the oldest clip is always at the tail of the list.
    final clips = await Clip.loadAllClips();
    var totalBytes = clips.fold<int>(0, (sum, c) => sum + c.clipSize);
    int fromEnd = clips.length - 1;

    while (totalBytes > limitBytes && fromEnd >= 0) {
      final oldest = clips[fromEnd];
      // Delete files from disk; ignore errors if files are already missing.
      try { await File(oldest.clipLocation).delete(); } catch (_) {}
      try { await File(oldest.thumbnailLocation).delete(); } catch (_) {}
      await oldest.deleteClipDB();
      totalBytes -= oldest.clipSize;
      fromEnd--;
    }
  }

  /// Saves a clip of the last N seconds of the active recording.
  /// [secondsPre] is how many seconds before the trigger to include; used as
  /// the fallback clip length when the live recording is no longer available.
  Future<void> saveClipFromLive({
    required int clipDurationSeconds,
    required int secondsPre,
    String triggerType = 'manual',
  }) async {
    if (_recordingProvider.isBusy || !_recordingProvider.isRecording) {
      // Queue for processing: immediately if not busy, or after _saveRecording completes
      _pendingClip = (secondsPre: secondsPre, triggerType: triggerType);
      if (!_recordingProvider.isBusy) await processPendingClip();
      return;
    }
    if (_recordingProvider.controller == null ||
        !_recordingProvider.controller!.value.isInitialized) {
      return;
    }
    _recordingProvider.lockBusy();
    try {
      await _saveClipFromLive(clipDurationSeconds, triggerType);
      notifyListeners();
    } catch (e) {
      debugPrint('Clip save failed: $e');
    } finally {
      _recordingProvider.unlockBusy();
    }
  }

  /// Saves a pending clip from the most recent recording, ending at the
  /// recording's last frame (the most recent available footage).
  Future<void> processPendingClip() async {
    final pending = _pendingClip;
    _pendingClip = null;
    if (pending == null) return;
    final recording = await Recording.openRecordingDB();
    if (recording == null) return;
    final end = recording.recordingLength;
    if (end == 0) return;
    final start = (end - pending.secondsPre).clamp(0, end);
    await _saveClipFromRecording(start, end, pending.triggerType);
    notifyListeners();
  }

  /// Saves a clip from the most-recent saved recording between two time frames.
  /// [startSeconds] and [endSeconds] are offsets into the recording file.
  Future<void> saveClipFromRecording({
    required int startSeconds,
    required int endSeconds,
    String triggerType = 'manual',
  }) async {
    if (_recordingProvider.isRecording) return;
    if (_recordingProvider.isBusy) return;
    assert(endSeconds > startSeconds, 'endSeconds must be after startSeconds');
    _recordingProvider.lockBusy();
    try {
      await _saveClipFromRecording(startSeconds, endSeconds, triggerType);
      notifyListeners();
    } catch (e) {
      debugPrint('Clip save failed: $e');
    } finally {
      _recordingProvider.unlockBusy();
    }
  }

  Future<void> _saveClipFromLive(
    int clipDurationSeconds,
    String triggerType,
  ) async {
    final controller = _recordingProvider.controller!;
    // Stop recording to flush the video file to disk.
    final xFile = await controller.stopVideoRecording();
    // Use segmentStartTime (not recordingStartTime) so the offset is relative
    // to this segment, not the entire session.
    final elapsed = _recordingProvider.segmentStartTime != null
        ? DateTime.now().difference(_recordingProvider.segmentStartTime!).inSeconds
        : clipDurationSeconds;

    // Restart immediately to minimise the gap in the continuous recording.
    await controller.startVideoRecording();
    _recordingProvider.setSegmentStartTime(DateTime.now());

    final appDir = await getApplicationDocumentsDirectory();
    final clipsDir = Directory('${appDir.path}/clips');
    final thumbnailsDir = Directory('${appDir.path}/thumbnails');
    await Future.wait([
      clipsDir.create(recursive: true),
      thumbnailsDir.create(recursive: true),
    ]);

    final startSecs = (elapsed - clipDurationSeconds).clamp(0, elapsed);
    final actualDuration = elapsed - startSecs;

    final id = const Uuid().v4();
    final clipPath = '${clipsDir.path}/$id.mp4';
    final thumbnailPath = '${thumbnailsDir.path}/$id.jpg';
    final now = DateTime.now();

    // Stream-copy the clip segment instead of re-encoding.
    // Trade-off: stream copy snaps the clip start to the nearest keyframe
    // boundary (typically within 1-2 seconds).
    await Future.wait([
      FFmpegKit.execute(
        '-y -ss $startSecs -i ${xFile.path} -t $actualDuration -c copy $clipPath',
      ),
      FFmpegKit.execute(
        '-y -ss $startSecs -i ${xFile.path} -vframes 1 -q:v 2 $thumbnailPath',
      ),
    ]);

    // Keep xFile around — it is added to segments so it can be concatenated
    // into the full session recording when recording stops. Pass elapsed so
    // rolling-buffer eviction in RecordingProvider can correctly account for
    // this segment's duration and estimated storage.
    _recordingProvider.addSegment(xFile.path, elapsed);

    if (!await File(clipPath).exists()) return;

    final fileSize = await File(clipPath).length();

    await Clip(
      id: id,
      dateTime: now.toIso8601String(),
      dateTimePretty: DateFormat('yyyy-MM-dd HH:mm').format(now),
      clipLength: actualDuration,
      clipSize: fileSize,
      triggerType: triggerType,
      isFlagged: false,
      clipLocation: clipPath,
      thumbnailLocation: thumbnailPath,
    ).insertClipDB();
    // Track the clip save event before enforcing the storage limit.
    _analytics.trackClipSaved(
      durationSeconds: actualDuration,
      triggerType: triggerType,
      fromLiveRecording: true,
    );
    // Remove oldest clip(s) if the total clip storage now exceeds the limit.
    await enforceClipStorageLimit();
    _clearClipProgress();
    clipSaved = true;
  }

  Future<void> _saveClipFromRecording(
    int startSeconds,
    int endSeconds,
    String triggerType,
  ) async {
    final recording = await Recording.openRecordingDB();
    if (recording == null) return;

    final appDir = await getApplicationDocumentsDirectory();
    final clipsDir = Directory('${appDir.path}/clips');
    final thumbnailsDir = Directory('${appDir.path}/thumbnails');
    await Future.wait([
      clipsDir.create(recursive: true),
      thumbnailsDir.create(recursive: true),
    ]);

    final duration = endSeconds - startSeconds;

    final id = const Uuid().v4();
    final clipPath = '${clipsDir.path}/$id.mp4';
    final thumbnailPath = '${thumbnailsDir.path}/$id.jpg';
    final now = DateTime.now();

    // Stream-copy the clip segment — same approach as _saveClipFromLive.
    // Both operations read from the source recording file so they run in
    // parallel; neither blocks the other.
    await Future.wait([
      FFmpegKit.execute(
        '-y -ss $startSeconds -i ${recording.recordingLocation} -t $duration -c copy $clipPath',
      ),
      FFmpegKit.execute(
        '-y -ss $startSeconds -i ${recording.recordingLocation} -vframes 1 -q:v 2 $thumbnailPath',
      ),
    ]);

    if (!await File(clipPath).exists()) return;

    final fileSize = await File(clipPath).length();

    await Clip(
      id: id,
      dateTime: now.toIso8601String(),
      dateTimePretty: DateFormat('yyyy-MM-dd HH:mm').format(now),
      clipLength: duration,
      clipSize: fileSize,
      triggerType: triggerType,
      isFlagged: false,
      clipLocation: clipPath,
      thumbnailLocation: thumbnailPath,
    ).insertClipDB();
    // Track the clip save event before enforcing the storage limit.
    _analytics.trackClipSaved(
      durationSeconds: duration,
      triggerType: triggerType,
      fromLiveRecording: false,
    );
    // Remove oldest clip(s) if the total clip storage now exceeds the limit.
    await enforceClipStorageLimit();
    _clearClipProgress();
    clipSaved = true;
  }
}
