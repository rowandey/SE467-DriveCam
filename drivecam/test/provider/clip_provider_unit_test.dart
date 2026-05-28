import 'package:drivecam/analytics/analytics_client.dart';
import 'package:drivecam/analytics/analytics_controller.dart';
import 'package:drivecam/provider/clip_provider.dart';
import 'package:drivecam/provider/recording_provider.dart';
import 'package:drivecam/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  // Helper that returns a freshly wired provider trio for tests.
  ClipProvider makeProvider({
    SettingsProvider? settings,
    AnalyticsController? analytics,
    RecordingProvider? recording,
  }) {
    final s = settings ?? SettingsProvider();
    final a = analytics ?? AnalyticsController(const NoopAnalyticsClient());
    final r = recording ?? RecordingProvider(s, a);
    return ClipProvider(r, s, a);
  }

  test('markClipSaved and dismissClipNotification toggle flags and notify', () {
    final settings = SettingsProvider();
    final analytics = AnalyticsController(const NoopAnalyticsClient());
    final recording = RecordingProvider(settings, analytics);
    final provider = makeProvider(settings: settings, analytics: analytics, recording: recording);
    var notifications = 0;
    provider.addListener(() => notifications++);

    expect(provider.clipSaved, isFalse);

    provider.markClipSaved();
    expect(provider.clipSaved, isTrue);
    expect(notifications, 1);

    provider.dismissClipNotification();
    expect(provider.clipSaved, isFalse);
    expect(notifications, 2);
  });

  test('startClipProgress sets progress state and end time', () {
    final settings = SettingsProvider();
    final analytics = AnalyticsController(const NoopAnalyticsClient());
    final recording = RecordingProvider(settings, analytics);
    final provider = makeProvider(settings: settings, analytics: analytics, recording: recording);

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
  });

  test('saveClipFromRecording returns early when recording is active or busy', () async {
    final settings = SettingsProvider();
    final analytics = AnalyticsController(const NoopAnalyticsClient());
    final recording = RecordingProvider(settings, analytics);
    final provider = makeProvider(settings: settings, analytics: analytics, recording: recording);

    // If recording is active the method must return without throwing and
    // clipSaved must remain false.
    recording.isRecording = true;
    await provider.saveClipFromRecording(startSeconds: 0, endSeconds: 1);
    expect(provider.clipSaved, isFalse);

    // If busy the method must also return early.
    recording.isRecording = false;
    recording.lockBusy();
    try {
      await provider.saveClipFromRecording(startSeconds: 0, endSeconds: 1);
      expect(provider.clipSaved, isFalse);
    } finally {
      recording.unlockBusy();
    }
  });

  test('saveClipFromLive exits early when controller is missing or not initialized', () async {
    final settings = SettingsProvider();
    final analytics = AnalyticsController(const NoopAnalyticsClient());
    final recording = RecordingProvider(settings, analytics);
    final provider = makeProvider(settings: settings, analytics: analytics, recording: recording);

    // Ensure recording is true but no controller has been set — method should
    // return early without throwing and leave clipSaved false.
    recording.isRecording = true;

    await provider.saveClipFromLive(clipDurationSeconds: 5, secondsPre: 2);
    expect(provider.clipSaved, isFalse);
  });
}
