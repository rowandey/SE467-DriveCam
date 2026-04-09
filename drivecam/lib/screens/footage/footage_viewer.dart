import 'dart:io';

import 'package:drivecam/models/recording.dart';
import 'package:drivecam/widgets/footage_editor.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:gal/gal.dart';

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

    try {
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
    } catch (e, st) {
      // Video initialization failed — surface a helpful error instead of
      // letting the platform exception crash the UI.
      debugPrint('Video init failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Video playback error: $e';
      });
    }
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
        actions: [
          if (_filePath != null)
              IconButton(
                onPressed: () => _exportToGallery(context),
                icon: const Icon(Icons.download),
                tooltip: 'Export to gallery',
              ),
        ],
      ),
      body: _buildBody(colorScheme),
    );
  }

  Future<void> _exportToGallery(BuildContext context) async {
    if (_filePath == null) return;
    final colorScheme = Theme.of(context).colorScheme;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Exporting to gallery...'), backgroundColor: colorScheme.primary),
    );
    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        await Gal.requestAccess();
        if (!await Gal.hasAccess()) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Gallery access denied')),
          );
          return;
        }
      }

      await Gal.putVideo(_filePath!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved to gallery')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
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
