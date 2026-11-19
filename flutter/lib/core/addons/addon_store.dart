import 'package:flutter/foundation.dart';

import '../booru/booru_store.dart';
import '../challenge/challenge_models.dart';
import '../support/sql_database.dart';
import '../support/swift_json.dart';
import 'addon_models.dart';

/// An add-on kept in the app, with whether it is on (`InstalledAddon`).
class InstalledAddon {
  const InstalledAddon({required this.addon, required this.enabled, required this.installed, required this.digest});
  final Addon addon;
  final bool enabled;
  final DateTime installed;

  /// SHA-256 of the file as it was opened, so that a person can compare it with what its maker published.
  final String digest;
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
      // Add-ons installed later win where two translate the same tag.
      for (final MapEntry(key: tag, value: words) in (contents.tagTranslations?.entries ?? const <String, String>{}).entries) {
        translations[AddonCheck.tagKey(tag)] = words;
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
      if (contents.learningTrack != null) tracks.add(item.addon);
    }
  }

  final enabledIDs = <String>{};

  /// Tag (lowercase, underscores) to the words shown for it.
  final translations = <String, String>{};
  final comicsInclude = <String>[];
  final comicsExclude = <String>[];
  final imageExclude = <String>[];

  /// Add-ons that are on and bring a learning track, oldest first.
  final tracks = <Addon>[];

  static const challengePrefix = 'addon:';
  static String challengeID(String addon, String game) => '$challengePrefix$addon:$game';
  static String lessonID(String addon, String lesson) => 'addon:$addon:$lesson';

  /// The words shown for a tag, by its full name (`female:glasses`) or, failing that, its name without the namespace.
  String? translation(String tag) {
    if (translations.isEmpty) return null;
    final key = AddonCheck.tagKey(tag);
    if (translations[key] case final words?) return words;
    final colon = key.indexOf(':');
    return colon >= 0 && colon < key.length - 1 ? translations[key.substring(colon + 1)] : null;
  }
}

/// The effects of the add-ons that are on, read by searches, tag lists and learning mode (`AddonRuntime`).
/// Listeners hear when an add-on is added, turned on or off, or removed.
class AddonRuntime extends ChangeNotifier {
  AddonRuntime._();
  static final shared = AddonRuntime._();

  AddonEffects _effects = AddonEffects();
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
  String? translation(String tag) => _effects.translation(tag);
}

/// Add-ons kept in the image-mode database, beside the challenges they may bring (`AddonStore`).
class AddonStore {
  AddonStore(this.database);
  final SqlDatabase database;

  static void migrate(SqlDatabase db) => db.execute('''
    CREATE TABLE addons (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, installed DOUBLE NOT NULL, digest TEXT NOT NULL);
    ''');

  /// Every add-on kept, checked again on the way out. One that no longer passes is left out, never used.
  List<InstalledAddon> installed() => database.read(
    (db) => [
      for (final row in db.rows('SELECT payload, enabled, installed, digest FROM addons ORDER BY installed'))
        if (_decode(row['payload']) case final addon?)
          InstalledAddon(
            addon: addon,
            enabled: (row['enabled']! as int) != 0,
            installed: DateTime.fromMicrosecondsSinceEpoch(((row['installed']! as num) * 1e6).round()),
            digest: row['digest']! as String,
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
  void install(Addon addon, {required String digest, DateTime? now}) {
    addon.validate();
    final payload = encodeSwiftJson(addon.json);
    database.write((db) {
      final enabled = db.value<int>('SELECT enabled FROM addons WHERE id = ?', [addon.id]) ?? 1;
      final installed = db.value<num>('SELECT installed FROM addons WHERE id = ?', [addon.id]) ?? unixSeconds(now);
      db.execute(
        'INSERT INTO addons (id, payload, enabled, installed, digest) VALUES (?, ?, ?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, digest = excluded.digest',
        [addon.id, payload, enabled, installed.toDouble(), digest],
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
