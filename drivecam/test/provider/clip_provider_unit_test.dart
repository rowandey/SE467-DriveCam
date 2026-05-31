import 'package:camera/camera.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'package:drivecam/analytics/analytics_client.dart';
import 'package:drivecam/analytics/analytics_controller.dart';
import 'package:drivecam/provider/clip_provider.dart';
import 'package:drivecam/provider/recording_provider.dart';
import 'package:drivecam/provider/settings_provider.dart';
import 'package:drivecam/utils/clip_saver.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

@GenerateNiceMocks([MockSpec<RecordingProvider>()])
@GenerateNiceMocks([MockSpec<SettingsProvider>()])
@GenerateNiceMocks([MockSpec<AnalyticsController>()])
@GenerateNiceMocks([MockSpec<ClipSaver>()])
@GenerateNiceMocks([MockSpec<CameraController>()])
@GenerateNiceMocks([MockSpec<CameraValue>()])
import 'clip_provider_unit_test.mocks.dart';

void main() {
  late MockRecordingProvider recording;
  late MockClipSaver clipSaver;
  late MockSettingsProvider settings;
  late MockAnalyticsController analytics;
  late ClipProvider provider;
  late int notifyCount;

  // Helper that returns a freshly wired provider trio for tests.
  ClipProvider makeProvider({
    SettingsProvider? settings,
    AnalyticsController? analytics,
    RecordingProvider? recording,
    ClipSaver? clipSaver,
  }) {
    final s = settings ?? SettingsProvider();
    final a = analytics ?? AnalyticsController(const NoopAnalyticsClient());
    final r = recording ?? RecordingProvider(s, a);
    return ClipProvider(r, s, a, clipSaver: clipSaver);
  }

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();

    recording = MockRecordingProvider();
    clipSaver = MockClipSaver();
    settings = MockSettingsProvider();
    analytics = MockAnalyticsController();
    provider = makeProvider(
      settings: settings,
      analytics: analytics,
      recording: recording,
      clipSaver: clipSaver,
    );

    notifyCount = 0;
    provider.addListener(() => notifyCount++);
  });

  test('markClipSaved and dismissClipNotification toggle flags and notify', () {
    expect(provider.clipSaved, isFalse);

    provider.markClipSaved();
    expect(provider.clipSaved, isTrue);
    expect(notifyCount, 1);

    provider.dismissClipNotification();
    expect(provider.clipSaved, isFalse);
    expect(notifyCount, 2);
  });

  test('startClipProgress sets progress state and end time', () {
    final before = DateTime.now();
    provider.startClipProgress(3);
    final after = DateTime.now();

    expect(provider.clipInProgress, isTrue);
    expect(provider.clipSaved, isFalse);
    expect(provider.clipProgressEndTime, isNotNull);
    // end time should be roughly now + 3 seconds
    final diffFromNow = provider.clipProgressEndTime!.difference(before);
    expect(diffFromNow.inSeconds, inInclusiveRange(3, 4));
    expect(provider.clipProgressEndTime!.isAfter(before), isTrue);
    expect(provider.clipProgressEndTime!.isBefore(after.add(const Duration(seconds: 5))), isTrue);

    expect(notifyCount, 1);
  });

  group('ClipProvider.saveClipFromRecording', () {
    test('saveClipFromRecording returns early when recording is active or busy', () async {
      // If recording is active the method must return without throwing and
      // clipSaved must remain false.
      when(recording.isRecording).thenReturn(true);
      await provider.saveClipFromRecording(startSeconds: 0, endSeconds: 1);
      verifyNever(clipSaver.saveClipFromRecording(any, any, any, any, any));
      expect(provider.clipSaved, isFalse);

      // If busy the method must also return early.
      when(recording.isRecording).thenReturn(false);
      when(recording.isBusy).thenReturn(true);
      try {
        await provider.saveClipFromRecording(startSeconds: 0, endSeconds: 1);
        expect(provider.clipSaved, isFalse);
      } finally {
        when(recording.isBusy).thenReturn(false);
      }
    });

    test('saves clip when recording is inactive and not busy', () async {
      when(recording.isRecording).thenReturn(false);
      when(recording.isBusy).thenReturn(false);

      // Assume the clip saver successfully saves the clip
      when(clipSaver.saveClipFromRecording(any, any, any, any, any)).thenAnswer((_) async => true);

      await provider.saveClipFromRecording(startSeconds: 0, endSeconds: 1);
      expect(provider.clipSaved, isTrue);
      expect(notifyCount, 1);
      verify(clipSaver.saveClipFromRecording(any, any, any, any, any));
      verify(recording.lockBusy()).called(1);
      verify(recording.unlockBusy()).called(1);
    });

    test('prints to debug when saving fails', () async {
      when(recording.isRecording).thenReturn(false);
      when(recording.isBusy).thenReturn(false);

      // Assume the clip saver successfully saves the clip
      when(clipSaver.saveClipFromRecording(any, any, any, any, any)).thenThrow(Error());

      // Capture debugPrint output by intercepting print calls in a Zone.
      final debugOutput = <String>[];
      await Zone.current.fork(
        specification: ZoneSpecification(
          print: (self, parent, zone, line) {
            debugOutput.add(line);
            parent.print(zone, line);
          },
        ),
      ).run(() async {
        await provider.saveClipFromRecording(startSeconds: 0, endSeconds: 1);
      });

      expect(provider.clipSaved, isFalse);
      verify(clipSaver.saveClipFromRecording(any, any, any, any, any));
      verify(recording.lockBusy()).called(1);
      verify(recording.unlockBusy()).called(1);

      expect(debugOutput, contains(contains('Clip save failed')));
    });
  });

  group('ClipProvider.saveClipFromLive', () {
    test('exits early when controller is missing or not initialized', () async {
      // Ensure recording is true but no controller has been set — method should
      // return early without throwing and leave clipSaved false.
      when(recording.isRecording).thenReturn(true);
      when(recording.controller).thenReturn(null);

      await provider.saveClipFromLive(clipDurationSeconds: 5, secondsPre: 2);
      expect(provider.clipSaved, isFalse);

      // Also check when controller is not initialized
      final cameraController = MockCameraController();
      final cameraValue = MockCameraValue();
      when(cameraValue.isInitialized).thenReturn(false);
      when(cameraController.value).thenReturn(cameraValue);

      when(recording.isRecording).thenReturn(true);
      when(recording.controller).thenReturn(cameraController);

      await provider.saveClipFromLive(clipDurationSeconds: 5, secondsPre: 2);
      expect(provider.clipSaved, isFalse);
    });

    test('processes pending clip when idle and exits early when busy', () async {
      // Use concrete typed mocks for non-nullable params to avoid Null matcher type issues.
      when(clipSaver.processPendingClip(any, analytics, settings)).thenAnswer((_) async => true);

      when(recording.isRecording).thenReturn(false);
      when(recording.isBusy).thenReturn(false);
      await provider.saveClipFromLive(clipDurationSeconds: 5, secondsPre: 2);
      verifyNever(clipSaver.saveClipFromLive(any, any, any, any, any));
      // When not recording and not busy, saveClipFromLive processes the pending clip immediately.
      verify(clipSaver.processPendingClip(any, analytics, settings)).called(1);
      expect(provider.clipSaved, isTrue);

      // Reset the notification flag so we can verify the busy branch leaves state unchanged.
      provider.dismissClipNotification();
      expect(provider.clipSaved, isFalse);

      // If busy the method must also return early.
      when(recording.isRecording).thenReturn(true);
      when(recording.isBusy).thenReturn(true);
      await provider.saveClipFromLive(clipDurationSeconds: 5, secondsPre: 2);
      verifyNever(clipSaver.saveClipFromLive(any, any, any, any, any));
      expect(provider.clipSaved, isFalse);
      verifyNoMoreInteractions(clipSaver);

      await provider.saveClipFromLive(clipDurationSeconds: 5, secondsPre: 2);
    });

    test('saves clip when recording and not busy', () async {
      when(recording.isRecording).thenReturn(true);
      when(recording.isBusy).thenReturn(false);

      final cameraController = MockCameraController();
      final cameraValue = MockCameraValue();
      when(cameraValue.isInitialized).thenReturn(true);
      when(cameraController.value).thenReturn(cameraValue);
      when(recording.controller).thenReturn(cameraController);

      when(clipSaver.saveClipFromLive(any, any, any, any, any)).thenAnswer((_) async => true);

      // Must await the async function so lockBusy, clip save, and unlockBusy complete.
      await provider.saveClipFromLive(clipDurationSeconds: 5, secondsPre: 2);

      expect(provider.clipSaved, isTrue);
      verify(recording.lockBusy()).called(1);
      verify(clipSaver.saveClipFromLive(any, any, recording, analytics, settings)).called(1);
      verify(recording.unlockBusy()).called(1);

      expect(notifyCount, 1);
    });

    test('prints to debug when saving fails', () async {
      when(recording.isRecording).thenReturn(true);
      when(recording.isBusy).thenReturn(false);

      final cameraController = MockCameraController();
      final cameraValue = MockCameraValue();
      when(cameraValue.isInitialized).thenReturn(true);
      when(cameraController.value).thenReturn(cameraValue);
      when(recording.controller).thenReturn(cameraController);

      when(clipSaver.saveClipFromLive(any, any, any, any, any)).thenThrow(Error());

      // Capture debugPrint output by intercepting print calls in a Zone.
      final debugOutput = <String>[];
      await Zone.current.fork(
        specification: ZoneSpecification(
          print: (self, parent, zone, line) {
            debugOutput.add(line);
            parent.print(zone, line);
          },
        ),
      ).run(() async {
        // Must await the async function so lockBusy, clip save, and unlockBusy complete.
        await provider.saveClipFromLive(clipDurationSeconds: 5, secondsPre: 2);
      });

      expect(provider.clipSaved, isFalse);
      verify(recording.lockBusy()).called(1);
      verify(clipSaver.saveClipFromLive(any, any, recording, analytics, settings)).called(1);
      verify(recording.unlockBusy()).called(1);

      // Verify that a debug message containing 'Clip save failed' was printed.
      expect(debugOutput, contains(contains('Clip save failed')));
    });
  });
}
