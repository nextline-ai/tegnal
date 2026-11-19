import 'dart:convert';
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';

import '../challenge/challenge_models.dart';
import '../study/study_models.dart';
import '../support/l10n.dart';
import '../support/swift_json.dart';

// MARK: - The file

/// An add-on: a data file, made by anyone, that the person downloads and opens in the app
/// (`Addon` in `AddonModels.swift`).
///
/// Add-ons are data only. They carry no code, no web content and no addresses, and nothing in them
/// is run, fetched or opened. Every part is checked before it is shown, the app keeps the checked
/// copy (not the file itself), and what an add-on adds stays apart from the person's own settings,
/// so turning it off or removing it leaves everything as it was.
class Addon {
  Addon._({
    required this.id,
    required this.version,
    required this.name,
    required this.author,
    required this.summary,
    required this.contents,
    required this.json,
  });

  static const format = 'tegnal-addon';
  static const schemaVersion = 1;
  static const maximumBytes = 8 * 1024 * 1024;
  static const fileExtension = 'tegnaladdon';

  /// Lowercase letters, digits, dots, hyphens and underscores, such as `studio.night-owl.ko-tags`.
  final String id;

  /// Digits and dots, such as `1.2.0`.
  final String version;
  final StudyText name;
  final String author;
  final StudyText? summary;
  final AddonContents contents;

  /// The checked add-on as it is kept: only the keys the app reads, English filled in.
  final JsonObject json;

  String get title => name.addonResolved();

  static const _topKeys = {'format', 'schemaVersion', 'id', 'version', 'name', 'author', 'summary', 'contents'};

  /// Reads a file the person picked. Nothing in it is used until it has passed every check.
  static Future<({Addon addon, String digest})> read(File file) async {
    if (await file.length() > maximumBytes) throw const AddonError.tooLarge();
    final handle = await file.open();
    try {
      // One byte past the limit, so that a file that grew after its size was read is still refused.
      return decode(await handle.read(maximumBytes + 1));
    } finally {
      await handle.close();
    }
  }

  static ({Addon addon, String digest}) decode(List<int> data) {
    if (data.length > maximumBytes) throw const AddonError.tooLarge();
    Object? object;
    try {
      object = jsonDecode(utf8.decode(data));
    } on Object {
      throw const AddonError.notAddon();
    }
    if (object is! Map<String, Object?> || object['format'] != format) throw const AddonError.notAddon();
    final schema = object['schemaVersion'];
    if (schema is! int || schema < 1) throw const AddonError.notAddon();
    if (schema > schemaVersion) throw const AddonError.newerFormat();
    // Anything not understood is refused rather than skipped, so that what is shown is all the file does.
    final extra = (object.keys.toSet().difference(_topKeys).toList()..sort()).firstOrNull;
    if (extra != null) throw AddonError.unknownContent(extra);
    final contents = object['contents'];
    if (contents is! Map<String, Object?>) throw const AddonError.empty();
    final unknown = (contents.keys.toSet().difference(AddonContents.keys).toList()..sort()).firstOrNull;
    if (unknown != null) throw AddonError.unknownContent(unknown);
    // Text written in Korean or Japanese only is shown in English too, rather than left blank.
    final filled = <String, Object?>{...object};
    for (final key in ['name', 'summary']) {
      if (filled[key] != null) filled[key] = _fillEnglish(filled[key], 0);
    }
    if (contents['learningTrack'] != null) filled['contents'] = {...contents, 'learningTrack': _fillEnglish(contents['learningTrack'], 0)};
    return (addon: fromJson(filled), digest: digest(data));
  }

  /// An add-on from its kept or filled-in form, checked in full. Throws [AddonError] when any part is not allowed.
  static Addon fromJson(JsonObject json) {
    final Addon addon;
    try {
      final contents = AddonContents._fromJson(json.object('contents'));
      addon = Addon._(
        id: json.string('id'),
        version: json.string('version'),
        name: json.dictionary('name', jsonString),
        author: json.string('author'),
        summary: json.dictionaryOrNull('summary', jsonString),
        contents: contents,
        json: {
          'format': json.string('format'),
          'schemaVersion': json.integer('schemaVersion'),
          'id': json.string('id'),
          'version': json.string('version'),
          'name': json.dictionary('name', jsonString),
          'author': json.string('author'),
          'summary': ?json.dictionaryOrNull('summary', jsonString),
          'contents': contents.json,
        },
      );
    } on AddonError {
      rethrow;
    } on SwiftJsonError catch (failure) {
      throw AddonError.invalid(_field(failure.message));
    } on Object {
      throw AddonError.invalid(L10n.text('File'));
    }
    addon.validate();
    return addon;
  }

  static String _field(String message) => RegExp(r'"([^"]*)"').firstMatch(message)?.group(1) ?? L10n.text('File');

  /// Gives every text in the app languages an English wording, taken from Korean or Japanese where English is missing.
  static Object? _fillEnglish(Object? value, int depth) {
    if (depth >= 24) return value;
    if (value is Map<String, Object?>) {
      const languages = {'en', 'ko', 'ja'};
      if (value.isNotEmpty && languages.containsAll(value.keys) && value.values.every((inner) => inner is String)) {
        return {...value, if (value['en'] == null && (value['ko'] ?? value['ja']) != null) 'en': value['ko'] ?? value['ja']};
      }
      return {for (final entry in value.entries) entry.key: _fillEnglish(entry.value, depth + 1)};
    }
    if (value is List) return [for (final inner in value) _fillEnglish(inner, depth + 1)];
    return value;
  }

  static String digest(List<int> data) => sha256.convert(data).toString();

  static const limits = (translations: 100000, searchTags: 500, challenges: 50, sections: 40, lessons: 300, steps: 80, groups: 60, tags: 2000);

  void validate() {
    void require(bool value, String field) {
      if (!value) throw AddonError.invalid(field);
    }

    require(
      json['format'] == format && json['schemaVersion'] is int && (json['schemaVersion']! as int) >= 1 && (json['schemaVersion']! as int) <= schemaVersion,
      'format',
    );
    require(AddonCheck.identifier(id), 'id');
    require(AddonCheck.version(version), 'version');
    require(AddonCheck.text(name, max: 80), 'name');
    require(AddonCheck.line(author, max: 80), 'author');
    if (summary case final summary?) require(AddonCheck.text(summary, max: 600, multiline: true), 'summary');
    if (contents.kinds.isEmpty) throw const AddonError.empty();

    if (contents.tagTranslations case final translations?) {
      require(const ['en', 'ko', 'ja'].contains(translations.language), 'tagTranslations.language');
      require(translations.entries.isNotEmpty && translations.entries.length <= limits.translations, 'tagTranslations.entries');
      final seen = <String>{};
      for (final MapEntry(key: tag, value: words) in translations.entries.entries) {
        final key = AddonCheck.tagKey(tag);
        require(AddonCheck.tag(key, namespaced: true), 'tagTranslations: ${AddonCheck.preview(tag)}');
        require(AddonCheck.line(words, max: 80), 'tagTranslations: ${AddonCheck.preview(tag)}');
        // One tag, one translation: `Long_Hair` and `long hair` are the same tag.
        require(seen.add(key), 'tagTranslations: ${AddonCheck.preview(tag)}');
      }
    }

    if (contents.searchTags case final search?) {
      for (final (field, list) in [('searchTags.comics.include', search.comicsInclude), ('searchTags.comics.exclude', search.comicsExclude)]) {
        if (list == null) continue;
        require(list.length <= limits.searchTags, field);
        for (final term in list) {
          require(AddonCheck.comicsTerm(term), '$field: ${AddonCheck.preview(term)}');
        }
      }
      if (search.imageExclude case final rules?) {
        require(rules.length <= limits.searchTags, 'searchTags.images.exclude');
        for (final rule in rules) {
          require(AddonCheck.imageRule(rule), 'searchTags.images.exclude: ${AddonCheck.preview(rule)}');
        }
      }
      final total = (search.comicsInclude?.length ?? 0) + (search.comicsExclude?.length ?? 0) + (search.imageExclude?.length ?? 0);
      require(total > 0, 'searchTags');
    }

    if (contents.challenges case final games?) {
      require(games.isNotEmpty && games.length <= limits.challenges, 'challenges');
      require(games.map((game) => game.id).toSet().length == games.length, 'challenges');
      for (final game in games) {
        require(AddonCheck.identifier(game.id), 'challenges: ${AddonCheck.preview(game.id)}');
        try {
          game.validate();
        } on Object {
          throw AddonError.invalid('challenges: ${AddonCheck.preview(game.title)}');
        }
        require(AddonCheck.challengeText(game), 'challenges: ${AddonCheck.preview(game.title)}');
      }
    }

    contents.learningTrack?.validate();
  }
}

enum AddonKind {
  translations,
  searchTags,
  challenges,
  track;

  String get title => switch (this) {
    translations => L10n.text('Tag Translations'),
    searchTags => L10n.text('Default and Excluded Tags'),
    challenges => L10n.text('Challenge Roulette'),
    track => L10n.text('Learning Track'),
  };
}

/// What an add-on brings. One file may bring several of these together, such as a track with the translations it uses.
class AddonContents {
  AddonContents._({this.tagTranslations, this.searchTags, this.challenges, this.learningTrack, required this.json});

  final AddonTranslations? tagTranslations;
  final AddonSearchTags? searchTags;
  final List<ChallengeDefinition>? challenges;
  final AddonTrack? learningTrack;
  final JsonObject json;

  static const keys = {'tagTranslations', 'searchTags', 'challenges', 'learningTrack'};

  List<AddonKind> get kinds => [
    if (tagTranslations != null) AddonKind.translations,
    if (searchTags != null) AddonKind.searchTags,
    if (challenges != null) AddonKind.challenges,
    if (learningTrack != null) AddonKind.track,
  ];

  factory AddonContents._fromJson(JsonObject json) {
    final translations = json.objectOrNull('tagTranslations') == null ? null : AddonTranslations._fromJson(json.object('tagTranslations'));
    final search = json.objectOrNull('searchTags') == null ? null : AddonSearchTags._fromJson(json.object('searchTags'));
    List<ChallengeDefinition>? games;
    if (json['challenges'] != null) {
      games = json.list('challenges', (value) {
        try {
          return ChallengeDefinition.fromJson(jsonObject(value));
        } on Object {
          throw const AddonError.invalid('challenges');
        }
      });
    }
    final track = json.objectOrNull('learningTrack') == null ? null : AddonTrack._fromJson(json.object('learningTrack'));
    return AddonContents._(
      tagTranslations: translations,
      searchTags: search,
      challenges: games,
      learningTrack: track,
      json: {
        'tagTranslations': ?translations?.json,
        'searchTags': ?search?.json,
        if (games != null) 'challenges': [for (final game in games) game.toJson()],
        'learningTrack': ?track?.json,
      },
    );
  }
}

/// Tag names shown in another wording. Each tag has exactly one translation; applied, it is shown in place of the tag.
/// Searches still use the tag itself.
class AddonTranslations {
  AddonTranslations._(this.language, this.entries);

  /// The language of the translations: `en`, `ko` or `ja`. Shown to the person; translations apply in every app language.
  final String language;

  /// Tag, as servers write it (`long_hair`, `female:glasses`), to the words shown for it.
  final Map<String, String> entries;

  JsonObject get json => {'language': language, 'entries': entries};

  factory AddonTranslations._fromJson(JsonObject json) => AddonTranslations._(json.string('language'), json.dictionary('entries', jsonString));
}

/// Tags added to searches and tags hidden from them.
class AddonSearchTags {
  AddonSearchTags._({this.comicsInclude, this.comicsExclude, this.imageExclude});

  /// Added to every comics search, like the Default Tags setting.
  final List<String>? comicsInclude;

  /// Hidden from every comics search, like the Default Excluded Tags setting. Written without a minus sign.
  final List<String>? comicsExclude;

  /// Rules that hide images on every server, written like blacklist lines.
  final List<String>? imageExclude;

  JsonObject get json => {
    if (comicsInclude != null || comicsExclude != null) 'comics': {'include': ?comicsInclude, 'exclude': ?comicsExclude},
    if (imageExclude != null) 'images': {'exclude': imageExclude},
  };

  factory AddonSearchTags._fromJson(JsonObject json) {
    final comics = json.objectOrNull('comics');
    final images = json.objectOrNull('images');
    return AddonSearchTags._(
      comicsInclude: comics?.stringsOrNull('include'),
      comicsExclude: comics?.stringsOrNull('exclude'),
      imageExclude: images?.stringsOrNull('exclude'),
    );
  }
}

/// A learning-mode track finished apart from the main track. Its sections keep the shape of the
/// bundled `StudyPath.json`; they are read here only to be checked, and kept with only the keys the
/// path reads.
class AddonTrack {
  AddonTrack._({required this.title, required this.summary, required this.color, this.symbol, this.groups, required this.sections, required this.json});

  final StudyText title;
  final StudyText summary;

  /// Six hexadecimal digits.
  final String color;
  final String? symbol;

  /// Tags the track teaches that the bundled curriculum does not, in its group format.
  final List<StudyGroup>? groups;

  /// Sections as `StudyPath.json` writes them, cleaned to the keys the path reads.
  final List<JsonObject> sections;
  final JsonObject json;

  static const poses = {'wave', 'cheer', 'think', 'sad', 'read', 'close-up', 'full-body'};

  List<JsonObject> get lessons => [for (final section in sections) ...(section['lessons']! as List).cast<JsonObject>()];

  factory AddonTrack._fromJson(JsonObject json) {
    final groups = json.listOrNull('groups', (value) => StudyGroup.fromJson(jsonObject(value)));
    final sections = json.list('sections', (value) => _section(jsonObject(value)));
    return AddonTrack._(
      title: json.dictionary('title', jsonString),
      summary: json.dictionary('summary', jsonString),
      color: json.string('color'),
      symbol: json.stringOrNull('symbol'),
      groups: groups,
      sections: sections,
      json: {
        'title': json.dictionary('title', jsonString),
        'summary': json.dictionary('summary', jsonString),
        'color': json.string('color'),
        'symbol': ?json.stringOrNull('symbol'),
        if (groups != null) 'groups': [for (final group in groups) _groupJson(group)],
        'sections': sections,
      },
    );
  }

  static JsonObject _groupJson(StudyGroup group) => {
    'id': group.id,
    'title': group.title,
    'exclusive': group.exclusive,
    'visual': group.visual,
    'tags': [
      for (final tag in group.tags) {'name': tag.name, 'ko': ?tag.ko, 'ja': ?tag.ja, 'note': tag.note, 'confusable': ?tag.confusable},
    ],
  };

  static StudyText _text(JsonObject json, String key) => json.dictionary(key, jsonString);
  static StudyText? _textOrNull(JsonObject json, String key) => json.dictionaryOrNull(key, jsonString);

  // The same keys Swift's `StudyPathLesson` decodes; anything else is dropped from the kept copy.
  static JsonObject _section(JsonObject json) => {
    'id': json.string('id'),
    'title': _text(json, 'title'),
    'summary': _text(json, 'summary'),
    'color': json.string('color'),
    'lessons': json.list('lessons', (value) => _lesson(jsonObject(value))),
  };

  static JsonObject _lesson(JsonObject json) {
    final kind = json.string('kind');
    if (!const {'concept', 'tags', 'boss'}.contains(kind)) throw SwiftJsonError('Unknown value for "kind"');
    return {
      'id': json.string('id'),
      'kind': kind,
      'symbol': json.string('symbol'),
      'title': _text(json, 'title'),
      'summary': ?_textOrNull(json, 'summary'),
      'tags': ?json.stringsOrNull('tags'),
      if (json['steps'] != null) 'steps': json.list('steps', (value) => _step(jsonObject(value))),
    };
  }

  static JsonObject _step(JsonObject json) => {
    if (json.objectOrNull('card') case final card?)
      'card': {
        'title': _text(card, 'title'),
        'body': _text(card, 'body'),
        'code': ?card.stringOrNull('code'),
        'symbol': ?card.stringOrNull('symbol'),
        'pose': ?card.stringOrNull('pose'),
        'action': ?card.stringOrNull('action'),
      },
    if (json.objectOrNull('ask') case final ask?)
      'ask': {
        'question': _text(ask, 'question'),
        'choices': ask.list('choices', (value) => jsonObject(value).map((key, inner) => MapEntry(key, jsonString(inner)))),
        'answer': ask.integer('answer'),
        'why': _text(ask, 'why'),
        'code': ?ask.booleanOrNull('code'),
      },
    if (json.objectOrNull('build') case final build?)
      'build': {'brief': _text(build, 'brief'), 'answer': build.strings('answer'), 'extras': build.strings('extras')},
    if (json.objectOrNull('order') case final order?)
      'order': {
        'brief': _text(order, 'brief'),
        'items': order.list('items', (value) => jsonObject(value).map((key, inner) => MapEntry(key, jsonString(inner)))),
        'why': _text(order, 'why'),
      },
    if (json.objectOrNull('sort') case final sort?)
      'sort': {
        'brief': _text(sort, 'brief'),
        'left': _text(sort, 'left'),
        'right': _text(sort, 'right'),
        'items': sort.list('items', (value) {
          final item = jsonObject(value);
          return {'text': _text(item, 'text'), 'right': item.boolean('right')};
        }),
        'why': _text(sort, 'why'),
      },
  };

  void validate() {
    void require(bool value, String field) {
      if (!value) throw AddonError.invalid('learningTrack: $field');
    }

    require(AddonCheck.text(title, max: 80), 'title');
    require(AddonCheck.text(summary, max: 400, multiline: true), 'summary');
    require(AddonCheck.color(color), 'color');
    if (symbol case final symbol?) require(AddonCheck.symbol(symbol), 'symbol');

    final known = <String>{};
    final groups = this.groups ?? const <StudyGroup>[];
    require(groups.length <= Addon.limits.groups, 'groups');
    require(groups.map((group) => group.id).toSet().length == groups.length, 'groups');
    for (final group in groups) {
      require(AddonCheck.identifier(group.id) && AddonCheck.text(group.title, max: 80), 'groups: ${AddonCheck.preview(group.id)}');
      require(group.tags.isNotEmpty, 'groups: ${AddonCheck.preview(group.id)}');
      for (final tag in group.tags) {
        final field = 'tag ${AddonCheck.preview(tag.name)}';
        require(AddonCheck.tag(tag.name, namespaced: false), field);
        require(AddonCheck.text(tag.note, max: 400, multiline: true), field);
        for (final name in [?tag.ko, ?tag.ja]) {
          require(AddonCheck.line(name, max: 80), field);
        }
        final confusable = tag.confusable ?? const <String>[];
        require(confusable.length <= 10 && confusable.every((name) => AddonCheck.tag(name, namespaced: false)), field);
        require(known.add(tag.name), field);
      }
    }
    require(known.length <= Addon.limits.tags, 'groups');

    require(sections.isNotEmpty && sections.length <= Addon.limits.sections, 'sections');
    require(sections.map((section) => section['id']).toSet().length == sections.length, 'sections');
    final lessons = this.lessons;
    require(lessons.isNotEmpty && lessons.length <= Addon.limits.lessons, 'lessons');
    require(lessons.map((lesson) => lesson['id']).toSet().length == lessons.length, 'lessons');
    for (final section in sections) {
      final id = section['id']! as String;
      require(AddonCheck.identifier(id), 'section ${AddonCheck.preview(id)}');
      require(
        AddonCheck.text(section['title']! as StudyText, max: 80) &&
            AddonCheck.text(section['summary']! as StudyText, max: 400, multiline: true) &&
            AddonCheck.color(section['color']! as String),
        'section ${AddonCheck.preview(id)}',
      );
      for (final lesson in (section['lessons']! as List).cast<JsonObject>()) {
        _validateLesson(lesson, known);
      }
    }
  }

  void _validateLesson(JsonObject lesson, Set<String> known) {
    final id = lesson['id']! as String;
    void require(bool value) {
      if (!value) throw AddonError.invalid('learningTrack: lesson ${AddonCheck.preview(id)}');
    }

    StudyText text(Object? value) => value! as StudyText;
    bool texts(Object? value, int max, {bool multiline = false}) =>
        value is List && value.every((item) => AddonCheck.text(item as StudyText, max: max, multiline: multiline));

    require(AddonCheck.identifier(id) && AddonCheck.symbol(lesson['symbol']! as String) && AddonCheck.text(text(lesson['title']), max: 80));
    if (lesson['summary'] case final StudyText summary) require(AddonCheck.text(summary, max: 400, multiline: true));
    final tags = (lesson['tags'] as List<String>?) ?? const <String>[];
    final steps = (lesson['steps'] as List?)?.cast<JsonObject>() ?? const <JsonObject>[];
    bool taught(String name) => known.contains(name) || StudyCurriculum.bundled.contains(name);
    if (lesson['kind'] == 'tags') {
      // Every tag of a tags lesson needs a meaning, from the app's curriculum or from the track's own groups.
      require(steps.isEmpty && tags.isNotEmpty && tags.length <= 12 && tags.toSet().length == tags.length && tags.every(taught));
      return;
    }
    require(tags.isEmpty && steps.isNotEmpty && steps.length <= Addon.limits.steps);
    for (final step in steps) {
      require(step.length == 1);
      if (step['card'] case final JsonObject card) {
        // Cards in add-ons only tell: they never open a page, a key sheet or the generator.
        require(card['action'] == null);
        require(AddonCheck.text(text(card['title']), max: 120) && AddonCheck.text(text(card['body']), max: 2000, multiline: true));
        require(card['code'] == null || AddonCheck.line(card['code']! as String, max: 1000, multiline: true));
        require(card['symbol'] == null || AddonCheck.symbol(card['symbol']! as String));
        require(card['pose'] == null || poses.contains(card['pose']));
      }
      if (step['ask'] case final JsonObject ask) {
        final choices = ask['choices']! as List;
        final answer = ask['answer']! as int;
        require(AddonCheck.text(text(ask['question']), max: 400, multiline: true) && AddonCheck.text(text(ask['why']), max: 600, multiline: true));
        require(choices.length >= 2 && choices.length <= 6 && answer >= 0 && answer < choices.length && texts(choices, 300, multiline: true));
      }
      if (step['build'] case final JsonObject build) {
        final answer = build['answer']! as List<String>, extras = build['extras']! as List<String>;
        require(AddonCheck.text(text(build['brief']), max: 400, multiline: true));
        require(answer.isNotEmpty && answer.length <= 12 && answer.toSet().length == answer.length && extras.length <= 12);
        require([...answer, ...extras].every((tag) => AddonCheck.tag(tag, namespaced: false)) && answer.toSet().intersection(extras.toSet()).isEmpty);
      }
      if (step['order'] case final JsonObject order) {
        final items = order['items']! as List;
        require(AddonCheck.text(text(order['brief']), max: 400, multiline: true) && AddonCheck.text(text(order['why']), max: 600, multiline: true));
        require(items.length >= 2 && items.length <= 8 && texts(items, 200));
      }
      if (step['sort'] case final JsonObject sort) {
        final items = (sort['items']! as List).cast<JsonObject>();
        require(AddonCheck.text(text(sort['brief']), max: 400, multiline: true) && AddonCheck.text(text(sort['why']), max: 600, multiline: true));
        require(AddonCheck.text(text(sort['left']), max: 60) && AddonCheck.text(text(sort['right']), max: 60));
        require(items.length >= 2 && items.length <= 12 && items.every((item) => AddonCheck.text(text(item['text']), max: 200)));
      }
    }
  }
}

// MARK: - Errors

class AddonError implements Exception {
  const AddonError.tooLarge() : kind = 'tooLarge', detail = null;
  const AddonError.notAddon() : kind = 'notAddon', detail = null;
  const AddonError.newerFormat() : kind = 'newerFormat', detail = null;
  const AddonError.unknownContent(String key) : kind = 'unknownContent', detail = key;
  const AddonError.empty() : kind = 'empty', detail = null;
  const AddonError.invalid(String field) : kind = 'invalid', detail = field;

  final String kind;
  final String? detail;

  String get errorDescription => switch (kind) {
    'tooLarge' => L10n.text('This add-on file is too large.'),
    'notAddon' => L10n.text('This file is not a TEGNAL add-on.'),
    'newerFormat' => L10n.text('This add-on needs a newer version of TEGNAL.'),
    'unknownContent' => L10n.text('This add-on contains something TEGNAL does not support: %@', [detail!]),
    'empty' => L10n.text('This add-on contains nothing to add.'),
    _ => L10n.text('This add-on was not added because a part of it is not allowed: %@', [detail!]),
  };

  @override
  bool operator ==(Object other) => other is AddonError && other.kind == kind && other.detail == detail;
  @override
  int get hashCode => Object.hash(kind, detail);
  @override
  String toString() => 'AddonError.$kind${detail == null ? '' : '($detail)'}';
}

// MARK: - Rules for every piece of text

/// The checks every value from an add-on passes (`AddonCheck`). Text is refused, not cleaned, so that
/// what is shown before installing is exactly what is installed.
abstract final class AddonCheck {
  static final _identifier = RegExp(r'^[a-z0-9][a-z0-9._-]*$');

  static bool identifier(String value, {int max = 48}) => value.length >= 3 && value.length <= max && _identifier.hasMatch(value);

  static final _version = RegExp(r'^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$');
  static bool version(String value) => _version.hasMatch(value);

  /// Compares `1.10` above `1.9`. Negative, zero or positive like [Comparable.compareTo].
  static int compare(String left, String right) {
    final a = left.split('.').map((part) => int.tryParse(part) ?? 0).toList();
    final b = right.split('.').map((part) => int.tryParse(part) ?? 0).toList();
    for (var index = 0; index < (a.length > b.length ? a.length : b.length); index++) {
      final x = index < a.length ? a[index] : 0, y = index < b.length ? b[index] : 0;
      if (x != y) return x < y ? -1 : 1;
    }
    return 0;
  }

  // Control characters, invisible format marks (direction overrides among them), private use,
  // surrogates, unassigned code points and line or paragraph separators.
  static final _hidden = RegExp(r'[\p{Cc}\p{Cf}\p{Co}\p{Cs}\p{Cn}\p{Zl}\p{Zp}]', unicode: true);

  /// One line of plain text, or several when [multiline]. Control characters, invisible formatting and
  /// direction overrides (which can make text read differently from what it is) are refused.
  static bool line(String value, {required int max, bool multiline = false}) {
    if (value.trim().isEmpty || value.characters.length > max) return false;
    for (final match in _hidden.allMatches(value)) {
      final mark = match[0]!;
      // Joiners keep emoji whole; a line break is allowed where several lines are.
      if (mark == '‍' || (multiline && mark == '\n')) continue;
      return false;
    }
    return true;
  }

  /// Text in the app languages. Only `en`, `ko` and `ja` are read.
  static bool text(StudyText value, {required int max, bool multiline = false}) =>
      value.isNotEmpty && value.keys.every(const {'en', 'ko', 'ja'}.contains) && value.values.every((text) => line(text, max: max, multiline: multiline));

  static final _color = RegExp(r'^[0-9A-Fa-f]{6}$');
  static bool color(String value) => _color.hasMatch(value);

  /// A system symbol name: letters, digits and dots.
  static final _symbol = RegExp(r'^[a-z0-9.]{1,60}$');
  static bool symbol(String value) => _symbol.hasMatch(value);

  /// The form a tag is matched in: lowercase, with underscores for spaces.
  static String tagKey(String value) => splitWhitespace(value.trim().toLowerCase()).join('_');

  /// One tag as servers write it. No spaces, search operators or wildcards, so that it can never widen or rewrite a search.
  static bool tag(String value, {required bool namespaced}) {
    if (!line(value, max: 128) || value.contains(RegExp(r'\s'))) return false;
    if ('-~*{}'.contains(value[0])) return false;
    if (value.contains(RegExp(r'[*{}",]'))) return false;
    if (!namespaced && value.endsWith(':')) return false;
    if (namespaced) {
      final colon = value.indexOf(':');
      if (colon >= 0 && colon == value.length - 1) return false;
    }
    return true;
  }

  static const comicsNamespaces = {
    'tag',
    'female',
    'male',
    'mixed',
    'other',
    'artist',
    'group',
    'parody',
    'character',
    'language',
    'type',
    'cosplayer',
    'series',
  };

  /// A term for comics searches. A namespace, when there is one, is one the comics searches already know.
  static bool comicsTerm(String value) {
    if (!tag(value, namespaced: true) || value.startsWith('-')) return false;
    final colon = value.indexOf(':');
    return colon < 0 || comicsNamespaces.contains(value.substring(0, colon).toLowerCase());
  }

  static const ratings = {'g', 's', 'q', 'e', 'general', 'sensitive', 'questionable', 'explicit', 'safe'};

  /// One line of an image blacklist: up to eight terms, all of which must match for an image to be hidden.
  /// Terms are tags, `rating:` and `artist:`, and terms after the first may start with a minus sign.
  static bool imageRule(String value) {
    if (!line(value, max: 400)) return false;
    final terms = splitWhitespace(value.toLowerCase());
    if (terms.isEmpty || terms.length > 8 || terms.first.startsWith('#')) return false;
    for (final (index, raw) in terms.indexed) {
      final negative = raw.startsWith('-');
      if (negative && index == 0) return false;
      final term = negative ? raw.substring(1) : raw;
      if (term.startsWith('rating:')) {
        if (!ratings.contains(term.substring(7))) return false;
      } else if (term.startsWith('artist:')) {
        if (!tag(term.substring(7), namespaced: false)) return false;
      } else if (term.startsWith('id:')) {
        return false;
      } else if (term.isEmpty || !tag(term, namespaced: false)) {
        return false;
      }
    }
    return true;
  }

  /// Every text a challenge shows, held to the same rules as the rest of the add-on.
  static bool challengeText(ChallengeDefinition game) {
    final lines = [
      game.title,
      game.template,
      for (final group in [...game.reels, ...game.groups]) ...[group.title, for (final option in group.options) option.text],
      for (final ending in game.endings) ending.title,
    ];
    final long = [
      game.detail,
      for (final page in game.helpPages ?? const <ChallengeHelpPage>[]) ...[page.title, page.body],
      for (final ending in game.endings) ending.detail,
    ];
    return lines.every((text) => line(text, max: 4000)) &&
        long.every((text) => text.isEmpty || line(text, max: 16000, multiline: true)) &&
        game.endings.every((ending) => ending.badge.isEmpty || line(ending.badge, max: 40));
  }

  /// A short, safe excerpt of a value for an error message.
  static String preview(String value) {
    final shown = value.replaceAll(_hidden, '').characters.take(40).toString();
    return shown.isEmpty ? '?' : shown;
  }
}

extension AddonTextResolved on StudyText {
  /// Like `resolved`, falling back to any language the add-on was written in.
  String addonResolved([String? language]) => this[language ?? L10n.language] ?? this['en'] ?? this['ko'] ?? this['ja'] ?? '';
}
