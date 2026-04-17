import 'package:drivecam/provider/recording_provider.dart';
import 'package:drivecam/widgets/recording_button.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class MyBottomNavBar extends StatelessWidget {
  final bool popOnRecord;
  const MyBottomNavBar({super.key, this.popOnRecord = false});

  @override
  Widget build(BuildContext context) {
    return BottomAppBar(
      color: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          RecordingButton(
            onPressed: () {
              if (popOnRecord) {
                Navigator.pop(context);
              }
              context.read<RecordingProvider>().toggleRecording();
            },
          ),
        ],
      ),
    );
  }
}
