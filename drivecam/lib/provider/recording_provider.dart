import 'package:flutter/material.dart';

class RecordingProvider extends ChangeNotifier {
  bool recordingOn = false;

  void toggleRecording() {
    recordingOn = !recordingOn;
    notifyListeners();
    if (recordingOn) {
      // TODO: start recording
    } else {
      // TODO: stop recording
    }
  }
}
