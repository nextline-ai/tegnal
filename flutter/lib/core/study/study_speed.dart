import 'dart:math';

import 'package:flutter/foundation.dart';

import '../booru/booru_store.dart';
import '../support/swift_json.dart';
import 'study_awards.dart';
import 'study_engine.dart';
import 'study_models.dart';
import 'study_store.dart';

enum StudySpeedPhase { ready, playing, finished }

/// A minute of quick questions on tags already met: a meaning is shown, and the tag is tapped. No picture is fetched,
/// so nothing waits on the network.
class StudySpeedRound extends ChangeNotifier {
  StudySpeedRound({required this.store, StudyCurriculum? curriculum, Random? random, DateTime Function()? now, this.utcOffset})
    : _random = random ?? Random(),
      _now = now ?? DateTime.now,
      id = uuidString(),
      tags = met(_progressOf(store), curriculum: curriculum ?? StudyCurriculum.bundled) {
    try {
      best = store.studyStore.stats()[StudyCounter.speed] ?? 0;
    } on Object {
      best = 0;
    }
  }

  static const length = 60.0;
  static const most = 20;

  /// Tags needed before a round can offer four different answers.
  static const needed = 4;

  final String id;
  final BooruStore store;

  /// The zone days are counted in, for tests; the device's own when null.
  final Duration? utcOffset;
  final Random _random;
  final DateTime Function() _now;

  /// The tags a round may ask: the ones answered at least once.
  final List<StudyTag> tags;

  var _phase = StudySpeedPhase.ready;
  StudyQuestion? _question;
  var _score = 0;
  var _asked = 0;
  var _combo = 0;
  var _bestCombo = 0;
  bool? _last;
  var _ends = DateTime.utc(4001);
  var _earned = 0;
  var _record = false;
  var _disposed = false;

  /// The best score so far, as it stood when the round was made.
  late int best;

  StudySpeedPhase get phase => _phase;
  StudyQuestion? get question => _question;
  int get score => _score;
  int get asked => _asked;
  int get combo => _combo;
  int get bestCombo => _bestCombo;

  /// Whether the last answer was right, until the next question is shown.
  bool? get last => _last;

  /// When the round ends; far in the future before it starts.
  DateTime get ends => _ends;
  int get earned => _earned;
  bool get record => _record;

  static Map<String, StudyProgress> _progressOf(BooruStore store) {
    try {
      return store.studyStore.progress();
    } on Object {
      return {};
    }
  }

  /// The tags a round may ask: the ones answered at least once.
  static List<StudyTag> met(Map<String, StudyProgress> progress, {required StudyCurriculum curriculum}) => [
    for (final tag in curriculum.tags)
      if (progress[tag.name] case final value? when !value.isNew) tag,
  ];

  /// Experience for a round: a point for each right answer, up to a ceiling.
  static int reward(int score) => min(most, max(0, score));

  bool get canPlay => tags.length >= needed;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void start([DateTime? now]) {
    if (!canPlay || _phase != StudySpeedPhase.ready) return;
    _phase = StudySpeedPhase.playing;
    _ends = (now ?? _now()).add(const Duration(seconds: 60));
    _ask();
    _changed();
  }

  void _ask() {
    final others = tags.where((tag) => tag.name != _question?.tag.name).toList();
    if (others.isEmpty) return;
    final tag = others[_random.nextInt(others.length)];
    final wrong = shuffledWith(tags.where((value) => value.name != tag.name), _random).take(3);
    final choices = shuffledWith([...wrong, tag], _random);
    _question = StudyQuestion(kind: StudyQuestionKind.meaningToTag, tag: tag, choices: choices, answer: max(0, choices.indexOf(tag)));
    _last = null;
  }

  /// Takes an answer and moves straight on. Returns whether it was right.
  bool answer(int index) {
    final current = _question;
    if (_phase != StudySpeedPhase.playing || current == null || _last != null) return false;
    final right = index == current.answer;
    _asked += 1;
    if (right) {
      _score += 1;
      _combo += 1;
      _bestCombo = max(_bestCombo, _combo);
    } else {
      _combo = 0;
    }
    _last = right;
    _changed();
    return right;
  }

  void next() {
    if (_phase != StudySpeedPhase.playing) return;
    _ask();
    _changed();
  }

  void finish() {
    if (_phase != StudySpeedPhase.playing) return;
    _phase = StudySpeedPhase.finished;
    _earned = reward(_score);
    _record = _score > best && _score > 0;
    try {
      if (_earned > 0) store.studyStore.earn(_earned, now: _now(), utcOffset: utcOffset);
      store.studyStore.raise(StudyCounter.speed, _score);
      store.studyStore.raise(StudyCounter.combo, _bestCombo);
    } on Object {
      // The result is still shown when it cannot be saved.
    }
    _changed();
  }
}
