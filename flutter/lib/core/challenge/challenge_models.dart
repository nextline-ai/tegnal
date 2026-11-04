import 'dart:typed_data';

import 'package:characters/characters.dart';

import '../support/l10n.dart';
import '../support/swift_json.dart';

class ChallengeOption {
  ChallengeOption({String? id, required this.text, this.tags = const [], this.group = '', this.enabled = true, this.weight = 1}) : id = id ?? uuidString();
  String id;
  String text;
  List<String> tags;
  String group;
  bool enabled;
  int weight;

  factory ChallengeOption.fromJson(JsonObject json) => ChallengeOption(
    id: json.string('id'),
    text: json.string('text'),
    tags: json.strings('tags'),
    group: json.string('group'),
    enabled: json.boolean('enabled'),
    weight: json.integer('weight'),
  );
  JsonObject toJson() => {'id': id, 'text': text, 'tags': tags, 'group': group, 'enabled': enabled, 'weight': weight};
}

class ChallengeGroup {
  ChallengeGroup({String? id, required this.title, required this.options, this.filter = ''}) : id = id ?? uuidString();
  String id;
  String title;
  List<ChallengeOption> options;
  String filter;

  List<ChallengeOption> get eligible => options.where((option) => option.enabled && (filter.isEmpty || option.group == filter)).toList();

  factory ChallengeGroup.fromJson(JsonObject json) => ChallengeGroup(
    id: json.string('id'),
    title: json.string('title'),
    options: json.list('options', (value) => ChallengeOption.fromJson(jsonObject(value))),
    filter: json.string('filter'),
  );
  JsonObject toJson() => {
    'id': id,
    'title': title,
    'options': [for (final option in options) option.toJson()],
    'filter': filter,
  };
}

class ChallengeRange {
  const ChallengeRange({required this.minimum, required this.maximum, this.step = 1});
  final int minimum;
  final int maximum;
  final int step;

  bool validate(int limit) => minimum > 0 && maximum >= minimum && maximum <= limit && step > 0 && step <= limit && (maximum - minimum) % step == 0;

  factory ChallengeRange.fromJson(JsonObject json) =>
      ChallengeRange(minimum: json.integer('minimum'), maximum: json.integer('maximum'), step: json.integer('step'));
  JsonObject toJson() => {'minimum': minimum, 'maximum': maximum, 'step': step};
}

enum ChallengeGoalMode { time, count, mixed }

class ChallengeGoalRule {
  ChallengeGoalRule({
    this.mode = ChallengeGoalMode.time,
    this.time = const ChallengeRange(minimum: 30, maximum: 120, step: 30),
    this.count = const ChallengeRange(minimum: 1, maximum: 3),
    this.timeWeight = 50,
    this.countWeight = 50,
  });
  ChallengeGoalMode mode;
  ChallengeRange time;
  ChallengeRange count;
  int timeWeight;
  int countWeight;

  factory ChallengeGoalRule.fromJson(JsonObject json) => ChallengeGoalRule(
    mode: ChallengeGoalMode.values.firstWhere((mode) => mode.name == json.string('mode'), orElse: () => throw SwiftJsonError('Unknown goal mode')),
    time: ChallengeRange.fromJson(json.object('time')),
    count: ChallengeRange.fromJson(json.object('count')),
    timeWeight: json.integer('timeWeight'),
    countWeight: json.integer('countWeight'),
  );
  JsonObject toJson() => {'mode': mode.name, 'time': time.toJson(), 'count': count.toJson(), 'timeWeight': timeWeight, 'countWeight': countWeight};
}

class ChallengeScoreBand {
  ChallengeScoreBand({String? id, required this.through, required this.minimum, required this.maximum}) : id = id ?? uuidString();
  String id;
  int through;
  int minimum;
  int maximum;

  factory ChallengeScoreBand.fromJson(JsonObject json) =>
      ChallengeScoreBand(id: json.string('id'), through: json.integer('through'), minimum: json.integer('minimum'), maximum: json.integer('maximum'));
  JsonObject toJson() => {'id': id, 'through': through, 'minimum': minimum, 'maximum': maximum};
}

class ChallengeEnding {
  ChallengeEnding({String? id, required this.title, required this.detail, required this.badge, this.color = 'purple', this.weight = 1})
    : id = id ?? uuidString();
  String id;
  String title;
  String detail;
  String badge;
  String color;
  int weight;
  static const colors = ['purple', 'pink', 'green', 'orange', 'blue'];

  factory ChallengeEnding.fromJson(JsonObject json) => ChallengeEnding(
    id: json.string('id'),
    title: json.string('title'),
    detail: json.string('detail'),
    badge: json.string('badge'),
    color: json.string('color'),
    weight: json.integer('weight'),
  );
  JsonObject toJson() => {'id': id, 'title': title, 'detail': detail, 'badge': badge, 'color': color, 'weight': weight};
}

class ChallengeHelpPage {
  ChallengeHelpPage({String? id, required this.title, required this.body}) : id = id ?? uuidString();
  String id;
  String title;
  String body;

  factory ChallengeHelpPage.fromJson(JsonObject json) => ChallengeHelpPage(id: json.string('id'), title: json.string('title'), body: json.string('body'));
  JsonObject toJson() => {'id': id, 'title': title, 'body': body};
}

class ChallengeError implements Exception {
  const ChallengeError.invalid(this.field) : kind = 'invalid';
  const ChallengeError.unsupported() : kind = 'unsupported', field = null;
  const ChallengeError.stale() : kind = 'stale', field = null;
  final String kind;
  final String? field;

  String get errorDescription => switch (kind) {
    'invalid' => L10n.text('Check this field: %@', [L10n.text(field!)]),
    'unsupported' => L10n.text('This challenge backup is too large or uses an unsupported format.'),
    _ => L10n.text('The challenge changed. Reopen it to continue.'),
  };

  @override
  String toString() => 'ChallengeError.$kind${field == null ? '' : '($field)'}';
}

class ChallengeDefinition {
  ChallengeDefinition({
    String? id,
    required this.title,
    this.detail = '',
    this.helpPages,
    required this.reels,
    this.groups = const [],
    this.template = '{reel1} · {reel2} · {goal}',
    ChallengeGoalRule? goal,
    this.target = 100,
    List<ChallengeScoreBand>? bands,
    this.multiplier = 1.0,
    required this.endings,
    this.fixedEndingID,
  }) : id = id ?? uuidString(),
       goal = goal ?? ChallengeGoalRule(),
       bands =
           bands ??
           [
             ChallengeScoreBand(through: 40, minimum: 12, maximum: 20),
             ChallengeScoreBand(through: 80, minimum: 6, maximum: 11),
             ChallengeScoreBand(through: 100, minimum: 1, maximum: 5),
           ];

  String id;
  String title;
  String detail;
  List<ChallengeHelpPage>? helpPages;
  List<ChallengeGroup> reels;
  List<ChallengeGroup> groups;
  String template;
  ChallengeGoalRule goal;
  int target;
  List<ChallengeScoreBand> bands;
  double multiplier;
  List<ChallengeEnding> endings;
  String? fixedEndingID;

  List<String> get variables => ['reel1', 'reel2', 'goal', for (var index = 0; index < groups.length; index++) 'extra${index + 1}'];

  static const exampleID = 'builtin.croquis.v1';

  /// The tabs of How to Play: the challenge's own details first, then its help pages.
  List<ChallengeHelpPage> get instructionPages {
    final pages = <ChallengeHelpPage>[
      if (detail.trim().isNotEmpty) ChallengeHelpPage(id: 'overview', title: L10n.text('How to Play'), body: detail),
      ...?helpPages,
    ];
    if (pages.isEmpty) {
      pages.add(
        ChallengeHelpPage(
          id: 'overview',
          title: L10n.text('How to Play'),
          body: L10n.text('Draw a mission, complete its goal, and collect points until the final result.'),
        ),
      );
    }
    return pages;
  }

  ChallengeDefinition copy() => ChallengeDefinition.fromJson(decodeJsonObject(encodeSwiftJson(toJson())));

  factory ChallengeDefinition.fromJson(JsonObject json) {
    ChallengeGroup group(Object? value) => ChallengeGroup.fromJson(jsonObject(value));
    return ChallengeDefinition(
      id: json.string('id'),
      title: json.string('title'),
      detail: json.string('detail'),
      helpPages: json.listOrNull('helpPages', (value) => ChallengeHelpPage.fromJson(jsonObject(value))),
      reels: json.list('reels', group),
      groups: json.list('groups', group),
      template: json.string('template'),
      goal: ChallengeGoalRule.fromJson(json.object('goal')),
      target: json.integer('target'),
      bands: json.list('bands', (value) => ChallengeScoreBand.fromJson(jsonObject(value))),
      multiplier: json.number('multiplier'),
      endings: json.list('endings', (value) => ChallengeEnding.fromJson(jsonObject(value))),
      fixedEndingID: json.stringOrNull('fixedEndingID'),
    );
  }

  JsonObject toJson() =>
      <String, Object?>{
          'id': id,
          'title': title,
          'detail': detail,
          'reels': [for (final group in reels) group.toJson()],
          'groups': [for (final group in groups) group.toJson()],
          'template': template,
          'goal': goal.toJson(),
          'target': target,
          'bands': [for (final band in bands) band.toJson()],
          'multiplier': multiplier,
          'endings': [for (final ending in endings) ending.toJson()],
        }
        ..putIfPresent('helpPages', helpPages == null ? null : [for (final page in helpPages!) page.toJson()])
        ..putIfPresent('fixedEndingID', fixedEndingID);

  /// Swift counts characters, not UTF-16 units.
  static int _count(String text) => text.characters.length;

  void validate() {
    void require(bool value, String field) {
      if (!value) throw ChallengeError.invalid(field);
    }

    bool validText(String text, {int max = 4000}) => text.trim().isNotEmpty && _count(text) <= max;

    require(validText(id, max: 128) && validText(title, max: 200) && _count(detail) <= 4000, 'Challenge Details');
    require(reels.length == 2 && groups.length <= 12, 'Draw Options');
    final help = helpPages ?? [];
    require(help.length <= 12 && help.map((page) => page.id).toSet().length == help.length, 'Help Tabs');
    for (final page in help) {
      require(page.id != 'overview' && validText(page.id, max: 128) && validText(page.title, max: 200) && validText(page.body, max: 16000), 'Help Tabs');
    }
    final all = [...reels, ...groups];
    require(all.map((group) => group.id).toSet().length == all.length, 'Draw Options');
    for (final group in all) {
      require(validText(group.id, max: 128) && validText(group.title, max: 200) && _count(group.filter) <= 200, 'Draw Options');
      require(group.options.isNotEmpty && group.options.length <= 1000 && group.eligible.isNotEmpty, group.title);
      require(group.options.map((option) => option.id).toSet().length == group.options.length, group.title);
      for (final option in group.options) {
        require(
          validText(option.id, max: 128) && validText(option.text) && _count(option.group) <= 200 && option.weight >= 1 && option.weight <= 10000,
          group.title,
        );
        // Atomic tags only: filters and server settings remain user controlled.
        require(
          option.tags.length <= 20 &&
              option.tags.every(
                (tag) =>
                    validText(tag, max: 128) &&
                    !tag.characters.any(isWhitespace) &&
                    !tag.contains(':') &&
                    !tag.startsWith('-') &&
                    !tag.startsWith('~') &&
                    !tag.contains('{') &&
                    !tag.contains('}'),
              ),
          'Search Tags',
        );
      }
    }
    require(goal.time.validate(86400) && goal.count.validate(10000), 'Goal Range');
    require(goal.timeWeight >= 1 && goal.timeWeight <= 10000 && goal.countWeight >= 1 && goal.countWeight <= 10000, 'Goal Probability');
    require(target >= 1 && target <= 100000 && const [0.5, 1.0, 1.5, 2.0].contains(multiplier), 'Scoring');
    require(bands.isNotEmpty && bands.length <= 100 && bands.map((band) => band.id).toSet().length == bands.length, 'Scoring');
    var previous = -1;
    for (final band in bands) {
      require(
        validText(band.id, max: 128) &&
            band.through > previous &&
            band.through <= 100000 &&
            band.minimum > 0 &&
            band.maximum >= band.minimum &&
            band.maximum <= 100000,
        'Scoring',
      );
      previous = band.through;
    }
    require(previous >= target - 1, 'Scoring');
    require(endings.isNotEmpty && endings.length <= 100 && endings.map((ending) => ending.id).toSet().length == endings.length, 'Endings');
    for (final ending in endings) {
      require(
        validText(ending.id, max: 128) &&
            validText(ending.title, max: 200) &&
            _count(ending.detail) <= 4000 &&
            _count(ending.badge) <= 40 &&
            ChallengeEnding.colors.contains(ending.color) &&
            ending.weight >= 1 &&
            ending.weight <= 10000,
        'Endings',
      );
    }
    require(fixedEndingID == null || endings.any((ending) => ending.id == fixedEndingID), 'Endings');
    require(validText(template), 'Mission Text');
    final pattern = RegExp(r'\{([^{}]*)\}');
    require(pattern.allMatches(template).every((match) => variables.contains(match[1])), 'Mission Variables');
    final remainder = template.replaceAll(pattern, '');
    require(!remainder.contains('{') && !remainder.contains('}'), 'Mission Variables');
  }

  static ChallengeDefinition croquis() {
    ChallengeOption option(String key, String tag) => ChallengeOption(text: L10n.text(key), tags: [tag]);
    return ChallengeDefinition(
      title: L10n.text('Croquis Challenge'),
      detail: L10n.text(
        'Draw a subject, a drawing method, and a time limit. Choose a reference image, then start the timer when you are ready. Sketch until time is up and tap Complete Mission to earn points. Reach 100 points to finish your session. You can pause or skip a mission at any time.',
      ),
      reels: [
        ChallengeGroup(
          title: L10n.text('Subject'),
          options: [option('Person', 'solo'), option('Animal', 'animal'), option('Scenery', 'scenery'), option('Object', 'still_life')],
        ),
        ChallengeGroup(
          title: L10n.text('Drawing Method'),
          options: [
            for (final text in ['Outline', 'Large Shapes', 'Light and Shadow']) ChallengeOption(text: L10n.text(text)),
          ],
        ),
      ],
      template: L10n.text('Sketch {reel1} using {reel2}. Goal: {goal}.'),
      endings: [
        ChallengeEnding(
          title: L10n.text('Great Practice'),
          detail: L10n.text('You completed your sketch session. Take a look at your progress.'),
          badge: '★',
          color: 'purple',
          weight: 10,
        ),
        ChallengeEnding(
          title: L10n.text('Fresh Perspective'),
          detail: L10n.text('Every sketch helps you see new shapes.'),
          badge: '✦',
          color: 'purple',
          weight: 45,
        ),
        ChallengeEnding(
          title: L10n.text('Creative Momentum'),
          detail: L10n.text('Keep your sketches and enjoy what you learned.'),
          badge: '✧',
          color: 'purple',
          weight: 45,
        ),
      ],
    );
  }
}

class ChallengeBackup {
  ChallengeBackup({this.format = 'tegnal-challenges', this.schemaVersion = 1, required this.games});
  String format;
  int schemaVersion;
  List<ChallengeDefinition> games;
  static const maximumBytes = 10 * 1024 * 1024;

  void validate() {
    if (format != 'tegnal-challenges' || schemaVersion != 1) throw const ChallengeError.unsupported();
    if (games.length > 200 || games.map((game) => game.id).toSet().length != games.length) throw const ChallengeError.invalid('Challenges');
    for (final game in games) {
      game.validate();
    }
  }

  factory ChallengeBackup.fromJson(JsonObject json) => ChallengeBackup(
    format: json.string('format'),
    schemaVersion: json.integer('schemaVersion'),
    games: json.list('games', (value) => ChallengeDefinition.fromJson(jsonObject(value))),
  );
  JsonObject toJson() => {
    'format': format,
    'schemaVersion': schemaVersion,
    'games': [for (final game in games) game.toJson()],
  };

  Uint8List encoded() {
    validate();
    final data = encodeJson(toJson(), pretty: true, escapingSlashes: false);
    if (data.length > maximumBytes) throw const ChallengeError.unsupported();
    return data;
  }

  static ChallengeBackup decode(List<int> data) {
    if (data.length > maximumBytes) throw const ChallengeError.unsupported();
    final value = ChallengeBackup.fromJson(decodeJsonObject(data));
    // Normalize historical backups before validation and future exports.
    if (value.format == 'number-memo-challenges') value.format = 'tegnal-challenges';
    value.validate();
    return value;
  }
}
