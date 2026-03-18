import 'dart:io';

import 'package:drivecam/models/recording.dart';
import 'package:drivecam/widgets/footage_editor.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class FootageViewer extends StatefulWidget {
  /// If provided, plays this file directly. Otherwise loads the latest recording from DB.
  final String? filePath;
  final String title;

  const FootageViewer({super.key, this.filePath, this.title = 'Recording'});

  @override
  State<FootageViewer> createState() => _FootageViewerState();
}

class _FootageViewerState extends State<FootageViewer> {
  VideoPlayerController? _controller;
  String? _filePath;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadVideo();
  }

  Future<void> _loadVideo() async {
    String? path = widget.filePath;

    if (path == null) {
      final recording = await Recording.openRecordingDB();
      if (!mounted) return;
      if (recording == null) {
        setState(() {
          _loading = false;
          _error = 'No recording found.';
        });
        return;
      }
      path = recording.recordingLocation;
    }

    final file = File(path);
    if (!file.existsSync()) {
      setState(() {
        _loading = false;
        _error = 'Video file not found.';
      });
      return;
    }

    final controller = VideoPlayerController.file(file);
    await controller.initialize();
    if (!mounted) {
      controller.dispose();
      return;
    }

    setState(() {
      _controller = controller;
      _filePath = path;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        title: Text(widget.title),
      ),
      body: _buildBody(colorScheme),
    );
  }

  Widget _buildBody(ColorScheme colorScheme) {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(color: colorScheme.primary),
      );
    }
    if (_error != null) {
      return Center(
        child: Text(_error!, style: TextStyle(color: colorScheme.onSurface)),
      );
    }

    final controller = _controller!;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    if (isLandscape) {
      // In landscape, overlay the editor controls on top of the video so the
      // footage fills the screen and controls float at the bottom.
      return Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87],
                ),
              ),
              child: Theme(
                data: Theme.of(context).copyWith(
                  colorScheme: colorScheme.copyWith(
                    onSurface: Colors.white,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 20),
                  child: FootageEditor(
                    controller: controller,
                    filePath: _filePath!,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          ),
        ),
        FootageEditor(
          controller: controller,
          filePath: _filePath!,
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
