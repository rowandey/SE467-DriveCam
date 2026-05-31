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

import 'package:flutter/material.dart';

import '../analytics/analytics_controller.dart';
import 'recording_provider.dart';
import 'settings_provider.dart';
import '../utils/clip_saver.dart';

class ClipProvider extends ChangeNotifier {
  final RecordingProvider _recordingProvider;
  final SettingsProvider _settingsProvider;
  final AnalyticsController _analytics;
  late final ClipSaver _clipSaver;

  // _settingsProvider is needed to read clipStorageLimit during eviction.
  // _analytics is needed to track clip save events.
  ClipProvider(this._recordingProvider, this._settingsProvider, this._analytics, {ClipSaver? clipSaver}) {
    _clipSaver = clipSaver ?? ClipSaver();
  }

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
      clipSaved = await _clipSaver.saveClipFromLive(clipDurationSeconds, triggerType, _recordingProvider, _analytics, _settingsProvider);
      _clearClipProgress();
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

    clipSaved = await _clipSaver.processPendingClip(pending, _analytics, _settingsProvider);

    _clearClipProgress();
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
      clipSaved = await _clipSaver.saveClipFromRecording(startSeconds, endSeconds, triggerType, _analytics, _settingsProvider);
      _clearClipProgress();
      notifyListeners();
    } catch (e) {
      debugPrint('Clip save failed: $e');
    } finally {
      _recordingProvider.unlockBusy();
    }
  }
}
