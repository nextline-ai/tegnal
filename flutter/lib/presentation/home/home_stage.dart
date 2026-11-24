import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/support/preferences.dart';
import 'home_travel.dart';

export 'home_travel.dart' show HomeRealm;

/// The place on screen once nothing is moving.
enum HomePlace { home, library, study }

/// What the app is showing, and what the home scene has to do next.
///
/// It also keeps what the native app keeps in `StudyMode`: which place lies under the scene
/// ([studying]) and the two switches that make the app go straight on to a place.
class HomeStage extends ChangeNotifier {
  HomeStage({required this.defaults, required this.booruDefaults, this.enabled = true}) : _habit = HomeHabit(defaults.string(HomeHabit.key) ?? '') {
    final starts = booruDefaults.boolean(startKey) ?? false;
    _startsLearning = starts;
    _startsInLibrary = !starts && (booruDefaults.boolean(libraryStartKey) ?? false);
    _studying = starts;
    _muted = defaults.boolean(mutedKey) ?? false;
    _prefersLibrary = _startsInLibrary || _habit.prefersLibrary(startsLearning: _startsLearning);
    if (enabled) {
      place = HomePlace.home;
      libraryWarm = _prefersLibrary;
      // Flutter builds screens on the thread that animates, so someone who goes to the library has it
      // built in the very first frame, under the blurred still, rather than during a journey.
      libraryMounted = _prefersLibrary;
      studyMounted = false;
      libraryOpened = false;
    } else {
      place = _studying ? HomePlace.study : HomePlace.library;
      libraryWarm = libraryMounted = studyMounted = libraryOpened = true;
    }
  }

  /// The stage of the running app, set in `main`. Until then, and in tests, the scene is not in use.
  static HomeStage shared = HomeStage(defaults: MemoryPreferences(), booruDefaults: MemoryPreferences(), enabled: false);

  static const mutedKey = 'home.musicOff';
  static const hintKey = 'home.returnHintsShown';

  /// Open straight into learning mode when the app starts (`StudyMode.startKey`).
  static const startKey = 'study.startInMode';

  /// Go straight on from the opening scene into the library when the app starts.
  static const libraryStartKey = 'home.startInLibrary';

  final Preferences defaults;
  final Preferences booruDefaults;

  /// Tests and screen comparisons that drive the library or learning mode directly start without the scene.
  final bool enabled;

  /// The place on screen once nothing is moving.
  late HomePlace place;

  /// A journey is under way, by finger or on its own.
  bool moving = false;

  /// The opening blur has cleared.
  bool introFinished = false;

  /// The library may read its first pages from the network.
  late bool libraryWarm;

  /// The library's screens exist.
  late bool libraryMounted;

  /// The learning screens exist.
  late bool studyMounted;

  /// The library has been on screen, so its own background work may run.
  late bool libraryOpened;

  /// The scene's hints are held back until the logo has arrived.
  bool hintsReady = false;

  /// How far the hints at the home scene have faded under a finger, from 0 to 1. Changes every frame.
  final engagement = ValueNotifier<double>(0);

  /// How far a place has been pulled toward the scene, in logical pixels, and whether letting go now goes back.
  final pull = ValueNotifier<double>(0);
  final pullArmed = ValueNotifier<bool>(false);

  /// Set by the scene's view, which does the travelling.
  void Function(HomeRealm realm)? travel;
  void Function(HomeRealm realm)? travelQuickly;
  VoidCallback? goHome;
  void Function(HomeRealm realm)? transfer;
  ValueChanged<bool>? onMutedChange;

  /// Called once, when the scene's first picture, the blurred still, has been drawn: the system's launch cover may go.
  VoidCallback? onSceneShown;

  void sceneShown() {
    final shown = onSceneShown;
    onSceneShown = null;
    shown?.call();
  }

  final HomeHabit _habit;
  late final bool _prefersLibrary;
  bool _openedPreferred = false;
  Timer? _hints;

  /// The library is worth preparing at launch: it is where this person usually goes.
  bool get prefersLibrary => _prefersLibrary;

  late bool _muted;
  bool get muted => _muted;
  set muted(bool value) {
    if (value == _muted) return;
    _muted = value;
    defaults.set(mutedKey, value);
    onMutedChange?.call(value);
    notifyListeners();
  }

  late bool _studying;

  /// Learning mode is the place under the scene, rather than the library.
  bool get studying => _studying;

  late bool _startsLearning;

  /// Open straight into learning mode when the app starts. Only one of the two start switches can be on.
  bool get startsLearning => _startsLearning;
  set startsLearning(bool value) {
    _startsLearning = value;
    booruDefaults.set(startKey, value);
    if (value && _startsInLibrary) startsInLibrary = false;
    notifyListeners();
  }

  late bool _startsInLibrary;

  /// Go straight on from the opening scene into the library when the app starts.
  bool get startsInLibrary => _startsInLibrary;
  set startsInLibrary(bool value) {
    _startsInLibrary = value;
    booruDefaults.set(libraryStartKey, value);
    if (value && _startsLearning) startsLearning = false;
    notifyListeners();
  }

  /// The scene covers the screen: nothing underneath should ask a question or speak.
  bool get coversScreen => enabled && (place == HomePlace.home || moving);
  bool get atHome => enabled && place == HomePlace.home;

  /// The library is what shows, with nothing moving: viewing mode's own first-run questions wait for this.
  bool get libraryOnScreen => place == HomePlace.library && !moving;

  /// The place the app is set to open in, if any. The scene is then passed through quickly, not skipped.
  HomeRealm? get preferred => _startsLearning
      ? HomeRealm.study
      : _startsInLibrary
      ? HomeRealm.library
      : null;

  /// Goes on to the place the app is set to open in, once, after the opening blur.
  void openPreferred({Duration after = Duration.zero}) {
    final realm = preferred;
    if (!enabled || _openedPreferred || !introFinished || realm == null) return;
    _openedPreferred = true;
    Timer(after, () {
      if (place != HomePlace.home || moving) return;
      travelQuickly?.call(realm);
    });
  }

  /// The first picture is on screen. Someone who goes to the library already has it built behind the scene.
  void introStarted() {
    if (!enabled || !_prefersLibrary || libraryMounted) return;
    libraryMounted = true;
    notifyListeners();
  }

  void finishIntro() {
    if (introFinished) return;
    introFinished = true;
    notifyListeners();
    openPreferred();
    _hints = Timer(const Duration(milliseconds: 2200), () {
      hintsReady = true;
      notifyListeners();
    });
  }

  /// A finger is heading for the library: its first pages can be on their way before it lets go.
  void leanToward(HomeRealm realm) {
    if (realm == HomeRealm.library && !libraryWarm) {
      libraryWarm = true;
      notifyListeners();
    }
  }

  /// Builds a place's screens under the scene and makes it the place underneath. True when they were not built yet,
  /// so that the caller lets a frame pass before animating.
  bool mount(HomeRealm realm) {
    final study = realm == HomeRealm.study;
    final fresh = study ? !studyMounted : !libraryMounted;
    if (!fresh && _studying == study) return false;
    _studying = study;
    if (study) {
      studyMounted = true;
    } else {
      libraryMounted = true;
      libraryWarm = true;
    }
    notifyListeners();
    return fresh;
  }

  /// Letting go has chosen a place. Its screens were built under the scene before the journey started.
  void depart(HomeRealm realm) {
    moving = true;
    _habit.record(realm);
    defaults.set(HomeHabit.key, _habit.recent);
    if (realm == HomeRealm.library) libraryWarm = true;
    mount(realm);
    notifyListeners();
  }

  void arrive(HomeRealm realm) {
    place = realm == HomeRealm.library ? HomePlace.library : HomePlace.study;
    if (realm == HomeRealm.library) libraryOpened = true;
    moving = false;
    _resetHands();
    notifyListeners();
  }

  void beginReturn() => _setMoving(true);

  void cancelReturn() {
    pull.value = 0;
    pullArmed.value = false;
    _setMoving(false);
  }

  void beginDrag() => _setMoving(true);

  void cancelDrag() {
    engagement.value = 0;
    _setMoving(false);
  }

  void arriveHome() {
    place = HomePlace.home;
    moving = false;
    _resetHands();
    notifyListeners();
  }

  /// Goes from the place on screen to the other one by way of the home scene: back along one journey and out along the other.
  /// False where the scene is not in use, or is itself on screen; the caller then switches places as before.
  bool cross(HomeRealm realm) {
    final transfer = this.transfer;
    if (!enabled || place == HomePlace.home || transfer == null) return false;
    if (!moving && place != (realm == HomeRealm.study ? HomePlace.study : HomePlace.library)) transfer(realm);
    return true;
  }

  /// Opens learning mode (`StudyMode.enter`): through the scene where it is in use, directly where it is not.
  void enterStudy() {
    if (cross(HomeRealm.study)) return;
    _studying = true;
    follow(studying: true);
    notifyListeners();
  }

  /// Opens the library by the same way in the other direction (`StudyMode.leave`).
  void leaveStudy() {
    if (cross(HomeRealm.library)) return;
    _studying = false;
    follow(studying: false);
    notifyListeners();
  }

  /// Where the scene is not in use, learning mode and the library still open each other directly; the scene keeps up with whichever shows.
  void follow({required bool studying}) {
    if (place == HomePlace.home || moving) return;
    place = studying ? HomePlace.study : HomePlace.library;
    if (studying) {
      studyMounted = true;
    } else {
      libraryWarm = libraryMounted = libraryOpened = true;
    }
    notifyListeners();
  }

  /// The way back is shown the first few times a place is reached.
  bool takeReturnHint() {
    final shown = defaults.integer(hintKey);
    if (shown >= 3) return false;
    defaults.set(hintKey, shown + 1);
    return true;
  }

  void _setMoving(bool value) {
    if (moving == value) return;
    moving = value;
    notifyListeners();
  }

  void _resetHands() {
    engagement.value = 0;
    pull.value = 0;
    pullArmed.value = false;
  }

  @override
  void dispose() {
    _hints?.cancel();
    engagement.dispose();
    pull.dispose();
    pullArmed.dispose();
    super.dispose();
  }
}
