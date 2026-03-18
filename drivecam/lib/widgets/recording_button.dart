import 'package:drivecam/provider/recording_provider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class RecordingButton extends StatelessWidget {
  final VoidCallback? onPressed;
  const RecordingButton({super.key, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final recordingProvider = context.watch<RecordingProvider>();

    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        shape: const CircleBorder(),
        fixedSize: const Size(72, 72),
        padding: EdgeInsets.zero,
      ),
      onPressed: onPressed ?? recordingProvider.toggleRecording,
      child: Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: recordingProvider.isRecording
              ? const Color(0xFFFF0000)
              : const Color(0xFF646464),
        ),
      ),
    );
  }
}
