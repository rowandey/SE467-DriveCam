import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsProvider extends ChangeNotifier {
  // Recording settings
  String framerate = '30 fps';
  String quality = '720p';
  String footageLimit = '2h';
  String storageLimit = '8GB';

  // Clip settings
  String preDurationLength = '2m';
  String postDurationLength = '2m';
  String clipStorageLimit = '4GB';

  Future<void> loadPrefs() async {
    final prefs = SharedPreferencesAsync();
    framerate = await prefs.getString('framerate') ?? '30 fps';
    quality = await prefs.getString('quality') ?? '720p';
    footageLimit = await prefs.getString('footageLimit') ?? '2h';
    storageLimit = await prefs.getString('storageLimit') ?? '8GB';
    preDurationLength = await prefs.getString('preDurationLength') ?? '2m';
    postDurationLength = await prefs.getString('postDurationLength') ?? '2m';
    clipStorageLimit = await prefs.getString('clipStorageLimit') ?? '4GB';
    notifyListeners();
  }

  void setFramerate(String value) async {
    framerate = value;
    notifyListeners();
    await SharedPreferencesAsync().setString('framerate', value);
  }

  void setQuality(String value) async {
    quality = value;
    notifyListeners();
    await SharedPreferencesAsync().setString('quality', value);
  }

  void setFootageLimit(String value) async {
    footageLimit = value;
    notifyListeners();
    await SharedPreferencesAsync().setString('footageLimit', value);
  }

  void setStorageLimit(String value) async {
    storageLimit = value;
    notifyListeners();
    await SharedPreferencesAsync().setString('storageLimit', value);
  }

  void setPreDurationLength(String value) async {
    preDurationLength = value;
    notifyListeners();
    await SharedPreferencesAsync().setString('preDurationLength', value);
  }

  void setPostDurationLength(String value) async {
    postDurationLength = value;
    notifyListeners();
    await SharedPreferencesAsync().setString('postDurationLength', value);
  }

  void setClipStorageLimit(String value) async {
    clipStorageLimit = value;
    notifyListeners();
    await SharedPreferencesAsync().setString('clipStorageLimit', value);
  }
}
