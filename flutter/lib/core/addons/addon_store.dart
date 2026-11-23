import 'package:flutter/foundation.dart';

import '../booru/booru_store.dart';
import '../challenge/challenge_models.dart';
import '../support/sql_database.dart';
import '../support/swift_json.dart';
import 'addon_models.dart';

/// An add-on kept in the app, with whether it is on (`InstalledAddon`).
class InstalledAddon {
  const InstalledAddon({required this.addon, required this.enabled, required this.installed, required this.digest, this.official = false});
  final Addon addon;
  final bool enabled;
  final DateTime installed;

  /// SHA-256 of the file as it was opened, so that a person can compare it with what its maker published.
  final String digest;

  /// Installed from the official add-ons, checked against TEGNAL's signed catalog, rather than opened from a file.
  final bool official;
  String get id => addon.id;
}

/// What the add-ons that are on change, gathered in one place (`AddonEffects`).
class AddonEffects {
  AddonEffects([List<InstalledAddon> installed = const []]) {
    final seenInclude = <String>{}, seenExclude = <String>{}, seenRules = <String>{};
    for (final item in [...installed]..sort((a, b) => a.installed.compareTo(b.installed))) {
      if (!item.enabled) continue;
      final contents = item.addon.contents;
      enabledIDs.add(item.id);
      enabledModes[item.id] = item.addon.mode;
      // Add-ons installed later win where two translate the same tag.
      for (final MapEntry(key: tag, value: words) in (contents.tagTranslations?.entries ?? const <String, String>{}).entries) {
        translations.putIfAbsent(item.addon.mode, () => {})[AddonCheck.tagKey(tag)] = words;
      }
      for (final term in contents.searchTags?.comicsInclude ?? const <String>[]) {
        if (seenInclude.add(term.toLowerCase())) comicsInclude.add(term);
      }
      for (final term in contents.searchTags?.comicsExclude ?? const <String>[]) {
        if (seenExclude.add(term.toLowerCase())) comicsExclude.add(term);
      }
      for (final rule in contents.searchTags?.imageExclude ?? const <String>[]) {
        if (seenRules.add(rule.toLowerCase())) imageExclude.add(rule);
      }
    }
    for (final MapEntry(key: mode, value: entries) in translations.entries) {
      final byWords = <String, String>{};
      final list = <({String folded, String tag, String words})>[];
      for (final MapEntry(key: tag, value: words) in entries.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
        final folded = fold(words);
        byWords.putIfAbsent(folded, () => tag);
        list.add((folded: folded, tag: tag, words: words));
      }
      tagsByWords[mode] = byWords;
      searchable[mode] = list;
    }
  }

  final enabledIDs = <String>{};

  /// The add-ons that are on, by the mode they belong to.
  final enabledModes = <String, AddonMode>{};

  /// Tag (lowercase, underscores) to the words shown for it, kept apart for each mode.
  final translations = <AddonMode, Map<String, String>>{};

  /// Translated words (folded: lowercase, single spaces, no width or diacritic differences) back to their tag, for searches typed in them.
  /// The first tag given a wording keeps it.
  final tagsByWords = <AddonMode, Map<String, String>>{};

  /// Every translation of a mode as (folded words, tag, words), for suggestions while a search is typed.
  final searchable = <AddonMode, List<({String folded, String tag, String words})>>{};
  final comicsInclude = <String>[];
  final comicsExclude = <String>[];
  final imageExclude = <String>[];


  static const challengePrefix = 'addon:';
  static String challengeID(String addon, String game) => '$challengePrefix$addon:$game';

  int enabledCount(AddonMode mode) => enabledModes.values.where((value) => value == mode).length;

  /// Namespaces of general tags. Comics pages name a general tag by who has it (`female:`, `male:`, `mixed:`, `other:`),
  /// while a translation may list it once as `tag:` or with no namespace.
  static const generalNamespaces = {'female', 'male', 'mixed', 'other', 'tag', 'f', 'm', 'x', 'o'};

  static const _plain = {
    'àáâãäåāăą': 'a',
    'çćĉċč': 'c',
    'ďđ': 'd',
    'èéêëēĕėęě': 'e',
    'ĝğġģ': 'g',
    'ìíîïĩīĭįı': 'i',
    'ñńņňŉ': 'n',
    'òóôõöøōŏő': 'o',
    'ŕŗř': 'r',
    'śŝşšß': 's',
    'ţťŧ': 't',
    'ùúûüũūŭůűų': 'u',
    'ýÿŷ': 'y',
    'źżž': 'z',
  };

  /// Lowercase, single spaces, and no width or diacritic differences, so that wordings compare the way people type them.
  static String fold(String text) {
    final out = StringBuffer();
    for (final rune in text.runes) {
      var code = rune;
      if (code == 0x3000) {
        code = 0x20;
      } else if (code >= 0xFF01 && code <= 0xFF5E) {
        code -= 0xFEE0;
      }
      final char = String.fromCharCode(code).toLowerCase();
      var folded = char;
      for (final MapEntry(key: letters, value: plain) in _plain.entries) {
        if (letters.contains(char)) {
          folded = plain;
          break;
        }
      }
      out.write(folded);
    }
    return out.toString().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).join(' ');
  }

  static bool _ascii(String text) => text.runes.every((rune) => rune < 128);

  /// The words shown for a tag in a mode: by its full name (`female:glasses`); a general tag (`female:`, `male:`, …)
  /// also by its `tag:` name; then by its name without the namespace.
  /// Only that mode's add-ons are read: a comics translation never renames an image tag.
  String? translation(String tag, AddonMode mode) {
    final translations = this.translations[mode];
    if (translations == null || translations.isEmpty) return null;
    final key = AddonCheck.tagKey(tag);
    if (translations[key] case final words?) return words;
    final colon = key.indexOf(':');
    if (colon < 0) return translations['tag:$key'];
    final name = key.substring(colon + 1);
    if (name.isEmpty) return null;
    if (generalNamespaces.contains(key.substring(0, colon))) {
      if (translations['tag:$name'] case final words?) return words;
    }
    return translations[name];
  }

  /// Tags whose translation holds what was typed, those starting with it first. Typed text in plain ASCII letters
  /// is left to the website's own suggestions unless it matches the start of a translation.
  List<({String tag, String words})> tags({required String matching, required AddonMode mode, int limit = 8}) {
    final folded = fold(matching);
    final list = searchable[mode];
    if (folded.isEmpty || list == null) return const [];
    final starts = <({String tag, String words})>[], contains = <({String tag, String words})>[];
    final ascii = _ascii(folded);
    for (final item in list) {
      if (item.folded.startsWith(folded)) {
        starts.add((tag: item.tag, words: item.words));
      } else if (!ascii && item.folded.contains(folded)) {
        contains.add((tag: item.tag, words: item.words));
      }
    }
    List<({String tag, String words})> byLength(List<({String tag, String words})> items) {
      final indexed = items.indexed.toList()
        ..sort((a, b) {
          final byWords = a.$2.words.runes.length.compareTo(b.$2.words.runes.length);
          return byWords != 0 ? byWords : a.$1.compareTo(b.$1);
        });
      return [for (final (_, item) in indexed) item];
    }

    return [...byLength(starts), ...byLength(contains)].take(limit).toList();
  }

  /// A search with every translated name in it written as its tag, so that `제독 -안경` searches `character:teitoku -tag:glasses`.
  /// Only names with letters outside ASCII are turned, so that English searches stay as typed. Names of up to four words are found.
  String searchQuery(String text, AddonMode mode) {
    final index = tagsByWords[mode];
    if (index == null || index.isEmpty || _ascii(text)) return text;
    final words = text.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    final result = <String>[];
    var position = 0;
    while (position < words.length) {
      var matched = false;
      for (var length = words.length - position < 4 ? words.length - position : 4; length >= 1; length--) {
        var phrase = words.sublist(position, position + length).join(' ');
        final negative = phrase.startsWith('-');
        if (negative) phrase = phrase.substring(1);
        if (_ascii(phrase) || index[fold(phrase)] is! String) continue;
        result.add('${negative ? '-' : ''}${index[fold(phrase)]}');
        position += length;
        matched = true;
        break;
      }
      if (!matched) result.add(words[position++]);
    }
    return result.join(' ');
  }
}

/// The effects of the add-ons that are on, read by searches, tag lists and learning mode (`AddonRuntime`).
/// Listeners hear when an add-on is added, turned on or off, or removed.
class AddonRuntime extends ChangeNotifier {
  AddonRuntime._();
  static final shared = AddonRuntime._();

  AddonEffects _effects = AddonEffects();

  /// The mode on screen, for tag names drawn where the mode is not passed along (taste and recap texts,
  /// which always belong to the mode shown). Set whenever the app's mode changes.
  AddonMode displayedMode = AddonMode.comics;
  AddonEffects get effects => _effects;

  void apply(AddonEffects next) {
    _effects = next;
    notifyListeners();
  }

  /// Reads the add-ons again after one was added, changed or removed.
  void reload(BooruStore booru) {
    List<InstalledAddon> installed;
    try {
      installed = AddonStore(booru.database).installed();
    } on Object {
      installed = const [];
    }
    apply(AddonEffects(installed));
  }

  /// Takes in a change to the add-ons everywhere: searches, tag names, image filters, challenges and tracks.
  static void applyChanges(BooruStore booru) {
    shared.reload(booru);
    booru.refresh();
  }

  /// The words to show for a tag, or null to show the tag itself.
  String? translation(String tag, AddonMode mode) => _effects.translation(tag, mode);
}

/// Add-ons kept in the image-mode database, beside the challenges they may bring (`AddonStore`).
class AddonStore {
  AddonStore(this.database);
  final SqlDatabase database;

  static void migrate(SqlDatabase db) => db.execute('''
    CREATE TABLE addons (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, installed DOUBLE NOT NULL, digest TEXT NOT NULL);
    ''');

  static void migrateOrigin(SqlDatabase db) => db.execute('ALTER TABLE addons ADD COLUMN official INTEGER NOT NULL DEFAULT 0');

  /// Every add-on kept, checked again on the way out. One that no longer passes is left out, never used.
  List<InstalledAddon> installed() => database.read(
    (db) => [
      for (final row in db.rows('SELECT payload, enabled, installed, digest, official FROM addons ORDER BY installed'))
        if (_decode(row['payload']) case final addon?)
          InstalledAddon(
            addon: addon,
            enabled: (row['enabled']! as int) != 0,
            installed: DateTime.fromMicrosecondsSinceEpoch(((row['installed']! as num) * 1e6).round()),
            digest: row['digest']! as String,
            official: (row['official']! as int) != 0,
          ),
    ],
  );

  static Addon? _decode(Object? payload) {
    try {
      return Addon.fromJson(decodeJsonObject(payload! as Uint8List));
    } on Object {
      return null;
    }
  }

  /// Adds an add-on, or replaces the one with the same identifier. A replaced add-on stays on or off as it was.
  /// `official` is set only for a copy downloaded from the official add-ons and checked against the signed catalog.
  void install(Addon addon, {required String digest, bool official = false, DateTime? now}) {
    addon.validate();
    final payload = encodeSwiftJson(addon.json);
    database.write((db) {
      final enabled = db.value<int>('SELECT enabled FROM addons WHERE id = ?', [addon.id]) ?? 1;
      final installed = db.value<num>('SELECT installed FROM addons WHERE id = ?', [addon.id]) ?? unixSeconds(now);
      db.execute(
        'INSERT INTO addons (id, payload, enabled, installed, digest, official) VALUES (?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, digest = excluded.digest, official = excluded.official',
        [addon.id, payload, enabled, installed.toDouble(), digest, official ? 1 : 0],
      );
      _writeChallenges(addon, db);
    });
  }

  void setEnabled(String id, bool enabled) => database.write((db) => db.execute('UPDATE addons SET enabled = ? WHERE id = ?', [enabled ? 1 : 0, id]));

  /// Removes an add-on and the challenges it brought. Lessons finished in its track stay in the person's record.
  void remove(String id) => database.write((db) {
    db.execute('DELETE FROM addons WHERE id = ?', [id]);
    final prefix = AddonEffects.challengeID(id, '');
    for (final table in ['challenges', 'challenge_sessions']) {
      db.execute('DELETE FROM $table WHERE substr(id, 1, ?) = ?', [prefix.length, prefix]);
    }
  });

  /// The add-on's challenges join the challenge library under identifiers of its own. An update
  /// replaces them, and drops the ones it no longer has.
  static void _writeChallenges(Addon addon, SqlDatabase db) {
    final prefix = AddonEffects.challengeID(addon.id, '');
    final games = [
      for (final source in addon.contents.challenges ?? const <ChallengeDefinition>[])
        ChallengeDefinition.fromJson(source.toJson())..id = AddonEffects.challengeID(addon.id, source.id),
    ];
    final keep = games.map((game) => game.id).toSet();
    for (final id in db.column<String>('SELECT id FROM challenges WHERE substr(id, 1, ?) = ?', [prefix.length, prefix])) {
      if (keep.contains(id)) continue;
      db.execute('DELETE FROM challenges WHERE id = ?', [id]);
      db.execute('DELETE FROM challenge_sessions WHERE id = ?', [id]);
    }
    for (final game in games) {
      game.validate();
      final data = encodeSwiftJson(game.toJson());
      if (data.length > ChallengeBackup.maximumBytes) throw const ChallengeError.unsupported();
      db.execute('INSERT INTO challenges (id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload', [game.id, data]);
    }
  }
}

/// The word being typed at the end of a search, matched against the translations of the mode's add-ons (`AddonSearchCompletion`).
class AddonSearchCompletion {
  AddonSearchCompletion._(this.prefix, this.excluded, this.term);

  final String prefix;
  final bool excluded;
  final String term;

  static AddonSearchCompletion? parse(String input) {
    if (input.isEmpty || RegExp(r'\s$').hasMatch(input)) return null;
    final tail = input.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).lastOrNull;
    if (tail == null) return null;
    final prefix = input.substring(0, input.length - tail.length);
    final excluded = tail.startsWith('-');
    final term = excluded ? tail.substring(1) : tail;
    if (term.isEmpty || term.runes.length > 64) return null;
    return AddonSearchCompletion._(prefix, excluded, term);
  }

  String inserting(String tag) => '$prefix${excluded ? '-' : ''}$tag ';

  /// Tags whose translation starts with or holds the word, from the add-ons of a mode.
  List<({String tag, String words})> suggestions(AddonMode mode, {int limit = 6}) => AddonRuntime.shared.effects.tags(matching: term, mode: mode, limit: limit);

  @override
  bool operator ==(Object other) => other is AddonSearchCompletion && other.prefix == prefix && other.excluded == excluded && other.term == term;
  @override
  int get hashCode => Object.hash(prefix, excluded, term);
}
