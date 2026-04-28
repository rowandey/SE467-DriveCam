// FootageEditor — playback scrubber + trim controls that sit below (or
// overlay) the video in FootageViewer.
//
// After the HLS switch, trim boundaries snap to HLS segment starts, which
// gives us two nice properties:
//   - "Save Clip" can build a sub-manifest instead of transcoding with
//     FFmpeg. It just selects a contiguous range of segments from the
//     source manifest.
//   - "Export to Gallery" (in FootageViewer) can remux the same segment
//     range into a single MP4 via MediaMuxer, again without FFmpeg.
//
// The slider itself stays arbitrary-precision for smooth scrubbing; only
// the trim boundaries snap. Segment boundaries are loaded from the
// source manifest on init.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../hls/hls_manifest.dart';
import '../provider/clip_provider.dart';

/// Notifies [FootageViewer] about the current trim range so it can feed
/// the same range into Export to Gallery. Null bounds mean "use default"
/// (0 for start, duration for end).
typedef TrimRangeChanged = void Function(Duration? start, Duration? end);

class FootageEditor extends StatefulWidget {
  final VideoPlayerController controller;

  /// Path to the source manifest (.m3u8). Used both for snap math and for
  /// the Save Clip sub-manifest.
  final String filePath;

  /// Optional callback; fires whenever the trim range changes so
  /// FootageViewer can keep its Export-to-Gallery state in sync.
  final TrimRangeChanged? onTrimRangeChanged;

  const FootageEditor({
    super.key,
    required this.controller,
    required this.filePath,
    this.onTrimRangeChanged,
  });

  @override
  State<FootageEditor> createState() => _FootageEditorState();
}

class _FootageEditorState extends State<FootageEditor> {
  Duration? _clipStart;
  Duration? _clipEnd;
  bool _saving = false;

  /// Cumulative start offsets of each segment in the source manifest, in
  /// seconds. Includes a trailing entry equal to the total duration so we
  /// can snap the clip end to the very last segment boundary too.
  /// Empty if the manifest couldn't be parsed (falls back to no snapping).
  List<double> _segmentBoundariesSecs = const [];

  VideoPlayerController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _loadSegmentBoundaries();
  }

  /// Load segment start offsets from the source manifest so trim
  /// boundaries can snap to real segment edges. On any error we fall back
  /// to an empty list, which disables snapping — the trim UI still works,
  /// it just won't align to segment cuts.
  Future<void> _loadSegmentBoundaries() async {
    try {
      final file = File(widget.filePath);
      if (!await file.exists()) return;
      final segments = await HlsManifest.parseFile(file);
      if (segments.isEmpty) return;
      final starts = HlsSegmentMath.cumulativeStarts(segments);
      final total = HlsSegmentMath.totalDuration(segments);
      if (!mounted) return;
      setState(() {
        _segmentBoundariesSecs = [...starts, total];
      });
    } catch (e) {
      debugPrint('Manifest parse failed in FootageEditor: $e');
    }
  }

  /// Snap an arbitrary playback position to the nearest segment boundary.
  /// Returns the input unchanged when no boundaries are available.
  Duration _snapToSegment(Duration d) {
    if (_segmentBoundariesSecs.isEmpty) return d;
    final targetSecs = d.inMilliseconds / 1000.0;
    var bestSecs = _segmentBoundariesSecs.first;
    var bestDelta = (bestSecs - targetSecs).abs();
    for (final b in _segmentBoundariesSecs) {
      final delta = (b - targetSecs).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        bestSecs = b;
      }
    }
    return Duration(milliseconds: (bestSecs * 1000).round());
  }

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
      _clipStart = _snapToSegment(_controller.value.position);
      if (_clipEnd != null && _clipEnd! <= _clipStart!) {
        _clipEnd = null;
      }
    });
    _notifyTrimChanged();
  }

  void _setClipEnd() {
    setState(() {
      _clipEnd = _snapToSegment(_controller.value.position);
      if (_clipStart != null && _clipStart! >= _clipEnd!) {
        _clipStart = null;
      }
    });
    _notifyTrimChanged();
  }

  void _notifyTrimChanged() {
    widget.onTrimRangeChanged?.call(_clipStart, _clipEnd);
  }

  void _togglePlayback() {
    setState(() {
      _controller.value.isPlaying ? _controller.pause() : _controller.play();
    });
  }

  /// Save Clip: build a sub-manifest in `<appDocuments>/clips/<uuid>/`.
  /// This no longer re-encodes; it just references the source's segments.
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
      final cp = Provider.of<ClipProvider>(context, listen: false);
      await cp.saveClipFromRange(
        sourceManifestPath: widget.filePath,
        startSecs: start.inMilliseconds / 1000.0,
        endSecs: end.inMilliseconds / 1000.0,
      );

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
