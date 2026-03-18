import 'package:drivecam/provider/recording_provider.dart';
import 'package:drivecam/screens/footage/all_footage_display.dart';
import 'package:drivecam/screens/settings.dart';
import 'package:drivecam/widgets/recording_button.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

enum NavPage { footage, settings }

class MyBottomNavBar extends StatelessWidget {
  final NavPage? activePage;
  const MyBottomNavBar({super.key, this.activePage});

  @override
  Widget build(BuildContext context) {
    return BottomAppBar(
      color: Theme.of(context).colorScheme.primary,
      child: Row(
        spacing: 56,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.video_collection_rounded),
            onPressed: () => _onFootagePressed(context),
          ),
          RecordingButton(
            onPressed: activePage != null
                ? () {
                    Navigator.pop(context);
                    context.read<RecordingProvider>().toggleRecording();
                  }
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _onSettingsPressed(context),
          ),
        ],
      ),
    );
  }

  void _onFootagePressed(BuildContext context) {
    if (activePage == NavPage.footage) {
      Navigator.pop(context);
    } else if (activePage == NavPage.settings) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const AllFootageDisplay()),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const AllFootageDisplay()),
      );
    }
  }

  void _onSettingsPressed(BuildContext context) {
    if (activePage == NavPage.settings) {
      Navigator.pop(context);
    } else if (activePage == NavPage.footage) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      );
    }
  }
}
