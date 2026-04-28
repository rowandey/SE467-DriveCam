// FootageViewer — full-screen video player for a recording or a clip.
//
// Storage-side the app is HLS (manifest + short MP4 segments), but
// ExoPlayer's HLS extractor only accepts fragmented MP4 (fMP4) segments.
// The Android camera plugin produces standard MP4 (moov-at-end, no mvex),
// so feeding the manifest directly to video_player fails with a
// FragmentedMp4Extractor NullPointerException.
//
// Workaround: on open, remux the manifest's segments into a single
// temp-dir MP4 via the MediaMuxer platform channel (the same path Export
// to Gallery uses) and play that. The concat is bit-perfect and fast
// (~a second for multi-minute recordings) because MediaMuxer copies
// samples — no re-encoding. The temp file is deleted on dispose.
//
// The FootageEditor still sees the manifest path directly, so its
// snap-to-segment-boundary logic and Save Clip (sub-manifest) flow
// operate on real HLS state, not the concat'd playback file.

import 'dart:io';

import 'package:drivecam/export/hls_export_channel.dart';
import 'package:drivecam/hls/hls_manifest.dart';
import 'package:drivecam/models/recording.dart';
import 'package:drivecam/widgets/app_drawers/nav_drawer.dart';
import 'package:drivecam/widgets/footage_editor.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

class FootageViewer extends StatefulWidget {
  /// If provided, plays this manifest directly. Otherwise loads the latest
  /// recording from the DB.
  final String? filePath;
  final String title;

  const FootageViewer({super.key, this.filePath, this.title = 'Recording'});

  @override
  State<FootageViewer> createState() => _FootageViewerState();
}

class _FootageViewerState extends State<FootageViewer> {
  VideoPlayerController? _controller;

  /// Source manifest path — the "real" filePath, used for trim/save-clip.
  String? _manifestPath;

  /// Temp-file path holding the concatenated MP4 we're actually playing.
  /// Separate from [_manifestPath] because FootageEditor needs the
  /// manifest for segment-boundary math and sub-manifest clip saves.
  String? _playbackTempPath;

  bool _loading = true;
  String? _error;

  // Trim range reported up from FootageEditor. Null means "no trim".
  Duration? _trimStart;
  Duration? _trimEnd;

  @override
  void initState() {
    super.initState();
    _loadVideo();
  }

  Future<void> _loadVideo() async {
    String? manifestPath = widget.filePath;

    if (manifestPath == null) {
      final recording = await Recording.openRecordingDB();
      if (!mounted) return;
      if (recording == null) {
        setState(() {
          _loading = false;
          _error = 'No recording found.';
        });
        return;
      }
      manifestPath = recording.recordingLocation;
    }

    final manifestFile = File(manifestPath);
    if (!await manifestFile.exists()) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Video file not found.';
      });
      return;
    }

    try {
      // 1. Parse the manifest → list of segments with relative URIs.
      final segments = await HlsManifest.parseFile(manifestFile);
      if (segments.isEmpty) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'No segments in manifest.';
        });
        return;
      }

      // 2. Resolve relative URIs against the manifest directory to get
      //    absolute paths the Kotlin side can open with MediaExtractor.
      final manifestDir = manifestFile.parent.path;
      final absoluteSegments = segments
          .map((s) => p.normalize(p.join(manifestDir, s.uri)))
          .toList();

      // 3. Remux all segments into one MP4 in the temp dir. Filename
      //    uses a fresh UUID so concurrent viewers never collide.
      final tempDir = await getTemporaryDirectory();
      final tempOut = p.join(tempDir.path, 'playback_${const Uuid().v4()}.mp4');
      await HlsExportChannel.remuxSegments(
        segmentPaths: absoluteSegments,
        outputPath: tempOut,
      );

      // 4. Play the concat'd MP4 via the stock video_player.file() path,
      //    which is the one that actually works reliably on ExoPlayer.
      final controller = VideoPlayerController.file(File(tempOut));
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        try {
          await File(tempOut).delete();
        } catch (_) {}
        return;
      }

      setState(() {
        _controller = controller;
        _manifestPath = manifestPath;
        _playbackTempPath = tempOut;
        _loading = false;
      });
    } catch (e, st) {
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
    // Best-effort cleanup of the concat'd playback file. If it sticks
    // around Android's temp-dir sweep will reap it eventually.
    if (_playbackTempPath != null) {
      final pathToDelete = _playbackTempPath!;
      // Fire-and-forget — can't await in dispose().
      // ignore: unawaited_futures
      File(pathToDelete).delete().catchError((_) => File(pathToDelete));
    }
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
          if (_manifestPath != null)
            IconButton(
              onPressed: () => _exportToGallery(context),
              icon: const Icon(Icons.download),
              tooltip: 'Export to gallery',
            ),
          Builder(
            builder: (scaffoldContext) => IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(scaffoldContext).openEndDrawer(),
            ),
          ),
        ],
      ),
      body: _buildBody(colorScheme),
      endDrawer: const NavDrawer(),
      extendBody: true,
    );
  }

  /// Export to Gallery: take the source manifest, optionally trim to the
  /// FootageEditor's selected range (snapped to segment boundaries), then
  /// remux the selected segments into a single .mp4 via the Android
  /// MediaMuxer platform channel. Push the result into the gallery and
  /// clean up the temp file.
  Future<void> _exportToGallery(BuildContext context) async {
    final manifestPath = _manifestPath;
    if (manifestPath == null) return;
    final colorScheme = Theme.of(context).colorScheme;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Exporting to gallery...'),
        backgroundColor: colorScheme.primary,
      ),
    );
    String? tempOutputPath;
    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        await Gal.requestAccess();
        if (!await Gal.hasAccess()) {
          if (!mounted) return;
          messenger.showSnackBar(
            const SnackBar(content: Text('Gallery access denied')),
          );
          return;
        }
      }

      final manifestFile = File(manifestPath);
      final segments = await HlsManifest.parseFile(manifestFile);
      if (segments.isEmpty) {
        if (!mounted) return;
        messenger.showSnackBar(
          const SnackBar(content: Text('No segments to export')),
        );
        return;
      }

      final selected = _selectSegmentsForExport(segments);
      if (selected.isEmpty) {
        if (!mounted) return;
        messenger.showSnackBar(
          const SnackBar(content: Text('Invalid trim range')),
        );
        return;
      }

      final manifestDir = manifestFile.parent.path;
      final absolutePaths = selected
          .map((s) => p.normalize(p.join(manifestDir, s.uri)))
          .toList();

      final tempDir = await getTemporaryDirectory();
      tempOutputPath = p.join(tempDir.path, 'export_${const Uuid().v4()}.mp4');

      await HlsExportChannel.remuxSegments(
        segmentPaths: absolutePaths,
        outputPath: tempOutputPath,
      );

      await Gal.putVideo(tempOutputPath);
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Saved to gallery')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    } finally {
      if (tempOutputPath != null) {
        try {
          await File(tempOutputPath).delete();
        } catch (_) {}
      }
    }
  }

  /// Apply the FootageEditor's trim range (if any) to the source segment
  /// list, returning the covering segment subrange. Falls back to all
  /// segments when no trim is active.
  List<SegmentRef> _selectSegmentsForExport(List<SegmentRef> segments) {
    if (_trimStart == null && _trimEnd == null) return segments;
    final startSecs = _trimStart != null
        ? _trimStart!.inMilliseconds / 1000.0
        : 0.0;
    final endSecs = _trimEnd != null
        ? _trimEnd!.inMilliseconds / 1000.0
        : HlsSegmentMath.totalDuration(segments);
    final range = HlsSegmentMath.rangeCovering(segments, startSecs, endSecs);
    if (range == null) return const [];
    return segments.sublist(range.firstIdx, range.lastIdx + 1);
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
                    filePath: _manifestPath!,
                    onTrimRangeChanged: _onTrimRangeChanged,
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
          filePath: _manifestPath!,
          onTrimRangeChanged: _onTrimRangeChanged,
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  void _onTrimRangeChanged(Duration? start, Duration? end) {
    // Stored as-is; applied only at Export time. No setState — this
    // state doesn't affect the render tree.
    _trimStart = start;
    _trimEnd = end;
  }
}
