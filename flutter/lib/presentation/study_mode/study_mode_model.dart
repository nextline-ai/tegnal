import 'package:flutter/foundation.dart';

import '../../core/addons/addon_store.dart';
import '../../core/booru/booru_models.dart';
import '../../core/generation/generation_store.dart';
import '../../core/study/study_awards.dart';
import '../../core/study/study_models.dart';
import '../../core/study/study_path.dart';
import '../../core/study/study_store.dart';
import '../booru/booru_common.dart';

/// `StudyModeModel`: everything learning mode shows, read again whenever a lesson may have changed it.
/// Every screen of the mode reads from one of these and calls [reload] after it has changed the store.
class StudyModeModel extends ChangeNotifier {
  StudyModeModel(this.booru) {
    final saved = booru.booruDefaults.integer(goalKey);
    _goal = StudyGame.goals.contains(saved) ? saved : StudyGame.defaultGoal;
    _trackID = booru.booruDefaults.string(trackKey);
  }

  /// `study.goal`: the experience the learner means to earn each day.
  static const goalKey = 'study.goal';

  /// `study.track`: the add-on track the path shows; missing for the main path.
  static const trackKey = 'study.track';

  final BooruContext booru;

  /// The main path. Tracks from add-ons are finished apart from it and never count toward its badges.
  StudyPath get path => StudyPath.bundled;

  /// The app's curriculum, with the tags of the tracks that are on added after it. Lessons are started with an
  /// engine built from this one.
  StudyCurriculum curriculum = StudyCurriculum.bundled;

  /// Tracks brought by add-ons that are on.
  List<StudyTrack> tracks = const [];

  String? _trackID;

  /// The track the path shows, null for the main path.
  String? get trackID => _trackID;
  set trackID(String? value) {
    _trackID = value;
    booru.booruDefaults.set(trackKey, value);
    notifyListeners();
  }

  StudyTrack? get track => tracks.where((track) => track.id == _trackID).firstOrNull;

  /// The path being shown: the chosen track's, or the main one.
  StudyPath get shownPath => track?.path ?? path;

  Map<String, StudyLessonRecord> records = {};
  Map<String, StudyProgress> progress = {};
  List<StudyDay> days = [];
  StudySummary summary = const StudySummary();
  StudyGame game = StudyGame();

  /// The one server lessons take their pictures from.
  BooruServer server = StudyServer.fallback;

  /// True while a learner with servers of their own has not said which one to learn from.
  bool needsServer = false;

  /// Every badge, which of them are earned, and the numbers they are measured by.
  List<StudyAward> awards = [];
  Map<String, StudyAwardRecord> earned = {};
  StudyFacts facts = StudyFacts();

  /// How many tags have been missed at least once, for Weak Spots.
  int weak = 0;

  int _goal = StudyGame.defaultGoal;
  int get goal => _goal;
  set goal(int value) {
    _goal = value;
    booru.booruDefaults.set(goalKey, value);
    reload();
  }

  /// The generator's store, which badges read the picture count and the saved key from.
  GenerationStore get generation => GenerationStore.shared(booru.booruDefaults);

  T _read<T>(T Function() read, T otherwise) {
    try {
      return read();
    } on Object {
      return otherwise;
    }
  }

  /// Takes in the tracks of the add-ons that are on. A track that was turned off or removed hands the path back to the
  /// main one.
  void _loadTracks() {
    final next = AddonRuntime.shared.effects.tracks;
    if (!listEquals([for (final track in next) track.id], [for (final track in tracks) track.id]) ||
        !listEquals([for (final track in next) track.path.lessons.length], [for (final track in tracks) track.path.lessons.length])) {
      tracks = next;
      final units = [for (final track in next) ?track.unit];
      curriculum = units.isEmpty
          ? StudyCurriculum.bundled
          : StudyCurriculum(version: StudyCurriculum.bundled.version, units: [...StudyCurriculum.bundled.units, ...units]);
    }
    if (_trackID != null && !tracks.any((track) => track.id == _trackID)) {
      _trackID = null;
      booru.booruDefaults.set(trackKey, null);
    }
  }

  /// A track finished for the first time, once: the lessons of an add-on track all done, and not yet celebrated.
  StudyTrack? newlyCompletedTrack({required String finishing}) {
    final done = tracks
        .where(
          (track) =>
              track.path.lessons.any((lesson) => lesson.id == finishing) &&
              track.complete(records) &&
              !(booru.booruDefaults.boolean('study.trackDone.${track.id}') ?? false),
        )
        .firstOrNull;
    if (done == null) return null;
    booru.booruDefaults.set('study.trackDone.${done.id}', true);
    return done;
  }

  void reload() {
    _loadTracks();
    final study = booru.store.studyStore;
    days = _read(study.days, const []);
    records = _read(study.lessons, const {});
    progress = _read(study.progress, const {});
    summary = StudySummary.of(curriculum: curriculum, progress: progress, days: days);
    game = StudyGame.of(days: days, goal: _goal);
    server = StudyServer.current(booru.store, defaults: booru.booruDefaults);
    needsServer = StudyServer.needsChoice(booru.store, defaults: booru.booruDefaults);
    if (awards.isEmpty) awards = StudyAward.all(path);
    earned = _read(study.awards, const {});
    facts = StudyFacts.of(path: path, records: records, days: days, progress: progress, stats: _read(study.stats, const {}));
    weak = progress.values.where((value) => value.wrong > 0 && curriculum.contains(value.tag)).length;
    notifyListeners();
  }

  /// Chooses the server lessons take their pictures from.
  void choose(BooruServer chosen) {
    booru.booruDefaults.set(StudyServer.key, chosen.id);
    reload();
  }

  /// Brings the earned badges up to date and returns the ones not yet celebrated, in gallery order.
  List<StudyAward> refreshAwards() {
    // The generator's store can fail to open (no storage folder yet); badges that do not depend on it must not wait for it.
    GenerationStore? store;
    try {
      store = generation;
    } on Object catch (error) {
      debugPrint('StudyModeModel: the generator store is unavailable: $error');
    }
    try {
      return StudyAwards.refresh(booru.store, path: path, generation: store);
    } on Object catch (error) {
      debugPrint('StudyModeModel: badges could not be refreshed: $error');
      return const [];
    }
  }
}
