import 'dart:io';
import 'package:drivecam/provider/recording_provider.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/recording.dart';
import '../models/clip.dart';
import '../analytics/analytics_controller.dart';
import '../provider/settings_provider.dart';

class ClipSaver {
  Future<bool> saveClipFromRecording(
    int startSeconds,
    int endSeconds,
    String triggerType,
    AnalyticsController analytics,
    SettingsProvider settingsProvider,
  ) async {
    final recording = await Recording.openRecordingDB();
    if (recording == null) return false;

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

    if (!await File(clipPath).exists()) return false;

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
    analytics.trackClipSaved(
      durationSeconds: duration,
      triggerType: triggerType,
      fromLiveRecording: false,
    );
    // Remove oldest clip(s) if the total clip storage now exceeds the limit.
    await enforceClipStorageLimit(settingsProvider);
    return true;
  }

  Future<bool> saveClipFromLive(
    int clipDurationSeconds,
    String triggerType,
    RecordingProvider recordingProvider,
    AnalyticsController analytics,
    SettingsProvider settingsProvider,
  ) async {
    final controller = recordingProvider.controller!;
    // Stop recording to flush the video file to disk.
    final xFile = await controller.stopVideoRecording();
    // Use segmentStartTime (not recordingStartTime) so the offset is relative
    // to this segment, not the entire session.
    final elapsed = recordingProvider.segmentStartTime != null
        ? DateTime.now()
              .difference(recordingProvider.segmentStartTime!)
              .inSeconds
        : clipDurationSeconds;

    // Restart immediately to minimise the gap in the continuous recording.
    await controller.startVideoRecording();
    recordingProvider.setSegmentStartTime(DateTime.now());

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
    recordingProvider.addSegment(xFile.path, elapsed);

    if (!await File(clipPath).exists()) return false;

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
    analytics.trackClipSaved(
      durationSeconds: actualDuration,
      triggerType: triggerType,
      fromLiveRecording: true,
    );
    // Remove oldest clip(s) if the total clip storage now exceeds the limit.
    await enforceClipStorageLimit(settingsProvider);
    return true;
  }

  /// Saves a pending clip from the most recent recording, ending at the
  /// recording's last frame (the most recent available footage).
  Future<bool> processPendingClip(
      ({int secondsPre, String triggerType})? pending,
      AnalyticsController analytics,
      SettingsProvider settingsProvider
      ) async {
    if (pending == null) return false;

    final recording = await Recording.openRecordingDB();
    if (recording == null) return false;
    final end = recording.recordingLength;
    if (end == 0) return false;
    final start = (end - pending.secondsPre).clamp(0, end);

    return saveClipFromRecording(start, end, pending.triggerType, analytics, settingsProvider);
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
  static Future<void> enforceClipStorageLimit(
    SettingsProvider settingsProvider,
  ) async {
    final limitBytes = SettingsProvider.clipStorageLimitToBytes(
      settingsProvider.clipStorageLimit,
    );

    // loadAllClips returns clips ordered date_time DESC (newest first),
    // so the oldest clip is always at the tail of the list.
    final clips = await Clip.loadAllClips();
    var totalBytes = clips.fold<int>(0, (sum, c) => sum + c.clipSize);
    int fromEnd = clips.length - 1;

    while (totalBytes > limitBytes && fromEnd >= 0) {
      final oldest = clips[fromEnd];
      // Delete files from disk; ignore errors if files are already missing.
      try {
        await File(oldest.clipLocation).delete();
      } catch (_) {}
      try {
        await File(oldest.thumbnailLocation).delete();
      } catch (_) {}
      await oldest.deleteClipDB();
      totalBytes -= oldest.clipSize;
      fromEnd--;
    }
  }
}
