import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../booru/booru_models.dart';
import '../support/l10n.dart';
import '../support/sql_database.dart';
import '../support/swift_json.dart';
import 'challenge_models.dart';
import 'challenge_store.dart';

class ChallengeMission {
  ChallengeMission({String? id, required this.selections, required this.kind, required this.goal, required this.text}) : id = id ?? uuidString();
  String id;
  List<ChallengeOption> selections;
  ChallengeGoalMode kind;
  int goal;
  String text;

  List<String> get tags => (selections.expand((option) => option.tags).toSet().toList()..sort());
  String get goalText => goalTextFor(kind, goal);

  static String goalTextFor(ChallengeGoalMode kind, int value) {
    final key = kind == ChallengeGoalMode.time ? (value == 1 ? '%@ second' : '%@ seconds') : (value == 1 ? '%@ repetition' : '%@ repetitions');
    return L10n.text(key, ['$value']);
  }

  factory ChallengeMission.fromJson(JsonObject json) => ChallengeMission(
    id: json.string('id'),
    selections: json.list('selections', (value) => ChallengeOption.fromJson(jsonObject(value))),
    kind: ChallengeGoalMode.values.byName(json.string('kind')),
    goal: json.integer('goal'),
    text: json.string('text'),
  );
  JsonObject toJson() => {
    'id': id,
    'selections': [for (final option in selections) option.toJson()],
    'kind': kind.name,
    'goal': goal,
    'text': text,
  };
}

enum ChallengePhase { idle, spinning, active, ready, ended }

class ChallengeSession {
  ChallengeSession({
    required this.definition,
    this.phase = ChallengePhase.idle,
    this.score = 0,
    this.mission,
    this.remaining = 0,
    this.count = 0,
    this.deadline,
    this.ending,
    this.revision = 0,
    this.sourceKind = 'servers',
    List<String>? serverIDs,
    this.folderID,
    this.selectedPost,
    this.spinSpeed = 'normal',
  }) : serverIDs = serverIDs ?? [];

  ChallengeDefinition definition;
  ChallengePhase phase;
  int score;
  ChallengeMission? mission;
  int remaining;
  int count;
  DateTime? deadline;
  ChallengeEnding? ending;
  int revision;
  // Local only. Never part of a challenge backup.
  String sourceKind;
  List<String> serverIDs;
  String? folderID;
  BooruPost? selectedPost;
  String spinSpeed;

  bool get canSearchImages => mission != null && (phase == ChallengePhase.active || phase == ChallengePhase.ready);
  double get progress => score / definition.target;

  ChallengeSession copy() => ChallengeSession.fromJson(toJson());

  // `Date` encodes as seconds since 2001, as Swift's JSONEncoder writes it.
  factory ChallengeSession.fromJson(JsonObject json) => ChallengeSession(
    definition: ChallengeDefinition.fromJson(json.object('definition')),
    phase: ChallengePhase.values.byName(json.string('phase')),
    score: json.integer('score'),
    mission: json.objectOrNull('mission') == null ? null : ChallengeMission.fromJson(json.object('mission')),
    remaining: json.integer('remaining'),
    count: json.integer('count'),
    deadline: json.numberOrNull('deadline') == null ? null : dateFromSwiftReferenceSeconds(json.number('deadline')),
    ending: json.objectOrNull('ending') == null ? null : ChallengeEnding.fromJson(json.object('ending')),
    revision: json.integer('revision'),
    sourceKind: json.stringOrNull('sourceKind') ?? 'servers',
    serverIDs: json.stringsOrNull('serverIDs') ?? [],
    folderID: json.stringOrNull('folderID'),
    selectedPost: json.objectOrNull('selectedPost') == null ? null : BooruPost.fromJson(json.object('selectedPost')),
    spinSpeed: json.stringOrNull('spinSpeed') ?? 'normal',
  );

  JsonObject toJson() =>
      <String, Object?>{
          'definition': definition.toJson(),
          'phase': phase.name,
          'score': score,
          'remaining': remaining,
          'count': count,
          'revision': revision,
          'sourceKind': sourceKind,
          'serverIDs': serverIDs,
          'spinSpeed': spinSpeed,
        }
        ..putIfPresent('mission', mission?.toJson())
        ..putIfPresent('deadline', deadline == null ? null : swiftReferenceSeconds(deadline!))
        ..putIfPresent('ending', ending?.toJson())
        ..putIfPresent('folderID', folderID)
        ..putIfPresent('selectedPost', selectedPost?.toJson());

  @override
  bool operator ==(Object other) => other is ChallengeSession && encodeJsonString(other.toJson()) == encodeJsonString(toJson());
  @override
  int get hashCode => encodeJsonString(toJson()).hashCode;
}

/// The only randomness and wall clock dependencies are explicit inputs.
class ChallengeEngine {
  ChallengeEngine({int Function(int start, int end)? random}) : random = random ?? ((start, end) => start + math.Random().nextInt(end - start));

  /// A value in `start ..< end`.
  final int Function(int start, int end) random;

  T _choose<T>(List<T> values, int Function(T value) weight) {
    final total = values.fold<int>(0, (sum, value) => sum + weight(value));
    var ticket = random(0, total);
    for (final value in values) {
      ticket -= weight(value);
      if (ticket < 0) return value;
    }
    return values.last;
  }

  int _number(ChallengeRange range) => range.minimum + random(0, (range.maximum - range.minimum) ~/ range.step + 1) * range.step;

  void draw(ChallengeSession session) {
    if (session.phase != ChallengePhase.idle) return;
    session.definition.validate();
    final definition = session.definition;
    final choices = [
      for (final group in [...definition.reels, ...definition.groups]) _choose(group.eligible, (option) => option.weight),
    ];
    final rule = definition.goal;
    final kind = rule.mode == ChallengeGoalMode.mixed
        ? (random(0, rule.timeWeight + rule.countWeight) < rule.timeWeight ? ChallengeGoalMode.time : ChallengeGoalMode.count)
        : rule.mode;
    final goal = _number(kind == ChallengeGoalMode.time ? rule.time : rule.count);
    final variables = {'reel1': choices[0].text, 'reel2': choices[1].text, 'goal': ChallengeMission.goalTextFor(kind, goal)};
    for (final (index, option) in choices.skip(2).indexed) {
      variables['extra${index + 1}'] = option.text;
    }
    // Replace tokens in the template once: option text is never interpreted as a template.
    final text = definition.template.replaceAllMapped(RegExp(r'\{([^{}]*)\}'), (match) => variables[match[1]] ?? '');
    session
      ..mission = ChallengeMission(selections: choices, kind: kind, goal: goal, text: text)
      ..phase = ChallengePhase.spinning
      ..remaining = kind == ChallengeGoalMode.time ? goal : 0
      ..count = 0
      ..deadline = null
      ..selectedPost = null;
  }

  void reconcile(ChallengeSession session, DateTime now, {bool restore = false}) {
    if (restore && session.phase == ChallengePhase.spinning) session.phase = ChallengePhase.active;
    final mission = session.mission;
    if (session.phase != ChallengePhase.active || mission == null) return;
    if (mission.kind == ChallengeGoalMode.time) {
      final deadline = session.deadline;
      if (deadline != null) session.remaining = math.max(0, (deadline.difference(now).inMicroseconds / 1e6).ceil());
      if (session.remaining == 0) {
        session
          ..deadline = null
          ..phase = ChallengePhase.ready;
      }
    } else if (session.count >= mission.goal) {
      session.phase = ChallengePhase.ready;
    }
  }

  void complete(ChallengeSession session, DateTime now) {
    reconcile(session, now);
    if (session.phase != ChallengePhase.ready) return;
    final definition = session.definition;
    final band = definition.bands.firstWhere((band) => session.score <= band.through);
    final points = math.max(1, (random(band.minimum, band.maximum + 1) * definition.multiplier).round());
    session
      ..score = math.min(definition.target, session.score + points)
      ..deadline = null
      ..remaining = 0
      ..count = 0
      ..mission = null
      ..selectedPost = null;
    if (session.score == definition.target) {
      session
        ..ending =
            definition.endings.where((ending) => ending.id == definition.fixedEndingID).firstOrNull ??
            _choose<ChallengeEnding>(definition.endings, (ending) => ending.weight)
        ..phase = ChallengePhase.ended;
    } else {
      session.phase = ChallengePhase.idle;
    }
  }
}

/// Sessions are stored beside their challenges in the image library.
extension ChallengeStoreSessions on ChallengeStore {
  ChallengeSession session(ChallengeDefinition game) => database.read((db) {
    final data = db.value<Uint8List>('SELECT payload FROM challenge_sessions WHERE id = ?', [game.id]);
    if (data == null) return ChallengeSession(definition: game);
    final session = ChallengeSession.fromJson(decodeJsonObject(data));
    session.definition.validate();
    return session;
  });

  bool hasSession(String id) {
    try {
      return database.read((db) => db.exists('SELECT EXISTS(SELECT 1 FROM challenge_sessions WHERE id = ?)', [id]));
    } on Object {
      return false;
    }
  }

  /// Optimistic revision prevents another screen from awarding the same mission twice.
  ChallengeSession commit(ChallengeSession session, {required int expected}) => database.write((SqlDatabase db) {
    if (!db.exists('SELECT EXISTS(SELECT 1 FROM challenges WHERE id = ?)', [session.definition.id])) throw const ChallengeError.stale();
    final existing = db.value<Uint8List>('SELECT payload FROM challenge_sessions WHERE id = ?', [session.definition.id]);
    final revision = existing == null ? 0 : ChallengeSession.fromJson(decodeJsonObject(existing)).revision;
    if (revision != expected) throw const ChallengeError.stale();
    final next = session.copy()..revision = expected + 1;
    db.execute('INSERT INTO challenge_sessions (id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload', [
      next.definition.id,
      encodeSwiftJson(next.toJson()),
    ]);
    return next;
  });
}

/// `ChallengeSessionController`: one challenge in play, persisted after every change.
class ChallengeSessionController extends ChangeNotifier {
  ChallengeSessionController({required ChallengeDefinition game, this.store, ChallengeEngine? engine, DateTime Function()? now})
    : engine = engine ?? ChallengeEngine(),
      now = now ?? DateTime.now,
      _latestDefinition = game {
    game.validate();
    session = store?.session(game) ?? ChallengeSession(definition: game);
    final restored = session.copy();
    this.engine.reconcile(restored, this.now(), restore: true);
    if (restored != session) _persist(restored);
  }

  final ChallengeStore? store;
  final ChallengeEngine engine;
  final DateTime Function() now;
  final ChallengeDefinition _latestDefinition;
  final id = uuidString();
  late ChallengeSession session;
  String? error;
  int stoppedReels = 0;
  bool unavailable = false;

  void _persist(ChallengeSession next) => session = store?.commit(next, expected: session.revision) ?? next;

  void _change(void Function(ChallengeSession value) action) {
    if (unavailable) return;
    try {
      final next = session.copy();
      action(next);
      if (next != session) _persist(next);
    } on ChallengeError catch (failure) {
      if (failure.kind == 'stale') unavailable = true;
      error = failure.errorDescription;
    } on Object catch (failure) {
      error = '$failure';
    }
    notifyListeners();
  }

  void draw() {
    if (session.phase != ChallengePhase.idle) return;
    stoppedReels = 0;
    _change(engine.draw);
  }

  void stopReel(int count) {
    stoppedReels = math.min(3, count);
    notifyListeners();
  }

  void reveal() {
    stoppedReels = 3;
    _change((value) {
      if (value.phase == ChallengePhase.spinning) value.phase = ChallengePhase.active;
    });
  }

  /// Running seconds are derived in the UI; only phase transitions need disk writes.
  void tick() {
    final deadline = session.deadline;
    if (session.phase != ChallengePhase.active || deadline == null || deadline.isAfter(now())) return;
    _change((value) => engine.reconcile(value, now()));
  }

  int seconds(DateTime date) {
    final deadline = session.deadline;
    return deadline == null ? session.remaining : math.max(0, (deadline.difference(date).inMicroseconds / 1e6).ceil());
  }

  void toggleTimer() => _change((value) {
    engine.reconcile(value, now());
    if (value.phase != ChallengePhase.active || value.mission?.kind != ChallengeGoalMode.time) return;
    value.deadline = value.deadline != null ? null : now().add(Duration(seconds: value.remaining));
  });

  void resetTimer() => _change((value) {
    final mission = value.mission;
    if (!const {ChallengePhase.active, ChallengePhase.ready}.contains(value.phase) || mission == null || mission.kind != ChallengeGoalMode.time) return;
    value
      ..remaining = mission.goal
      ..deadline = null
      ..phase = ChallengePhase.active;
  });

  void adjust(int amount) => _change((value) {
    final mission = value.mission;
    if (!const {ChallengePhase.active, ChallengePhase.ready}.contains(value.phase) || mission == null || mission.kind != ChallengeGoalMode.count) return;
    value
      ..count = math.min(mission.goal, math.max(0, value.count + amount))
      ..phase = value.count == mission.goal ? ChallengePhase.ready : ChallengePhase.active;
  });

  void complete() => _change((value) => engine.complete(value, now()));

  void skip() => _change((value) {
    if (!const {ChallengePhase.active, ChallengePhase.ready}.contains(value.phase)) return;
    value
      ..phase = ChallengePhase.idle
      ..mission = null
      ..deadline = null
      ..selectedPost = null
      ..count = 0
      ..remaining = 0;
  });

  void restart() => _change((value) {
    final current = store?.definitions().where((game) => game.id == _latestDefinition.id).firstOrNull ?? _latestDefinition;
    final next = ChallengeSession(
      definition: current,
      revision: value.revision,
      sourceKind: value.sourceKind,
      serverIDs: value.serverIDs,
      folderID: value.folderID,
      spinSpeed: value.spinSpeed,
    );
    value
      ..definition = next.definition
      ..phase = next.phase
      ..score = 0
      ..mission = null
      ..remaining = 0
      ..count = 0
      ..deadline = null
      ..ending = null
      ..selectedPost = null;
  });

  void select(BooruPost? post) => _change((value) => value.selectedPost = post);

  void source({required String kind, required List<String> servers, String? folder}) => _change((value) {
    value
      ..sourceKind = kind
      ..serverIDs = servers
      ..folderID = folder
      ..selectedPost = null;
  });

  void speed(String value) => _change((session) => session.spinSpeed = value);
}
