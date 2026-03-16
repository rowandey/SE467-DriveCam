import 'dart:io';

import 'package:camera/camera.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/recording.dart';

class RecordingProvider extends ChangeNotifier {
  bool isRecording = false;
  CameraController? _controller;
  DateTime? _recordingStartTime;
  bool _isBusy = false;

  void setCameraController(CameraController controller) {
    _controller = controller;
  }

  Future<void> toggleRecording() async {
    if (_isBusy) return;
    if (_controller == null || !_controller!.value.isInitialized) return;

    _isBusy = true;
    isRecording = !isRecording;
    notifyListeners();

    try {
      if (isRecording) {
        await _controller!.startVideoRecording();
        _recordingStartTime = DateTime.now();
      } else {
        await _saveRecording();
      }
    } catch (e) {
      isRecording = !isRecording;
      notifyListeners();
      debugPrint('Recording toggle failed: $e');
    } finally {
      _isBusy = false;
    }
  }

  Future<void> _saveRecording() async {
    final xFile = await _controller!.stopVideoRecording();
    final duration = _recordingStartTime != null
        ? DateTime.now().difference(_recordingStartTime!).inSeconds
        : 0;
    _recordingStartTime = null;

    // Set up storage directories
    final appDir = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${appDir.path}/recordings');
    final thumbnailsDir = Directory('${appDir.path}/thumbnails');
    await Future.wait([
      recordingsDir.create(recursive: true),
      thumbnailsDir.create(recursive: true),
    ]);

    // Generate paths
    final id = const Uuid().v4();
    final videoPath = '${recordingsDir.path}/$id.mp4';
    final thumbnailPath = '${thumbnailsDir.path}/$id.jpg';

    // Move recording from temp to permanent location
    await File(xFile.path).copy(videoPath);
    await File(xFile.path).delete();

    // Get file size in bytes
    final fileSize = await File(videoPath).length();

    // Generate thumbnail from first frame
    await FFmpegKit.execute(
      '-y -i $videoPath -vframes 1 -q:v 2 $thumbnailPath',
    );
    final thumbnailExists = await File(thumbnailPath).exists();

    // Delete previous recording (single-row table)
    final existing = await Recording.openRecordingDB();
    if (existing != null) {
      try {
        await File(existing.recordingLocation).delete();
      } catch (_) {}
      if (existing.thumbnailLocation != null) {
        try {
          await File(existing.thumbnailLocation!).delete();
        } catch (_) {}
      }
      await existing.deleteRecordingDB();
    }

    // Save new recording to database
    final recording = Recording(
      id: id,
      recordingLocation: videoPath,
      recordingLength: duration,
      recordingSize: fileSize,
      thumbnailLocation: thumbnailExists ? thumbnailPath : null,
    );
    await recording.insertRecordingDB();
  }
}
