// Theme provider tests

import 'package:drivecam/provider/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  late ThemeProvider themeProvider;
  setUp(() {
    themeProvider = ThemeProvider();
  });

  group('ThemeProvider.setDarkMode', () {
    test('sets theme to dark and saves preference', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
            'darkMode': false,
          });

      themeProvider.setDarkMode(true);

      expect(themeProvider.themeMode, ThemeMode.dark);
      final prefs = SharedPreferencesAsyncPlatform.instance;
      expect(await prefs!.getBool('darkMode', SharedPreferencesOptions()), true);
    });

    test('sets theme to light and saves preference', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
            'darkMode': true,
          });

      themeProvider.setDarkMode(false);

      expect(themeProvider.themeMode, ThemeMode.light);
      final prefs = SharedPreferencesAsyncPlatform.instance;
      expect(await prefs!.getBool('darkMode', SharedPreferencesOptions()), false);
    });
  });

  group('ThemeProvider.loadDarkModePrefs', () {
    test('sets theme to dark when darkMode is true', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
            'darkMode': true,
          });

      await themeProvider.loadDarkModePrefs();

      expect(themeProvider.themeMode, ThemeMode.dark);
    });

    test('sets theme to light when darkMode is false', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
            'darkMode': false,
          });

      await themeProvider.loadDarkModePrefs();

      expect(themeProvider.themeMode, ThemeMode.light);
    });
  });
}
