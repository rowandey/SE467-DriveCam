// Tests for the shared settings list, including the restart-required warning
// shown when a recording-specific setting changes during an active session.

import 'package:drivecam/analytics/analytics_client.dart';
import 'package:drivecam/analytics/analytics_controller.dart';
import 'package:drivecam/provider/recording_provider.dart';
import 'package:drivecam/provider/settings_provider.dart';
import 'package:drivecam/provider/theme_provider.dart';
import 'package:drivecam/widgets/settings/settings_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets(
    'shows a restart warning when a recording setting changes mid-session',
    (tester) async {
      final settingsProvider = SettingsProvider();
      final analyticsController = AnalyticsController(const NoopAnalyticsClient());
      final recordingProvider = RecordingProvider(
        settingsProvider,
        analyticsController,
      )..isRecording = true;
      final themeProvider = ThemeProvider();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider.value(value: analyticsController),
            ChangeNotifierProvider.value(value: settingsProvider),
            ChangeNotifierProvider.value(value: recordingProvider),
            ChangeNotifierProvider.value(value: themeProvider),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SettingsList(
                settingsProvider: settingsProvider,
                isDark: false,
                themeProvider: themeProvider,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(EditableText).first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('1080p').last);
      await tester.pumpAndSettle();

      expect(find.text('Restart recording required'), findsOneWidget);
      expect(
        find.text(
          'Stop the current recording, then start a new session to apply this change.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('audio changes do not show the restart warning', (tester) async {
    final settingsProvider = SettingsProvider();
    final analyticsController = AnalyticsController(const NoopAnalyticsClient());
    final recordingProvider = RecordingProvider(
      settingsProvider,
      analyticsController,
    )..isRecording = true;
    final themeProvider = ThemeProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider.value(value: analyticsController),
          ChangeNotifierProvider.value(value: settingsProvider),
          ChangeNotifierProvider.value(value: recordingProvider),
          ChangeNotifierProvider.value(value: themeProvider),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SettingsList(
              settingsProvider: settingsProvider,
              isDark: false,
              themeProvider: themeProvider,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    expect(find.text('Restart recording required'), findsNothing);
  });
}