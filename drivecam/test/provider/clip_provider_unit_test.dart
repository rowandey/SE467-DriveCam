import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'package:drivecam/analytics/analytics_client.dart';
import 'package:drivecam/analytics/analytics_controller.dart';
import 'package:drivecam/provider/clip_provider.dart';
import 'package:drivecam/provider/recording_provider.dart';
import 'package:drivecam/provider/settings_provider.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

@GenerateNiceMocks([MockSpec<RecordingProvider>()])
@GenerateNiceMocks([MockSpec<SettingsProvider>()])
@GenerateNiceMocks([MockSpec<AnalyticsController>()])
import 'clip_provider_unit_test.mocks.dart';

void main() {
  late MockRecordingProvider recording;
  late ClipProvider provider;

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

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();

    recording = MockRecordingProvider();
    provider = makeProvider(settings: MockSettingsProvider(), analytics: MockAnalyticsController(), recording: recording);
  });

  test('markClipSaved and dismissClipNotification toggle flags and notify', () {
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
    // If recording is active the method must return without throwing and
    // clipSaved must remain false.
    when(recording.isRecording).thenReturn(true);
    await provider.saveClipFromRecording(startSeconds: 0, endSeconds: 1);
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

  test('saveClipFromLive exits early when controller is missing or not initialized', () async {
    // Ensure recording is true but no controller has been set — method should
    // return early without throwing and leave clipSaved false.
    when(recording.isRecording).thenReturn(true);
    when(recording.controller).thenReturn(null);


    await provider.saveClipFromLive(clipDurationSeconds: 5, secondsPre: 2);
    expect(provider.clipSaved, isFalse);
  });
}
