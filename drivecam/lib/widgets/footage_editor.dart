import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/clip.dart';
import 'package:provider/provider.dart';
import '../provider/clip_provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

class FootageEditor extends StatefulWidget {
  final VideoPlayerController controller;
  final String filePath;

  const FootageEditor({
    super.key,
    required this.controller,
    required this.filePath,
  });

  @override
  State<FootageEditor> createState() => _FootageEditorState();
}

class _FootageEditorState extends State<FootageEditor> {
  Duration? _clipStart;
  Duration? _clipEnd;
  bool _saving = false;

  VideoPlayerController get _controller => widget.controller;

  void _seekBackward() {
    final current = _controller.value.position;
    final target = current - const Duration(seconds: 10);
    _controller.seekTo(target < Duration.zero ? Duration.zero : target);
  }

  void _seekForward() {
    final current = _controller.value.position;
    final duration = _controller.value.duration;
    final target = current + const Duration(seconds: 10);
    _controller.seekTo(target > duration ? duration : target);
  }

  void _setClipStart() {
    setState(() {
      _clipStart = _controller.value.position;
      if (_clipEnd != null && _clipEnd! <= _clipStart!) {
        _clipEnd = null;
      }
    });
  }

  void _setClipEnd() {
    setState(() {
      _clipEnd = _controller.value.position;
      if (_clipStart != null && _clipStart! >= _clipEnd!) {
        _clipStart = null;
      }
    });
  }

  void _togglePlayback() {
    setState(() {
      _controller.value.isPlaying ? _controller.pause() : _controller.play();
    });
  }

  Future<void> _saveClip() async {
    if (_saving) return;

    final start = _clipStart ?? Duration.zero;
    final end = _clipEnd ?? _controller.value.duration;

    if (end <= start) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid clip range')),
        );
      }
      return;
    }

    setState(() => _saving = true);

    try {
      // Create clip inside app storage and register in DB (do NOT export to
      // the device gallery automatically).
      final appDir = await getApplicationDocumentsDirectory();
      final clipsDir = Directory('${appDir.path}/clips');
      final thumbnailsDir = Directory('${appDir.path}/thumbnails');
      final tempDir = Directory('${appDir.path}/temp');
      await Future.wait([
        clipsDir.create(recursive: true),
        thumbnailsDir.create(recursive: true),
        tempDir.create(recursive: true),
      ]);

      final id = const Uuid().v4();
      final outputPath = '${clipsDir.path}/$id.mp4';
      final thumbnailPath = '${thumbnailsDir.path}/$id.jpg';
      final startSecs = start.inMilliseconds / 1000.0;
      final durationSecs = (end - start).inMilliseconds / 1000.0;

      // Re-encode clip to H.264/AAC to ensure platform player compatibility.
      await FFmpegKit.execute(
        '-y -i ${widget.filePath} -ss $startSecs -t $durationSecs -c:v libx264 -preset veryfast -crf 23 -c:a aac -b:a 128k $outputPath',
      );

      if (!await File(outputPath).exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to create clip')),
          );
        }
        return;
      }

      final fileSize = await File(outputPath).length();
      await FFmpegKit.execute('-y -i $outputPath -vframes 1 -q:v 2 $thumbnailPath');

      final now = DateTime.now();
      await Clip(
        id: id,
        dateTime: now.toIso8601String(),
        dateTimePretty: DateFormat('yyyy-MM-dd HH:mm').format(now),
        clipLength: ((end - start).inMilliseconds / 1000).round(),
        clipSize: fileSize,
        triggerType: 'manual',
        isFlagged: false,
        clipLocation: outputPath,
        thumbnailLocation: thumbnailPath,
      ).insertClipDB();

      // Notify ClipProvider so UI updates (clip list / notifications)
      try {
        final cp = Provider.of<ClipProvider>(context, listen: false);
        cp.markClipSaved();
      } catch (_) {}

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Clip saved to app')), 
        );
      }
    } catch (e) {
      debugPrint('Save clip failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        final duration = value.duration;
        final position = value.position;

        final isLandscape =
            MediaQuery.of(context).orientation == Orientation.landscape;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Scrubber
            SliderTheme(
              data: SliderThemeData(
                trackHeight: 4,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: colorScheme.primary,
                inactiveTrackColor: colorScheme.onSurface.withAlpha(31),
                thumbColor: colorScheme.primary,
                overlayColor: colorScheme.primary.withAlpha(40),
              ),
              child: Slider(
                min: 0,
                max: duration.inMilliseconds
                    .toDouble()
                    .clamp(1, double.infinity),
                value: position.inMilliseconds
                    .toDouble()
                    .clamp(0, duration.inMilliseconds.toDouble()),
                onChanged: (ms) {
                  _controller.seekTo(Duration(milliseconds: ms.toInt()));
                },
              ),
            ),

            // Position / duration timestamps + controls row
            // In landscape, merge timestamps and buttons into one row to
            // minimise vertical space.
            if (isLandscape)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _formatDuration(position),
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _seekBackward,
                      icon: Icon(Icons.replay_10,
                          color: colorScheme.onSurface),
                      iconSize: 24,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    IconButton(
                      onPressed: _setClipStart,
                      icon: Icon(
                        Icons.first_page,
                        color: _clipStart != null
                            ? colorScheme.primary
                            : colorScheme.onSurface,
                      ),
                      iconSize: 24,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      onPressed: _togglePlayback,
                      icon: Icon(
                        value.isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        color: colorScheme.primary,
                      ),
                      iconSize: 36,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      onPressed: _setClipEnd,
                      icon: Icon(
                        Icons.last_page,
                        color: _clipEnd != null
                            ? colorScheme.primary
                            : colorScheme.onSurface,
                      ),
                      iconSize: 24,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    IconButton(
                      onPressed: _seekForward,
                      icon: Icon(Icons.forward_10,
                          color: colorScheme.onSurface),
                      iconSize: 24,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatDuration(duration),
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 12,
                      ),
                    ),
                    if (_clipStart != null || _clipEnd != null) ...[
                      const SizedBox(width: 12),
                      Text(
                        'Clip: ${_formatDuration(_clipStart ?? Duration.zero)} → ${_formatDuration(_clipEnd ?? duration)}',
                        style: TextStyle(
                          color: colorScheme.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    const Spacer(),
                    GestureDetector(
                      onTap: _saving ? null : _saveClip,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 6),
                        decoration: BoxDecoration(
                          color: _saving
                              ? colorScheme.primary.withAlpha(128)
                              : colorScheme.primary,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text(
                                'Save Clip',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              // Portrait: keep the existing multi-row layout
              // Position / duration timestamps
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatDuration(position),
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      _formatDuration(duration),
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),

              // Clip range indicator
              if (_clipStart != null || _clipEnd != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Clip: ${_formatDuration(_clipStart ?? Duration.zero)} → ${_formatDuration(_clipEnd ?? duration)}',
                    style: TextStyle(
                      color: colorScheme.primary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),

              const SizedBox(height: 16),

              // Control buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: _seekBackward,
                    icon: Icon(Icons.replay_10,
                        color: colorScheme.onSurface),
                    iconSize: 32,
                  ),
                  IconButton(
                    onPressed: _setClipStart,
                    icon: Icon(
                      Icons.first_page,
                      color: _clipStart != null
                          ? colorScheme.primary
                          : colorScheme.onSurface,
                    ),
                    iconSize: 32,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _togglePlayback,
                    icon: Icon(
                      value.isPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_filled,
                      color: colorScheme.primary,
                    ),
                    iconSize: 52,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _setClipEnd,
                    icon: Icon(
                      Icons.last_page,
                      color: _clipEnd != null
                          ? colorScheme.primary
                          : colorScheme.onSurface,
                    ),
                    iconSize: 32,
                  ),
                  IconButton(
                    onPressed: _seekForward,
                    icon: Icon(Icons.forward_10,
                        color: colorScheme.onSurface),
                    iconSize: 32,
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // Save clip button (pill shape)
              GestureDetector(
                onTap: _saving ? null : _saveClip,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                  decoration: BoxDecoration(
                    color: _saving
                        ? colorScheme.primary.withAlpha(128)
                        : colorScheme.primary,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text(
                          'Save Clip',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
