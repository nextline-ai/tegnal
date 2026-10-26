import 'dart:convert';
import 'dart:math';

import '../data/library_store.dart';
import 'content.dart';

enum ChallengePhase { idle, spinning, active, ready, ended }

enum ChallengeGoalKind { time, count, mixed }

/// Native challenge definitions remain native-shaped JSON, including fields an
/// older editor does not understand. Sessions and reference sources are local.
class ChallengeDefinition {
  ChallengeDefinition.fromJson(Map<String, dynamic> value)
    : _json = _clone(value) {
    validate();
  }
  final Map<String, dynamic> _json;
  static const exampleId = 'builtin.croquis.v1';
  String get id => _json['id'] as String;
  String get title => _json['title'] as String;
  String get detail => _json['detail'] as String? ?? '';
  String get template => _json['template'] as String;
  int get target => _int(_json['target']);
  double get multiplier => (_json['multiplier'] as num).toDouble();
  Map<String, dynamic> get goal => _map(_json['goal']);
  List<Map<String, dynamic>> get reels => _maps(_json['reels']);
  List<Map<String, dynamic>> get groups => _maps(_json['groups'] ?? []);
  List<Map<String, dynamic>> get bands => _maps(_json['bands']);
  List<Map<String, dynamic>> get endings => _maps(_json['endings']);
  List<Map<String, dynamic>> get helpPages => _maps(_json['helpPages'] ?? []);
  Map<String, dynamic> toJson() => _clone(_json);
  ChallengeDefinition withChanges(Map<String, dynamic> changes) =>
      ChallengeDefinition.fromJson({..._json, ...changes});

  void validate() {
    _require(
      _text(_json['id'], 128) &&
          _text(_json['title'], 200) &&
          (_json['detail'] == null ||
              _json['detail'] is String &&
                  (_json['detail'] as String).length <= 4000),
      'Challenge Details',
    );
    final reels = _strictMaps(_json['reels'], 'Draw Options');
    final groups = _strictMaps(_json['groups'] ?? [], 'Draw Options');
    _require(reels.length == 2 && groups.length <= 12, 'Draw Options');
    final help = _strictMaps(_json['helpPages'] ?? [], 'Help Tabs');
    _require(help.length <= 12 && _uniqueIds(help), 'Help Tabs');
    for (final page in help) {
      _require(
        page['id'] != 'overview' &&
            _text(page['id'], 128) &&
            _text(page['title'], 200) &&
            _text(page['body'], 16000),
        'Help Tabs',
      );
    }
    final all = [...reels, ...groups];
    _require(_uniqueIds(all), 'Draw Options');
    for (final group in all) {
      _require(
        _text(group['id'], 128) &&
            _text(group['title'], 200) &&
            (group['filter'] ?? '') is String &&
            (group['filter'] as String? ?? '').length <= 200,
        'Draw Options',
      );
      final options = _strictMaps(group['options'], 'Draw Options');
      _require(
        options.isNotEmpty &&
            options.length <= 1000 &&
            _uniqueIds(options) &&
            eligible(group).isNotEmpty,
        group['title'] as String,
      );
      for (final option in options) {
        _require(
          _text(option['id'], 128) &&
              _text(option['text'], 4000) &&
              (option['group'] ?? '') is String &&
              (option['group'] as String? ?? '').length <= 200 &&
              option['enabled'] is bool &&
              _bounded(option['weight'], 1, 10000),
          group['title'] as String,
        );
        final tags = option['tags'];
        _require(
          tags is List &&
              tags.length <= 20 &&
              tags.every(
                (tag) =>
                    _text(tag, 128) &&
                    !RegExp(r'[\s:{}]').hasMatch(tag as String) &&
                    !tag.startsWith('-') &&
                    !tag.startsWith('~'),
              ),
          'Search Tags',
        );
      }
    }
    final goal = _map(_json['goal']);
    _require(
      ChallengeGoalKind.values.any((kind) => kind.name == goal['mode']) &&
          _validRange(goal['time'], 86400) &&
          _validRange(goal['count'], 10000),
      'Goal Range',
    );
    _require(
      _bounded(goal['timeWeight'], 1, 10000) &&
          _bounded(goal['countWeight'], 1, 10000),
      'Goal Probability',
    );
    _require(
      _bounded(_json['target'], 1, 100000) &&
          [.5, 1, 1.5, 2].contains(_json['multiplier']),
      'Scoring',
    );
    final bands = _strictMaps(_json['bands'], 'Scoring');
    _require(
      bands.isNotEmpty && bands.length <= 100 && _uniqueIds(bands),
      'Scoring',
    );
    var previous = -1;
    for (final band in bands) {
      _require(
        _text(band['id'], 128) &&
            _bounded(band['through'], 0, 100000) &&
            _int(band['through']) > previous &&
            _bounded(band['minimum'], 1, 100000) &&
            _bounded(band['maximum'], _int(band['minimum']), 100000),
        'Scoring',
      );
      previous = _int(band['through']);
    }
    _require(previous >= target - 1, 'Scoring');
    final endings = _strictMaps(_json['endings'], 'Endings');
    _require(
      endings.isNotEmpty && endings.length <= 100 && _uniqueIds(endings),
      'Endings',
    );
    for (final ending in endings) {
      _require(
        _text(ending['id'], 128) &&
            _text(ending['title'], 200) &&
            ending['detail'] is String &&
            (ending['detail'] as String).length <= 4000 &&
            ending['badge'] is String &&
            (ending['badge'] as String).length <= 40 &&
            [
              'purple',
              'pink',
              'green',
              'orange',
              'blue',
            ].contains(ending['color']) &&
            _bounded(ending['weight'], 1, 10000),
        'Endings',
      );
    }
    _require(
      _json['fixedEndingID'] == null ||
          endings.any((ending) => ending['id'] == _json['fixedEndingID']),
      'Endings',
    );
    _require(_text(_json['template'], 4000), 'Mission Text');
    final variables = {
      'reel1',
      'reel2',
      'goal',
      for (var i = 1; i <= groups.length; i++) 'extra$i',
    };
    final pattern = RegExp(r'\{([^{}]*)\}');
    _require(
      pattern
              .allMatches(template)
              .every((match) => variables.contains(match.group(1))) &&
          !template.replaceAll(pattern, '').contains(RegExp(r'[{}]')),
      'Mission Variables',
    );
  }

  static List<Map<String, dynamic>> eligible(Map<String, dynamic> group) =>
      _maps(group['options'])
          .where(
            (option) =>
                option['enabled'] == true &&
                ((group['filter'] ?? '') == '' ||
                    option['group'] == group['filter']),
          )
          .toList();

  factory ChallengeDefinition.croquis({String id = exampleId}) {
    Map<String, dynamic> option(
      String id,
      String text, [
      List<String> tags = const [],
    ]) => {
      'id': id,
      'text': text,
      'tags': tags,
      'group': '',
      'enabled': true,
      'weight': 1,
    };
    return ChallengeDefinition.fromJson({
      'id': id,
      'title': 'Croquis Challenge',
      'detail': 'Draw a subject, a drawing method, and a time limit. Choose a reference image, then start the timer when you are ready. Sketch until time is up and tap Complete Mission to earn points. Reach 100 points to finish your session. You can pause or skip a mission at any time.',
      'reels': [
        {
          'id': 'subject',
          'title': 'Subject',
          'filter': '',
          'options': [
            option('person', 'Person', ['solo']),
            option('animal', 'Animal', ['animal']),
            option('scenery', 'Scenery', ['scenery']),
            option('object', 'Object', ['still_life']),
          ],
        },
        {
          'id': 'method',
          'title': 'Drawing Method',
          'filter': '',
          'options': [
            option('outline', 'Outline'),
            option('shapes', 'Large Shapes'),
            option('light', 'Light and Shadow'),
          ],
        },
      ],
      'groups': <dynamic>[],
      'template': 'Sketch {reel1} using {reel2}. Goal: {goal}.',
      'goal': {
        'mode': 'time',
        'time': {'minimum': 30, 'maximum': 120, 'step': 30},
        'count': {'minimum': 1, 'maximum': 3, 'step': 1},
        'timeWeight': 50,
        'countWeight': 50,
      },
      'target': 100,
      'multiplier': 1.0,
      'bands': [
        {'id': 'early', 'through': 40, 'minimum': 12, 'maximum': 20},
        {'id': 'middle', 'through': 80, 'minimum': 6, 'maximum': 11},
        {'id': 'late', 'through': 100, 'minimum': 1, 'maximum': 5},
      ],
      'endings': [
        {
          'id': 'practice',
          'title': 'Great Practice',
          'detail': 'You completed your sketch session. Take a look at your progress.',
          'badge': '★',
          'color': 'purple',
          'weight': 10,
        },
        {
          'id': 'perspective',
          'title': 'Fresh Perspective',
          'detail': 'Every sketch helps you see new shapes.',
          'badge': '✦',
          'color': 'purple',
          'weight': 45,
        },
        {
          'id': 'momentum',
          'title': 'Creative Momentum',
          'detail': 'Keep your sketches and enjoy what you learned.',
          'badge': '✧',
          'color': 'purple',
          'weight': 45,
        },
      ],
    });
  }
}

class ChallengeMission {
  ChallengeMission({
    required this.id,
    required this.selections,
    required this.kind,
    required this.goal,
    required this.text,
  });
  final String id;
  final List<Map<String, dynamic>> selections;
  final ChallengeGoalKind kind;
  final int goal;
  final String text;
  List<String> get tags => {
    for (final selection in selections)
      ...((selection['tags'] as List?)?.cast<String>() ?? <String>[]),
  }.toList()..sort();
  Map<String, dynamic> toJson() => {
    'id': id,
    'selections': selections,
    'kind': kind.name,
    'goal': goal,
    'text': text,
  };
  factory ChallengeMission.fromJson(Map<String, dynamic> value) =>
      ChallengeMission(
        id: value['id'] as String,
        selections: _maps(value['selections']),
        kind: ChallengeGoalKind.values.byName(value['kind'] as String),
        goal: _int(value['goal']),
        text: value['text'] as String,
      );
  static String goalText(ChallengeGoalKind kind, int amount) =>
      kind == ChallengeGoalKind.time
      ? '$amount ${amount == 1 ? 'second' : 'seconds'}'
      : '$amount ${amount == 1 ? 'repetition' : 'repetitions'}';
}

class ChallengeSession {
  ChallengeSession(this.definition);
  ChallengeDefinition definition;
  ChallengePhase phase = ChallengePhase.idle;
  int score = 0;
  ChallengeMission? mission;
  int remaining = 0;
  int count = 0;
  DateTime? deadline;
  Map<String, dynamic>? ending;
  int revision = 0;
  String sourceKind = 'servers';
  List<String> serverIds = [];
  String? folderId;
  ContentItem? selectedItem;
  String spinSpeed = 'normal';
  Map<String, dynamic> toJson() => {
    'definition': definition.toJson(),
    'phase': phase.name,
    'score': score,
    'mission': mission?.toJson(),
    'remaining': remaining,
    'count': count,
    'deadline': deadline?.toUtc().toIso8601String(),
    'ending': ending,
    'revision': revision,
    'sourceKind': sourceKind,
    'serverIDs': serverIds,
    'folderID': folderId,
    'selectedItem': selectedItem?.toJson(),
    'spinSpeed': spinSpeed,
  };
  factory ChallengeSession.fromJson(Map<String, dynamic> value) {
    final session =
        ChallengeSession(
            ChallengeDefinition.fromJson(_map(value['definition'])),
          )
          ..phase = ChallengePhase.values.byName(value['phase'] as String)
          ..score = _int(value['score'])
          ..remaining = _int(value['remaining'])
          ..count = _int(value['count'])
          ..revision = _int(value['revision'])
          ..deadline = value['deadline'] is String
              ? DateTime.parse(value['deadline'] as String)
              : null
          ..mission = value['mission'] is Map
              ? ChallengeMission.fromJson(_map(value['mission']))
              : null
          ..ending = value['ending'] is Map ? _map(value['ending']) : null
          ..sourceKind = value['sourceKind'] as String? ?? 'servers'
          ..serverIds = (value['serverIDs'] as List? ?? []).cast<String>()
          ..folderId = value['folderID'] as String?
          ..selectedItem = value['selectedItem'] is Map
              ? ContentItem.fromJson(_map(value['selectedItem']))
              : null
          ..spinSpeed = value['spinSpeed'] as String? ?? 'normal';
    _require(
      session.score >= 0 &&
          session.score <= session.definition.target &&
          session.remaining >= 0 &&
          session.count >= 0 &&
          session.revision >= 0 &&
          (![
                ChallengePhase.active,
                ChallengePhase.ready,
                ChallengePhase.spinning,
              ].contains(session.phase) ||
              session.mission != null &&
                  session.mission!.goal > 0 &&
                  session.mission!.kind != ChallengeGoalKind.mixed),
      'Saved Session',
    );
    return session;
  }
}

/// Randomness and clocks are passed explicitly so scoring and timers are testable.
class ChallengeEngine {
  ChallengeEngine({int Function(int maximum)? random})
    : _random = random ?? Random.secure().nextInt;
  final int Function(int maximum) _random;
  Map<String, dynamic> _choose(List<Map<String, dynamic>> values) {
    var ticket = _random(
      values.fold<int>(0, (total, value) => total + _int(value['weight'])),
    );
    for (final value in values) {
      ticket -= _int(value['weight']);
      if (ticket < 0) return value;
    }
    return values.last;
  }

  int _number(Map<String, dynamic> range) =>
      _int(range['minimum']) +
      _random(
            (_int(range['maximum']) - _int(range['minimum'])) ~/
                    _int(range['step']) +
                1,
          ) *
          _int(range['step']);
  void draw(ChallengeSession session) {
    if (session.phase != ChallengePhase.idle) return;
    final definition = session.definition;
    definition.validate();
    final choices = [
      ...definition.reels,
      ...definition.groups,
    ].map((group) => _choose(ChallengeDefinition.eligible(group))).toList();
    final rule = definition.goal;
    var kind = ChallengeGoalKind.values.byName(rule['mode'] as String);
    if (kind == ChallengeGoalKind.mixed) {
      kind =
          _random(_int(rule['timeWeight']) + _int(rule['countWeight'])) <
              _int(rule['timeWeight'])
          ? ChallengeGoalKind.time
          : ChallengeGoalKind.count;
    }
    final goal = _number(_map(rule[kind.name]));
    final variables = {
      'reel1': choices[0]['text'] as String,
      'reel2': choices[1]['text'] as String,
      'goal': ChallengeMission.goalText(kind, goal),
      for (var index = 2; index < choices.length; index++)
        'extra${index - 1}': choices[index]['text'] as String,
    };
    final text = definition.template.replaceAllMapped(
      RegExp(r'\{([^{}]*)\}'),
      (match) => variables[match.group(1)] ?? '',
    );
    session
      ..mission = ChallengeMission(
        id: newChallengeId(),
        selections: choices,
        kind: kind,
        goal: goal,
        text: text,
      )
      ..phase = ChallengePhase.spinning
      ..remaining = kind == ChallengeGoalKind.time ? goal : 0
      ..count = 0
      ..deadline = null
      ..selectedItem = null;
  }

  void reveal(ChallengeSession session) {
    if (session.phase == ChallengePhase.spinning) {
      session.phase = ChallengePhase.active;
    }
  }

  void reconcile(
    ChallengeSession session,
    DateTime now, {
    bool restore = false,
  }) {
    if (restore) reveal(session);
    final mission = session.mission;
    if (session.phase != ChallengePhase.active || mission == null) return;
    if (mission.kind == ChallengeGoalKind.time) {
      if (session.deadline != null) session.remaining = seconds(session, now);
      if (session.remaining == 0) {
        session
          ..deadline = null
          ..phase = ChallengePhase.ready;
      }
    } else if (session.count >= mission.goal) {
      session.phase = ChallengePhase.ready;
    }
  }

  int seconds(ChallengeSession session, DateTime now) =>
      session.deadline == null
      ? session.remaining
      : max(
          0,
          (session.deadline!.difference(now).inMicroseconds /
                  Duration.microsecondsPerSecond)
              .ceil(),
        );
  void toggleTimer(ChallengeSession session, DateTime now) {
    reconcile(session, now);
    if (session.phase != ChallengePhase.active ||
        session.mission?.kind != ChallengeGoalKind.time) {
      return;
    }
    session.deadline = session.deadline != null
        ? null
        : now.add(Duration(seconds: session.remaining));
  }

  void resetTimer(ChallengeSession session) {
    if (![
          ChallengePhase.active,
          ChallengePhase.ready,
        ].contains(session.phase) ||
        session.mission?.kind != ChallengeGoalKind.time) {
      return;
    }
    session
      ..remaining = session.mission!.goal
      ..deadline = null
      ..phase = ChallengePhase.active;
  }

  void adjust(ChallengeSession session, int amount) {
    if (![
          ChallengePhase.active,
          ChallengePhase.ready,
        ].contains(session.phase) ||
        session.mission?.kind != ChallengeGoalKind.count) {
      return;
    }
    session.count = (session.count + amount).clamp(0, session.mission!.goal);
    session.phase = session.count == session.mission!.goal
        ? ChallengePhase.ready
        : ChallengePhase.active;
  }

  void complete(ChallengeSession session, DateTime now) {
    reconcile(session, now);
    if (session.phase != ChallengePhase.ready) return;
    final definition = session.definition;
    final band = definition.bands.firstWhere(
      (value) => session.score <= _int(value['through']),
    );
    final points = max(
      1,
      ((_int(band['minimum']) +
                  _random(_int(band['maximum']) - _int(band['minimum']) + 1)) *
              definition.multiplier)
          .round(),
    );
    session
      ..score = min(definition.target, session.score + points)
      ..deadline = null
      ..remaining = 0
      ..count = 0
      ..mission = null
      ..selectedItem = null;
    if (session.score == definition.target) {
      session.ending =
          definition.endings
              .where(
                (value) => value['id'] == definition._json['fixedEndingID'],
              )
              .firstOrNull ??
          _choose(definition.endings);
      session.phase = ChallengePhase.ended;
    } else {
      session.phase = ChallengePhase.idle;
    }
  }

  void skip(ChallengeSession session) {
    if (![
      ChallengePhase.active,
      ChallengePhase.ready,
    ].contains(session.phase)) {
      return;
    }
    session
      ..phase = ChallengePhase.idle
      ..mission = null
      ..deadline = null
      ..selectedItem = null
      ..count = 0
      ..remaining = 0;
  }
}

class ChallengeRepository {
  ChallengeRepository(this.store);
  final LibraryStore store;
  static const maximumBytes = 10 * 1024 * 1024;
  List<ChallengeDefinition> definitions() =>
      _maps(store.portable('backup.challenges')?['games'] ?? [])
          .map(ChallengeDefinition.fromJson)
          .toList();
  ChallengeDefinition example() {
    final existing = definitions()
        .where((value) => value.id == ChallengeDefinition.exampleId)
        .firstOrNull;
    if (existing != null) return existing;
    final value = ChallengeDefinition.croquis();
    save(value);
    return value;
  }

  void save(ChallengeDefinition definition) {
    definition.validate();
    store.transaction(() {
      final games = definitions();
      final index = games.indexWhere((value) => value.id == definition.id);
      if (index < 0) {
        games.add(definition);
      } else {
        games[index] = definition;
      }
      _write(games);
    });
  }

  void delete(String id) => store.transaction(() {
    _write(definitions().where((value) => value.id != id).toList());
    store.setSetting('challenge.session.$id', null);
  });
  void _write(List<ChallengeDefinition> definitions) {
    _require(definitions.length <= 200, 'Challenges');
    final object = {
      ...?store.portable('backup.challenges'),
      'format': 'tegnal-challenges',
      'schemaVersion': 1,
      'games': definitions.map((value) => value.toJson()).toList(),
    };
    _require(
      utf8.encode(jsonEncode(object)).length <= maximumBytes,
      'Challenge Backup Size',
    );
    store.setPortable('backup.challenges', object);
  }

  bool hasSession(String id) => store.setting('challenge.session.$id') is Map;
  ChallengeSession session(ChallengeDefinition definition) {
    final value = store.setting('challenge.session.${definition.id}');
    return value is Map
        ? ChallengeSession.fromJson(_map(value))
        : ChallengeSession(definition);
  }

  ChallengeSession commit(ChallengeSession session, {required int expected}) =>
      store.transaction(() {
        _require(
          definitions().any(
            (definition) => definition.id == session.definition.id,
          ),
          'Challenge no longer exists',
        );
        final previous = store.setting(
          'challenge.session.${session.definition.id}',
        );
        final revision = previous is Map ? _int(previous['revision']) : 0;
        if (revision != expected) {
          throw const ContentException(
            'The challenge changed in another view. Reopen it to continue.',
          );
        }
        final next = ChallengeSession.fromJson(session.toJson())
          ..revision = expected + 1;
        store.setSetting(
          'challenge.session.${session.definition.id}',
          next.toJson(),
        );
        return next;
      });
  String exportJson({ChallengeDefinition? definition}) {
    final object = {
      'format': 'tegnal-challenges',
      'schemaVersion': 1,
      'games': (definition == null ? definitions() : [definition])
          .map((value) => value.toJson())
          .toList(),
    };
    final text = const JsonEncoder.withIndent('  ').convert(object);
    _require(utf8.encode(text).length <= maximumBytes, 'Challenge Backup Size');
    return text;
  }

  void importJson(String text, {bool replace = false}) {
    _require(utf8.encode(text).length <= maximumBytes, 'Challenge Backup Size');
    final root = _map(jsonDecode(text));
    _require(
      [
            'tegnal-challenges',
            'number-memo-challenges',
          ].contains(root['format']) &&
          root['schemaVersion'] == 1,
      'Challenge Backup Format',
    );
    final raw = _strictMaps(root['games'], 'Challenges');
    _require(raw.length <= 200 && _uniqueIds(raw), 'Challenges');
    final incoming = raw.map(ChallengeDefinition.fromJson).toList();
    store.transaction(() {
      final previous = definitions();
      final ids = previous.map((value) => value.id).toSet();
      final games = {for (final value in previous) value.id: value};
      for (var value in incoming) {
        if (!replace && ids.contains(value.id)) {
          value = value.withChanges({
            'id': newChallengeId(),
            'title':
                '${value.title.substring(0, min(195, value.title.length))} Copy',
          });
        }
        games[value.id] = value;
      }
      store.setPortable('backup.challenges', {
        ...?store.portable('backup.challenges'),
        ...root,
        'games': games.values.map((value) => value.toJson()).toList(),
      });
      _write(games.values.toList());
    });
  }
}

String newChallengeId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(0x7fffffff)}';
Map<String, dynamic> _clone(Map<String, dynamic> value) =>
    _map(jsonDecode(jsonEncode(value)));
Map<String, dynamic> _map(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<Map<String, dynamic>> _maps(dynamic value) =>
    value is List ? value.whereType<Map>().map(_map).toList() : [];
List<Map<String, dynamic>> _strictMaps(dynamic value, String field) {
  _require(value is List && value.every((row) => row is Map), field);
  return _maps(value);
}

int _int(dynamic value) => value is num ? value.toInt() : 0;
bool _text(dynamic value, int maximum) =>
    value is String && value.trim().isNotEmpty && value.length <= maximum;
bool _bounded(dynamic value, int minimum, int maximum) =>
    value is int && value >= minimum && value <= maximum;
bool _uniqueIds(List<Map<String, dynamic>> values) =>
    values.map((value) => value['id']).toSet().length == values.length;
bool _validRange(dynamic value, int limit) {
  final range = _map(value);
  return _bounded(range['minimum'], 1, limit) &&
      _bounded(range['maximum'], _int(range['minimum']), limit) &&
      _bounded(range['step'], 1, limit) &&
      (_int(range['maximum']) - _int(range['minimum'])) % _int(range['step']) ==
          0;
}

void _require(bool condition, String field) {
  if (!condition) throw ContentException('Check this field: $field');
}
