# Vosk Model Setup

DriveCam uses [Vosk](https://alphacephei.com/vosk/) for offline, on-device speech
recognition. No API key or internet connection is required at runtime.

## Step 1 — Download the model

Download the small English model zip (~40 MB) from the Vosk model page:

```
https://alphacephei.com/vosk/models
```

Look for **vosk-model-small-en-us-0.15** and download the `.zip` file.

## Step 2 — Place the file

Copy the downloaded zip into this directory **without extracting it**:

```
assets/models/vosk-model-small-en-us-0.15.zip
```

The file must have exactly that name. The app's `ModelLoader.loadFromAssets()`
call extracts and caches it to local storage on first launch, so users only pay
the extraction cost once.

## Step 3 — Verify pubspec.yaml

`pubspec.yaml` already declares this directory as a Flutter asset:

```yaml
flutter:
  assets:
    - assets/models/
```

Run `flutter pub get` after adding the file, then rebuild the app.

## Notes

- The zip file is ~40 MB. Make sure it is listed in `.gitignore` if your
  repository has size limits (GitHub rejects files > 100 MB).
- The grammar restriction (`['clip', '[unk]']`) means the recognizer only
  ever outputs "clip" or "[unk]" — CPU usage is minimal.
- Voice clipping only works on **Android** (vosk_flutter ships an Android
  MethodChannel binding). iOS is not supported by the library.
