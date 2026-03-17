import 'package:drivecam/screens/footage/clip_display.dart';
import 'package:drivecam/screens/footage/footage_viewer.dart';
import 'package:drivecam/screens/footage/recording_display.dart';
import 'package:drivecam/widgets/app_bars/app_bar.dart';
import 'package:drivecam/widgets/app_bars/bottom_app_bar.dart';
import 'package:flutter/material.dart';

class AllFootageDisplay extends StatelessWidget {
  const AllFootageDisplay({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const MyAppBar(title: 'Clip Manager'),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Text('Clips', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            const ClipDisplay(),
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Text('Recording', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FootageViewer()),
              ),
              child: const RecordingDisplay(),
            ),
          ],
        ),
      ),
      bottomNavigationBar: const MyBottomNavBar(activePage: NavPage.footage),
    );
  }
}
