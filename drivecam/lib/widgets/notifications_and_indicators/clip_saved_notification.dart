import 'package:drivecam/provider/recording_provider.dart';
import 'package:drivecam/provider/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class ClipSavedNotification extends StatelessWidget {
  const ClipSavedNotification({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<RecordingProvider>(
      builder: (context, recording, _) {
        if (!recording.clipSaved) return const SizedBox.shrink();
        final green = context.read<ThemeProvider>().clipSavedColor;
        return SafeArea(
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, top: 52),
              child: GestureDetector(
                onTap: recording.dismissClipNotification,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: green,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'Clip Saved',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
