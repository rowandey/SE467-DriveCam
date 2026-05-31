// Sensor provider unit tests, impact detection logic is tested in sensor_provider_impact_test.dart with CSV fixtures that replay real sensor data.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'package:drivecam/provider/sensor_provider.dart';

import 'package:drivecam/provider/recording_provider.dart';
import 'package:drivecam/provider/clip_provider.dart';
import 'package:drivecam/provider/settings_provider.dart';
import 'package:drivecam/analytics/analytics_controller.dart';
import 'package:drivecam/services/sensor_service.dart';


@GenerateNiceMocks([MockSpec<RecordingProvider>()])
@GenerateNiceMocks([MockSpec<ClipProvider>()])
@GenerateNiceMocks([MockSpec<SettingsProvider>()])
@GenerateNiceMocks([MockSpec<AnalyticsController>()])
@GenerateNiceMocks([MockSpec<SensorEventSource>()])
import 'sensor_provider_test.mocks.dart';

void main() {
  setUp(() {

  });

  group('SensorProvider', () {
    test('listens to recording state changes', () {
      final analyticsController = MockAnalyticsController();
      final settingsProvider = MockSettingsProvider();
      final recordingProvider = MockRecordingProvider();
      final clipProvider = MockClipProvider();

      final sensorProvider = SensorProvider(
        recordingProvider,
        clipProvider,
        settingsProvider,
      );

      expect(sensorProvider, isNotNull);
      verify(recordingProvider.addListener(any));
    });
  });

  group('SensorProvider.setEnabled', () {
    late SensorProvider sensorProvider;
    late int notifyCount = 0;

    late MockRecordingProvider recordingProvider;
    late MockSensorEventSource sensorEventSource;

    setUp(() {
      recordingProvider = MockRecordingProvider();
      sensorEventSource = MockSensorEventSource();

      sensorProvider = SensorProvider(
          recordingProvider,
          MockClipProvider(),
          MockSettingsProvider(),
          sensorSource: sensorEventSource
      );
      notifyCount = 0;
      sensorProvider.addListener(() => notifyCount++ );
    });

    test('starts listening when enabled and recording, then notifies listeners', () {
      when(recordingProvider.isRecording).thenReturn(true);

      sensorProvider.setEnabled(true);
      expect(sensorProvider.enabled, isTrue);
      expect(notifyCount, 1);

      verify(sensorEventSource.start()).called(1);
      verify(sensorEventSource.userAccelerometerStream);
      verify(sensorEventSource.gyroscopeStream);
    });

    test('just notifies listeners when enabled and not recording', () {
      when(recordingProvider.isRecording).thenReturn(false);

      sensorProvider.setEnabled(true);
      expect(sensorProvider.enabled, isTrue);
      expect(notifyCount, 1);

      verifyNever(sensorEventSource.start());
      verifyNever(sensorEventSource.userAccelerometerStream);
      verifyNever(sensorEventSource.gyroscopeStream);
    });

    test('stops listening when disabled, then notifies listeners', () {
      when(recordingProvider.isRecording).thenReturn(true);

      sensorProvider.setEnabled(false);
      expect(sensorProvider.enabled, isFalse);
      expect(notifyCount, 1);

      verify(sensorEventSource.stop()).called(1);
    });
  });

  group('SensorProvider._onRecordingChanged', () {
    late SensorProvider sensorProvider;

    late RecordingProvider recordingProvider;
    late MockSensorEventSource sensorEventSource;

    setUp(() {
      recordingProvider = RecordingProvider(MockSettingsProvider(), MockAnalyticsController());
      sensorEventSource = MockSensorEventSource();

      sensorProvider = SensorProvider(
          recordingProvider,
          MockClipProvider(),
          MockSettingsProvider(),
          sensorSource: sensorEventSource
      );
    });

    test('listens when recording is started and provider is enabled', () {
      recordingProvider.isRecording = true;
      recordingProvider.notifyListeners();

      verify(sensorEventSource.start()).called(1);
      verify(sensorEventSource.userAccelerometerStream);
      verify(sensorEventSource.gyroscopeStream);
    });

    test('stops listening when recording is stopped and provider is enabled', () {
      recordingProvider.isRecording = false;
      recordingProvider.notifyListeners();

      verify(sensorEventSource.stop()).called(1);
      verifyNever(sensorEventSource.userAccelerometerStream);
      verifyNever(sensorEventSource.gyroscopeStream);
    });

    test("doesn't do anything when disabled", () {
      sensorProvider.setEnabled(false);

      recordingProvider.isRecording = true;
      recordingProvider.notifyListeners();

      verifyNever(sensorEventSource.start());
      verifyNever(sensorEventSource.userAccelerometerStream);
      verifyNever(sensorEventSource.gyroscopeStream);
    });
  });

  group('SensorProvider.onTrigger', () {
    late SensorProvider sensorProvider;

    late MockSettingsProvider settingsProvider;
    late MockClipProvider clipProvider;

    setUp(() {
      settingsProvider = MockSettingsProvider();
      clipProvider = MockClipProvider();

      sensorProvider = SensorProvider(
          MockRecordingProvider(),
          clipProvider,
          settingsProvider,
          sensorSource: MockSensorEventSource()
      );
    });

    test('saves a clip immediately when post duration clip length is 0', () {
      when(settingsProvider.preDurationLength).thenReturn('5s');
      when(settingsProvider.postDurationLength).thenReturn('0s');

      sensorProvider.onTrigger();

      verify(clipProvider.saveClipFromLive(clipDurationSeconds: 5, secondsPre: 5, triggerType: 'sensor')).called(1);
    });

    test('starts a clip save when post duration clip length is >0', () {
      when(settingsProvider.preDurationLength).thenReturn('5s');
      when(settingsProvider.postDurationLength).thenReturn('5s');

      fakeAsync((async) {
        sensorProvider.onTrigger();

        verify(clipProvider.startClipProgress(5)).called(1);

        // Timer hasn't fired yet, so clip shouldn't be saved
        verifyNever(clipProvider.saveClipFromLive(
            clipDurationSeconds: anyNamed("clipDurationSeconds"),
            secondsPre: anyNamed("secondsPre"),
            triggerType: anyNamed("triggerType"))
        );

        // Advance time to trigger the timer
        async.elapse(const Duration(seconds: 5));

        // Clip should have been saved now
        verify(clipProvider.saveClipFromLive(
            clipDurationSeconds: 5 + 5,
            secondsPre: 5,
            triggerType: 'sensor')
        ).called(1);
      });
    });
  });
}
