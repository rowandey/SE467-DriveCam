import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
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
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        await Gal.requestAccess();
        if (!await Gal.hasAccess()) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Gallery access denied')),
            );
          }
          return;
        }
      }

      final appDir = await getApplicationDocumentsDirectory();
      final tempDir = Directory('${appDir.path}/temp');
      await tempDir.create(recursive: true);

      final id = const Uuid().v4();
      final outputPath = '${tempDir.path}/$id.mp4';
      final startSecs = start.inMilliseconds / 1000.0;
      final durationSecs = (end - start).inMilliseconds / 1000.0;

      await FFmpegKit.execute(
        '-y -i ${widget.filePath} -ss $startSecs -t $durationSecs -c copy $outputPath',
      );

      if (!await File(outputPath).exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to create clip')),
          );
        }
        return;
      }

      await Gal.putVideo(outputPath);

      try {
        await File(outputPath).delete();
      } catch (_) {}

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Clip saved to gallery')),
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
        );
      },
    );
  }
}
