// camera_view.dart
// Owns the CameraController and renders the live camera preview.
//
// Rolling-buffer integration (from main branch):
//   Calls setVideoBitrate after each controller init so RecordingProvider can
//   estimate per-segment storage accurately (bytes = bitrate × seconds ÷ 8).
//   Implements _doPeriodicFlush, which RecordingProvider's 5-minute timer
//   invokes to flush the current segment to disk so old footage can be evicted.
//   Also handles mid-recording reinit (audio setting change) by flushing the
//   current segment with its duration before swapping controllers.
//
// Voice clip integration (Vosk):
//   When voiceClipEnabled is true and recording is active, Vosk performs
//   offline speech recognition in the background. Saying "clip" triggers the
//   same _triggerClipSave() path as tapping the screen.
//   Vosk is open-source, requires no API key, runs entirely on-device, and
//   uses a grammar restriction (['clip', '[unk]']) so it only listens for the
//   target word — keeping CPU usage low.
//   See assets/models/SETUP.md for the one-time model download steps.

import 'dart:async';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:drivecam/provider/clip_provider.dart';
import 'package:drivecam/provider/recording_provider.dart';
import 'package:drivecam/provider/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:vosk_flutter/vosk_flutter.dart';

class CameraView extends StatefulWidget {
  const CameraView({super.key});

  @override
  State<CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> {
  CameraController? _controller;
  late Future<void> _initFuture;
  CameraDescription? _camera;
  String? _currentQuality;
  String? _currentFramerate;
  // Tracks the audio setting that was used when the controller was last created.
  // null until the first init completes.
  bool? _currentAudioEnabled;
  Orientation? _currentOrientation;
  Timer? _clipTimer;
  // Cached provider reference so dispose() can null out onFlushRequested
  // without relying on context (which may be invalid during disposal).
  RecordingProvider? _recordingProvider;
  // Cached settings reference so dispose() can remove the change listener
  // without needing a valid BuildContext.
  SettingsProvider? _settingsProvider;

  // ── Vosk speech recognition ───────────────────────────────────────────────
  // Vosk is an open-source offline speech recognition library. No API key or
  // network connection is required. A grammar restriction (['clip', '[unk]'])
  // limits the vocabulary to just the target word, which keeps CPU usage low
  // and reduces false positives.
  //
  // Lifecycle:
  //   _initVosk()  — called once in initState(); loads the bundled model zip,
  //                  creates Model + Recognizer, then starts the SpeechService
  //                  if recording is already active (race-condition guard).
  //   _startVosk() — called when recording starts with voiceClipEnabled=true.
  //   _stopVosk()  — called when recording stops or voiceClipEnabled=false.

  // Vosk model and recognizer — created once and reused for the widget lifetime.
  // Model holds the loaded acoustic + language model; Recognizer wraps it with
  // a grammar restriction and sample-rate config.
  Model? _voskModel;
  Recognizer? _voskRecognizer;

  // The SpeechService owns the microphone capture loop. It is created by
  // _startVosk() and disposed by _stopVosk() each time recognition toggles.
  SpeechService? _speechService;

  // True after _initVosk() succeeds. Guards _startVosk() so it never tries to
  // use a null model or recognizer.
  bool _voskReady = false;

  // True while the SpeechService is actively capturing audio. Keeps
  // _startVosk() / _stopVosk() idempotent.
  bool _voskListening = false;

  // Debounce: true for 2 s after a detection so a single utterance cannot fire
  // multiple clip saves if Vosk emits the same result in consecutive callbacks.
  bool _clipSaveDebounce = false;

  // ── Vosk methods ──────────────────────────────────────────────────────────

  /// Loads the bundled Vosk model, creates a grammar-restricted Recognizer,
  /// and marks the service as ready. Runs asynchronously so it does not block
  /// camera start-up.
  ///
  /// ModelLoader.loadFromAssets() extracts the zip to app-documents/models/ on
  /// first launch and returns the cached path on subsequent runs — no manual
  /// file-copy needed.
  ///
  /// After a successful init, starts detection immediately if recording is
  /// already active — handles the race where recording begins before init
  /// finishes.
  Future<void> _initVosk() async {
    try {
      // Extract the bundled model zip to local storage (cached after first run).
      // The asset path must match pubspec.yaml. See assets/models/SETUP.md for
      // instructions on downloading vosk-model-small-en-us-0.15.zip.
      final modelPath = await ModelLoader().loadFromAssets(
        'assets/models/vosk-model-small-en-us-0.15.zip',
      );
      _voskModel = await VoskFlutterPlugin.instance().createModel(modelPath);

      // Grammar restriction: only 'clip' and '[unk]' (everything else) are
      // recognised. This dramatically reduces CPU load and false positives
      // compared to a full-vocabulary recognizer.
      _voskRecognizer = await VoskFlutterPlugin.instance().createRecognizer(
        model: _voskModel!,
        sampleRate: 16000,
        grammar: ['clip', '[unk]'],
      );

      _voskReady = true;
      debugPrint('[VoiceClip] Vosk initialized');

      // Race condition guard: recording may have started while we were waiting
      // for the async init. Start detection now if we should be listening.
      if (mounted) {
        final isRecording = context.read<RecordingProvider>().isRecording;
        final voiceEnabled = context.read<SettingsProvider>().voiceClipEnabled;
        if (isRecording && voiceEnabled) _startVosk();
      }
    } catch (e) {
      // Model not found is the most common failure — see assets/models/SETUP.md.
      debugPrint('[VoiceClip] Vosk init failed: $e');
    }
  }

  /// Called when Vosk's onPartial or onResult stream contains 'clip'.
  /// The debounce guard prevents a single utterance from triggering multiple
  /// clip saves if Vosk emits the word across both the partial and final result.
  void _onClipWordDetected() {
    if (_clipSaveDebounce || !mounted) return;
    if (!context.read<RecordingProvider>().isRecording) return;
    debugPrint('[VoiceClip] "clip" detected');
    _clipSaveDebounce = true;
    _triggerClipSave();
    // Reset the debounce after 2 seconds so back-to-back utterances each save
    // a separate clip rather than collapsing into one.
    Future.delayed(const Duration(seconds: 2), () => _clipSaveDebounce = false);
  }

  /// Parses a Vosk JSON result string and returns true only if the recognised
  /// text contains the exact word "clip" as a standalone token.
  ///
  /// Vosk emits JSON in two shapes:
  ///   onPartial → {"partial": "clip"}
  ///   onResult  → {"text": "clip"}
  ///
  /// A simple [String.contains] check would fire on any word that has "clip"
  /// as a substring (e.g. "eclipse", "clipping"). Parsing the JSON and
  /// splitting on whitespace ensures we match only the complete word.
  bool _voskJsonContainsClip(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      // Use 'text' for final results, 'partial' for in-progress partials.
      final text = ((map['text'] ?? map['partial']) as String? ?? '').trim();
      // Split into individual tokens and look for an exact 'clip' match so
      // words like "eclipse" or "clipping" are never treated as the keyword.
      return text.split(RegExp(r'\s+')).contains('clip');
    } catch (_) {
      // Malformed JSON — treat as no match rather than crashing.
      return false;
    }
  }

  /// Creates a SpeechService, subscribes to its result streams, and starts the
  /// microphone capture loop. Idempotent — safe to call when already listening.
  ///
  /// Both onPartial (real-time) and onResult (final) streams are checked so
  /// the clip fires as soon as the word is recognised rather than waiting for
  /// a sentence boundary.
  Future<void> _startVosk() async {
    if (!_voskReady || _voskListening || _voskRecognizer == null) return;
    try {
      // initSpeechService returns a SpeechService that wraps the platform mic
      // channel. On Android this goes through a MethodChannel; not supported
      // on iOS (vosk_flutter only ships the Android MethodChannel binding).
      _speechService = await VoskFlutterPlugin.instance()
          .initSpeechService(_voskRecognizer!);

      // onPartial fires continuously while the user is speaking; onResult fires
      // once at a sentence boundary. We listen to both so the clip triggers as
      // soon as 'clip' is confidently recognised in either stream.
      _speechService!.onPartial().listen((partial) {
        if (_voskJsonContainsClip(partial)) _onClipWordDetected();
      });
      _speechService!.onResult().listen((result) {
        if (_voskJsonContainsClip(result)) _onClipWordDetected();
      });

      await _speechService!.start();
      _voskListening = true;
      debugPrint('[VoiceClip] Vosk started');
    } catch (e) {
      debugPrint('[VoiceClip] Vosk start failed: $e');
    }
  }

  /// Stops and disposes the SpeechService, freeing the microphone.
  /// Idempotent — safe to call when already stopped.
  Future<void> _stopVosk() async {
    if (!_voskListening) return;
    _voskListening = false;
    await _speechService?.stop();
    await _speechService?.dispose();
    _speechService = null;
    debugPrint('[VoiceClip] Vosk stopped');
  }

  /// Listener attached to both [RecordingProvider] and [SettingsProvider].
  /// Starts voice recognition when recording is active and voiceClipEnabled is
  /// true; stops it otherwise.
  void _onRecordingStateChanged() {
    if (!mounted) return;
    final isRecording = context.read<RecordingProvider>().isRecording;
    final voiceEnabled = context.read<SettingsProvider>().voiceClipEnabled;
    debugPrint('[VoiceClip] state change: recording=$isRecording, voiceEnabled=$voiceEnabled');
    if (isRecording && voiceEnabled) {
      _startVosk();
    } else {
      _stopVosk();
    }
  }

  // ──────────────────────────────────────────────────────────────────────────

  /// Initializes (or reinitializes) the [CameraController] with the given settings.
  /// Also registers the bitrate with RecordingProvider and wires the flush callback.
  Future<void> _initCamera(
    String quality,
    String framerate,
    bool audioEnabled,
  ) async {
    _camera ??= (await availableCameras()).first;
    // videoBitrate is derived from quality + framerate so the encoder uses a
    // known, fixed rate rather than a platform-chosen default. A fixed bitrate
    // is required for accurate storage-consumption estimates elsewhere in the
    // app (bytes = bitrate × seconds ÷ 8). audioBitrate is intentionally left
    // at the platform default since audio storage is negligible by comparison.
    final bitrate = SettingsProvider.videoBitrateForSettings(quality, framerate);
    final controller = CameraController(
      _camera!,
      SettingsProvider.qualityToPreset(quality),
      fps: SettingsProvider.framerateToFps(framerate),
      enableAudio: audioEnabled,
      videoBitrate: bitrate,
    );
    await controller.initialize();
    if (!mounted) return;
    // Cache the provider reference so dispose() can clean up onFlushRequested
    // without needing a valid BuildContext.
    _recordingProvider = context.read<RecordingProvider>();
    _recordingProvider!.setCameraController(controller);
    // Keep bitrate in sync with the controller so segment size estimation in
    // addSegment always reflects the current encoding rate.
    _recordingProvider!.setVideoBitrate(bitrate);
    // Point the flush timer callback at this widget's _doPeriodicFlush so
    // RecordingProvider can trigger stop/restart without holding a controller ref.
    _recordingProvider!.onFlushRequested = _doPeriodicFlush;
    _controller = controller;
    _currentQuality = quality;
    _currentFramerate = framerate;
    _currentAudioEnabled = audioEnabled;
  }

  /// Called by RecordingProvider's 5-minute flush timer to flush the current
  /// camera segment to disk, register it with the rolling buffer, and restart
  /// recording — giving _evictOldestIfNeeded a chance to drop old footage.
  Future<void> _doPeriodicFlush() async {
    if (!mounted) return;
    final recordingProvider = context.read<RecordingProvider>();
    if (!recordingProvider.isRecording || recordingProvider.isBusy) return;

    recordingProvider.lockBusy();
    try {
      // Capture segment start before stopping so the duration is accurate even
      // if stopVideoRecording takes a moment to complete.
      final segmentStart = recordingProvider.segmentStartTime ?? DateTime.now();
      final xFile = await _controller!.stopVideoRecording();
      final durationSeconds = DateTime.now().difference(segmentStart).inSeconds;
      // addSegment accounts for duration + estimated size and triggers eviction
      // of oldest segments if either the time or storage limit is exceeded.
      recordingProvider.addSegment(xFile.path, durationSeconds);
      await _controller!.startVideoRecording();
      recordingProvider.setSegmentStartTime(DateTime.now());
    } catch (e) {
      debugPrint('Periodic flush failed: $e');
    } finally {
      recordingProvider.unlockBusy();
    }
  }

  /// Reads settings and triggers clip save logic via ClipProvider.
  /// If a post-duration is configured the clip is deferred until the timer fires.
  Future<void> _triggerClipSave() async {
    final clipProvider = context.read<ClipProvider>();
    final settingsProvider = context.read<SettingsProvider>();

    final secondsPre = SettingsProvider.clipDurationToSeconds(
      settingsProvider.preDurationLength,
    );
    final secondsPost = SettingsProvider.clipDurationToSeconds(
      settingsProvider.postDurationLength,
    );
    final seconds = secondsPre + secondsPost;

    if (secondsPost == 0) {
      clipProvider.saveClipFromLive(
        clipDurationSeconds: seconds,
        secondsPre: secondsPre,
      );
    } else {
      _clipTimer?.cancel();
      clipProvider.startClipProgress(secondsPost);
      // Clip is only actually taken and saved once post second counter expires.
      // Unfortunately, the technology to look into the future doesn't exist yet.
      _clipTimer = Timer(Duration(seconds: secondsPost), () {
        clipProvider.saveClipFromLive(
          clipDurationSeconds: seconds,
          secondsPre: secondsPre,
        );
      });
    }
  }

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsProvider>();
    _initFuture = _initCamera(settings.quality, settings.framerate, settings.audioEnabled);
    // Initialize Vosk asynchronously so it doesn't delay camera startup.
    // _startVosk() is a no-op until _voskReady is true, so any recording-state
    // change that fires before init completes is handled by the race-condition
    // guard at the end of _initVosk().
    _initVosk();
    // addPostFrameCallback defers provider listener registration until after
    // the first frame, by which point the widget is fully in the tree and
    // context.read is safe to use without a BuildContext warning.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _recordingProvider = context.read<RecordingProvider>();
      _settingsProvider = context.read<SettingsProvider>();
      // These listeners start/stop voice recognition whenever the recording
      // state or the voiceClipEnabled setting changes.
      _recordingProvider!.addListener(_onRecordingStateChanged);
      _settingsProvider!.addListener(_onRecordingStateChanged);
    });
  }

  /// Stops the current recording segment, disposes the old controller,
  /// reinitializes with new settings (e.g. a changed audio toggle), then
  /// restarts recording so the session continues uninterrupted.
  Future<void> _reinitCameraWhileRecording(
    CameraController oldController,
    String quality,
    String framerate,
    bool audioEnabled,
  ) async {
    final recordingProvider = context.read<RecordingProvider>();
    // Guard against concurrent clip saves or other busy operations.
    if (recordingProvider.isBusy) return;

    recordingProvider.lockBusy();
    try {
      // Capture segment start before stopping so duration is accurate.
      final segmentStart = recordingProvider.segmentStartTime ?? DateTime.now();
      // Flush the current video segment to disk so no footage is lost.
      final xFile = await oldController.stopVideoRecording();
      final durationSeconds = DateTime.now().difference(segmentStart).inSeconds;
      // Pass duration so rolling-buffer eviction can account for this segment's
      // time and estimated storage correctly.
      recordingProvider.addSegment(xFile.path, durationSeconds);

      // Dispose the old controller before creating the new one.
      oldController.dispose();

      // Bring up a fresh controller with the updated settings.
      await _initCamera(quality, framerate, audioEnabled);
      if (!mounted) return;

      // Resume recording on the new controller to maintain a continuous session.
      await _controller!.startVideoRecording();
      recordingProvider.setSegmentStartTime(DateTime.now());
    } catch (e) {
      debugPrint('Camera reinit while recording failed: $e');
    } finally {
      recordingProvider.unlockBusy();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settingsProvider = context.watch<SettingsProvider>();
    final quality = settingsProvider.quality;
    final framerate = settingsProvider.framerate;
    final audioEnabled = settingsProvider.audioEnabled;
    final orientation = MediaQuery.of(context).orientation;

    final audioChanged =
        _currentAudioEnabled != null && audioEnabled != _currentAudioEnabled;

    // Special case: audio setting changed while actively recording.
    if (audioChanged && context.read<RecordingProvider>().isRecording) {
      _currentAudioEnabled = audioEnabled;
      final oldController = _controller!;
      setState(() {
        _controller = null;
        _initFuture = _reinitCameraWhileRecording(
          oldController,
          quality,
          framerate,
          audioEnabled,
        );
      });
      return;
    }

    // Include audio changes in the general "settings changed" check so a
    // non-recording reinit picks up the new enableAudio value.
    final settingsChanged = _currentQuality != null &&
        (quality != _currentQuality ||
            framerate != _currentFramerate ||
            audioChanged);
    final orientationChanged =
        _currentOrientation != null && orientation != _currentOrientation;
    _currentOrientation = orientation;

    // Reinitialize the camera when settings change, or when the device is
    // rotated while not recording.
    if (settingsChanged ||
        (orientationChanged &&
            !context.read<RecordingProvider>().isRecording)) {
      _controller?.dispose();
      setState(() {
        _controller = null;
        _initFuture = _initCamera(quality, framerate, audioEnabled);
      });
    }
  }

  @override
  void dispose() {
    _clipTimer?.cancel();
    // Stop Vosk. dispose() is synchronous so we fire-and-forget the async
    // stop; _voskListening is set to false first so no new start() calls can
    // succeed after this point. Model and Recognizer are managed by the Vosk
    // plugin and do not need explicit deletion.
    _stopVosk();
    _controller?.dispose();
    // Clear the flush callback so the timer in RecordingProvider doesn't call
    // into this widget after it has been removed from the tree.
    _recordingProvider?.onFlushRequested = null;
    // Remove change listeners so providers don't hold a reference to this
    // widget after it has been disposed (prevents memory leaks and setState
    // calls on a dead widget).
    _recordingProvider?.removeListener(_onRecordingStateChanged);
    _settingsProvider?.removeListener(_onRecordingStateChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return FutureBuilder<void>(
      future: _initFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done &&
            _controller != null) {
          final previewSize = _controller!.value.previewSize;
          // previewSize is in sensor coordinates (landscape: width > height).
          // In portrait we swap to match the rotated display; in landscape the
          // sensor and screen orientations align so we use them directly.
          final width = isLandscape
              ? (previewSize?.width ?? 1)
              : (previewSize?.height ?? 1);
          final height = isLandscape
              ? (previewSize?.height ?? 1)
              : (previewSize?.width ?? 1);

          // Stack provides layering so the menu button can overlay the camera preview.
          // The menu button allows users to open the end drawer from the camera view.
          return Stack(
            children: [
              InkWell(
                onTap: () {
                  if (context.read<RecordingProvider>().isRecording) {
                    _triggerClipSave();
                  }
                },
                child: SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: width,
                      height: height,
                      child: CameraPreview(_controller!),
                    ),
                  ),
                ),
              ),
              // Menu button overlay positioned at top-right to access the navigation drawer.
              Positioned(
                top: 8,
                right: 8,
                child: SafeArea(
                  child: IconButton(
                    icon: const Icon(Icons.menu),
                    color: Colors.white,
                    iconSize: 28,
                    onPressed: () => Scaffold.of(context).openEndDrawer(),
                  ),
                ),
              ),
            ],
          );
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }
}
