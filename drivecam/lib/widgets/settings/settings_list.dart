// settings_list.dart
// Shared settings UI used by both the main Settings screen and the onboarding
// flow. Renders dropdowns for recording/clip preferences and toggle switches
// for boolean settings (audio, dark mode). All state is owned by the providers
// passed in — this widget is purely presentational.

import 'package:drivecam/provider/settings_provider.dart';
import 'package:drivecam/provider/theme_provider.dart';
import 'package:drivecam/provider/recording_provider.dart';
import 'package:drivecam/widgets/settings/setting_dropdown.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../analytics/analytics_controller.dart';

// Formats a byte count into a human-readable GB or MB string.
// Returns GB with one decimal place if >= 1 GB, otherwise MB rounded.
String _formatBytes(double bytes) {
  final gb = bytes / (1024 * 1024 * 1024);
  if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
}

// Computes an estimated storage size for one hour of footage and shows it in
// a dialog. Uses the same bitrate table as the recording pipeline so the
// estimate reflects what the app will actually write to disk.
//
// Formula: bytes = (video_bps + audio_bps) × 3600 s ÷ 8 bits/byte
// Audio adds a flat 128 kbps (AAC stereo) when audio is enabled.
const int _audioBitrate = 128000; // 128 kbps AAC stereo

void _showStorageEstimateDialog(
    BuildContext context, SettingsProvider settings) {
  final videoBitrate =
      SettingsProvider.videoBitrateForSettings(settings.quality, settings.framerate);
  // Add audio bitrate only when audio recording is enabled.
  final totalBitrate = settings.audioEnabled ? videoBitrate + _audioBitrate : videoBitrate;
  final bytes = totalBitrate * 3600 / 8;
  final mbps = (totalBitrate / 1000000).toStringAsFixed(2);
  final sizeStr = _formatBytes(bytes);

  final audioNote = settings.audioEnabled
      ? 'Includes 128 kbps audio.'
      : 'Audio is off — enable it in settings to include audio in the estimate.';

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('1-Hour Storage Estimate'),
      content: Text(
        'At ${settings.quality} / ${settings.framerate}, one hour of footage '
        'uses approximately $sizeStr.\n\n'
        'This is based on a total bitrate of $mbps Mbps. $audioNote Actual size '
        'may vary slightly depending on scene complexity.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Got it'),
        ),
      ],
    ),
  );
}

class SettingsList extends StatelessWidget {
  const SettingsList({
    super.key,
    required this.settingsProvider,
    required this.isDark,
    required this.themeProvider,
  });

  final SettingsProvider settingsProvider;
  final bool isDark;
  final ThemeProvider themeProvider;

  // Shows a clear warning that the current recording must be stopped and
  // restarted before a recording-specific setting can take effect.
  Future<void> _showRecordingRestartDialog(BuildContext context) async {
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restart recording required'),
        content: const Text(
          'Stop the current recording, then start a new session to apply this change.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // Applies a settings change, tracks it, and warns the user if the change
  // needs a fresh recording session to take effect.
  Future<void> _applyRecordingSettingChange({
    required BuildContext context,
    required SettingsProvider settingsProvider,
    required AnalyticsController analytics,
    required String settingName,
    required Object value,
    required VoidCallback applyChange,
  }) async {
    applyChange();
    analytics.trackSettingChanged(
      settings: settingsProvider,
      settingName: settingName,
      value: value,
    );

    final recordingProvider = context.read<RecordingProvider>();
    if (recordingProvider.isRecording) {
      await _showRecordingRestartDialog(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final analytics = context.read<AnalyticsController>();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text("Recording", style: TextStyle(fontSize: 22)),
        SettingDropdown(
          label: 'Framerate',
          value: settingsProvider.framerate,
          options: SettingsProvider.framerateOptions,
          onChanged: (value) => _applyRecordingSettingChange(
            context: context,
            settingsProvider: settingsProvider,
            analytics: analytics,
            settingName: 'framerate',
            value: value,
            applyChange: () => settingsProvider.setFramerate(value),
          ),
        ),
        SettingDropdown(
          label: 'Quality',
          value: settingsProvider.quality,
          options: SettingsProvider.qualityOptions,
          onChanged: (value) => _applyRecordingSettingChange(
            context: context,
            settingsProvider: settingsProvider,
            analytics: analytics,
            settingName: 'quality',
            value: value,
            applyChange: () => settingsProvider.setQuality(value),
          ),
        ),
        SettingDropdown(
          label: 'Rolling Footage Limit',
          value: settingsProvider.footageLimit,
          options: SettingsProvider.footageLimitOptions,
          onChanged: (value) => _applyRecordingSettingChange(
            context: context,
            settingsProvider: settingsProvider,
            analytics: analytics,
            settingName: 'rolling_footage_limit',
            value: value,
            applyChange: () => settingsProvider.setFootageLimit(value),
          ),
        ),
        SettingDropdown(
          label: 'Footage Storage Limit',
          value: settingsProvider.storageLimit,
          options: SettingsProvider.storageLimitOptions,
          onChanged: (value) => _applyRecordingSettingChange(
            context: context,
            settingsProvider: settingsProvider,
            analytics: analytics,
            settingName: 'footage_storage_limit',
            value: value,
            applyChange: () => settingsProvider.setStorageLimit(value),
          ),
        ),
        // Info button that estimates how much storage 1 hour of footage uses
        // based on the currently selected quality and framerate. Tapping opens
        // a dialog so the user can plan their storage limit accordingly.
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => _showStorageEstimateDialog(context, settingsProvider),
            icon: const Icon(Icons.info_outline, size: 14),
            label: const Text('How much space does 1 hr use?', style: TextStyle(fontSize: 12)),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text("Audio", style: Theme.of(context).textTheme.bodyLarge),
            Switch(
              value: settingsProvider.audioEnabled,
              onChanged: (value) {
                settingsProvider.setAudioEnabled(value);
                analytics.trackSettingChanged(
                  settings: settingsProvider,
                  settingName: 'audio_enabled',
                  value: value,
                );
              },
            ),
          ],
        ),

        Divider(),

        Text("Clipping", style: TextStyle(fontSize: 22)),
        SettingDropdown(
          label: 'Clip Pre-Duration',
          value: settingsProvider.preDurationLength,
          options: SettingsProvider.clipDurationOptions,
            onChanged: (value) {
              settingsProvider.setPreDurationLength(value);
              analytics.trackSettingChanged(
                settings: settingsProvider,
                settingName: 'clip_pre_duration',
                value: value,
              );
            },
        ),
        SettingDropdown(
          label: 'Clip Post-Duration',
          value: settingsProvider.postDurationLength,
          options: SettingsProvider.clipDurationOptions,
            onChanged: (value) {
              settingsProvider.setPostDurationLength(value);
              analytics.trackSettingChanged(
                settings: settingsProvider,
                settingName: 'clip_post_duration',
                value: value,
              );
            },
        ),
        SettingDropdown(
          label: 'Clip Storage Limit',
          value: settingsProvider.clipStorageLimit,
          options: SettingsProvider.clipStorageLimitOptions,
            onChanged: (value) {
              settingsProvider.setClipStorageLimit(value);
              analytics.trackSettingChanged(
                settings: settingsProvider,
                settingName: 'clip_storage_limit',
                value: value,
              );
            },
        ),
        // Voice clip toggle: when enabled, saying "clip" while recording
        // saves a clip without needing to tap the screen.
        // Disabling it stops the speech recognizer, saving battery and CPU.
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Voice Clip", style: Theme.of(context).textTheme.bodyLarge),
                  Text(
                    'Say "clip" while recording to clip. May encounter issues if audio is turned on.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Switch(
              value: settingsProvider.voiceClipEnabled,
              onChanged: (value) {
                settingsProvider.setVoiceClipEnabled(value);
                analytics.trackSettingChanged(
                  settings: settingsProvider,
                  settingName: 'voice_clip_enabled',
                  value: value,
                );
              },
            ),
          ],
        ),

        Divider(),

        Text("Privacy & Analytics", style: TextStyle(fontSize: 22)),
        Text(
          'Help improve DriveCam on Android and iOS by sharing anonymous usage metrics like session activity, recording activity, clip saves, and the settings you use most often. This stays off unless you opt in.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  "Share Anonymous Usage Metrics",
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ),
            Switch(
              value: settingsProvider.analyticsEnabled,
              onChanged: (value) async {
                settingsProvider.setAnalyticsEnabled(value);
                await analytics.setConsent(
                  value,
                  settings: settingsProvider,
                );
              },
            ),
          ],
        ),

        Divider(),

        Text("Misc", style: TextStyle(fontSize: 22)),

        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text("Dark Mode", style: Theme.of(context).textTheme.bodyLarge),
            // TODO: update switch themeing to work with darkmode
            Switch(
              value: isDark,
              onChanged: (value) => themeProvider.setDarkMode(value),
            ),
          ],
        ),
      ],
    );
  }
}
