import 'package:flutter/foundation.dart';

/// The two libraries, as `AppMode` in the native app.
enum AppMode { manga, booru }

/// Root destinations shared by both libraries, as `AppTab`.
enum AppTab { folders, works, artists, settings, insights }

/// The selection the root views share: which library and which tab.
class AppState extends ChangeNotifier {
  // ignore: prefer_initializing_formals
  AppState({AppMode mode = AppMode.manga, AppTab tab = AppTab.folders}) : _mode = mode, _tab = tab;

  AppMode _mode;
  AppTab _tab;

  AppMode get mode => _mode;
  set mode(AppMode value) {
    if (value == _mode) return;
    _mode = value;
    notifyListeners();
  }

  /// The theme or language changed in Settings, so the app rebuilds around it.
  void appearanceChanged() => notifyListeners();

  AppTab get tab => _tab;
  set tab(AppTab value) {
    if (value == _tab) return;
    _tab = value;
    notifyListeners();
  }
}
