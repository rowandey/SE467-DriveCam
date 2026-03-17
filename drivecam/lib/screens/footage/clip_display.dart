import 'dart:io';
import 'package:drivecam/models/clip.dart';
import 'package:drivecam/screens/footage/footage_viewer.dart';
import 'package:flutter/material.dart';

class ClipDisplay extends StatelessWidget {
  const ClipDisplay({super.key});

  static String _formatDuration(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  static String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      final gb = bytes / (1024 * 1024 * 1024);
      return '${gb.toStringAsFixed(2)} GB';
    }
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Clip>>(
      future: Clip.loadAllClips(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 200,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final clips = snapshot.data ?? [];
        if (clips.isEmpty) {
          return const Center(child: Text('No clips saved'));
        }

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 4,
            mainAxisSpacing: 4,
            childAspectRatio: 16 / 9,
          ),
          itemCount: clips.length,
          itemBuilder: (context, index) => _ClipTile(clip: clips[index]),
        );
      },
    );
  }
}

class _ClipTile extends StatelessWidget {
  final Clip clip;
  const _ClipTile({required this.clip});

  @override
  Widget build(BuildContext context) {
    final durationText = ClipDisplay._formatDuration(clip.clipLength);
    final sizeText = ClipDisplay._formatSize(clip.clipSize);
    final hasThumbnail = File(clip.thumbnailLocation).existsSync();

    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => FootageViewer(
            filePath: clip.clipLocation,
            title: clip.dateTimePretty,
          ),
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasThumbnail)
            Image.file(File(clip.thumbnailLocation), fit: BoxFit.cover)
          else
            const Placeholder(),
          Positioned(
            right: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '$sizeText - $durationText',
                style: const TextStyle(color: Colors.white, fontSize: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
