# Porcupine Keyword Setup

DriveCam uses [Picovoice Porcupine](https://picovoice.ai/platform/porcupine/) for
hands-free "clip" detection. Porcupine runs entirely on-device — no internet required
during use — and is optimized for always-on listening alongside other audio (like the
camera microphone).

## Steps to enable voice clip

### 1. Get a free AccessKey
1. Go to <https://console.picovoice.ai> and create a free account.
2. Copy your **AccessKey** from the dashboard.
3. Open `lib/widgets/camera_view.dart` and paste it into the constant:
   ```dart
   static const String _kPorcupineAccessKey = 'YOUR_KEY_HERE';
   ```
   > Keep this key out of version control. Use a `.env` file or
   > Flutter's `--dart-define` flag for any production build.

### 2. Generate the "clip" keyword model
1. In Picovoice Console, open the **Keyword Trainer** (Wake Word tab).
2. Type `clip` as the wake phrase and click **Train**.
3. Download the model file for **Android** → save as:
   ```
   assets/keywords/clip_android.ppn
   ```
4. Download the model file for **iOS** → save as:
   ```
   assets/keywords/clip_ios.ppn
   ```

### 3. Register the assets
The `pubspec.yaml` already declares `assets/keywords/` so Flutter will
bundle these files automatically. No further changes needed.

### 4. Run the app
```bash
flutter clean && flutter pub get && flutter run
```

## Sensitivity
The default sensitivity is `0.5` (range 0.0–1.0). A higher value detects
the keyword more aggressively but may produce false positives in noisy
environments. Adjust `_kPorcupineSensitivity` in `camera_view.dart` if needed.
