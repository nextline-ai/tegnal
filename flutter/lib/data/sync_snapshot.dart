import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../core/content.dart';
import 'backup_codec.dart';
import 'library_store.dart';

/// Exact Drive snapshots use the native JSON envelope, while ordinary backup
/// import keeps its existing merge behavior. Device state never moves to Drive.
abstract final class SyncSnapshot {
  /// Ignores only the four export clocks, never dates belonging to saved data.
  /// Map insertion order is immaterial; array order remains meaningful.
  static String fingerprint(String nativeJson) {
    final root = _validatedEnvelope(nativeJson);
    root.remove('exportedAt');
    _section(root, 'comics').remove('exported_at');
    _section(root, 'images').remove('exportedAt');
    _section(root, 'challenges').remove('exportedAt');
    return sha256.convert(utf8.encode(jsonEncode(_canonical(root)))).toString();
  }

  /// Sources, folders, artists, searches, challenges and extension metadata all
  /// count as data, even if neither library has a saved work yet.
  static bool isEmpty(String nativeJson) {
    final root = _validatedEnvelope(nativeJson);
    root.remove('exportedAt');
    root.remove('format');
    root.remove('version');
    for (final name in ['comics', 'images', 'challenges']) {
      final section = _section(root, name);
      section.remove('format');
      section.remove('version');
      section.remove('schemaVersion');
      section.remove(name == 'comics' ? 'exported_at' : 'exportedAt');
    }
    return !_hasContent(root);
  }

  /// Explicitly combining libraries follows the established backup importer:
  /// unique entries survive and the remote snapshot wins duplicate metadata.
  static String merge(String local, String remote) {
    _validatedEnvelope(local);
    _validatedEnvelope(remote);
    final temporary = LibraryStore.memory();
    try {
      final codec = BackupCodec(temporary);
      codec.importJson(local);
      codec.importJson(remote);
      return codec.exportJson();
    } finally {
      temporary.close();
    }
  }

  /// Applies a complete snapshot with deletion semantics. Validation, source
  /// identity mapping and staging finish before the live transaction begins.
  static void replace(LibraryStore store, String nativeJson) {
    final root = _validatedEnvelope(nativeJson);
    final temporary = LibraryStore.memory();
    try {
      final oldSources = store.sources();
      final incoming = (_section(root, 'images')['servers'] as List)
          .map((value) => SourceConfig.fromJson(_map(value)))
          .toList();
      _seedSources(temporary, oldSources, incoming);
      final codec = BackupCodec(temporary);
      codec.importJson(nativeJson);
      _retainDeviceFields(store, temporary);
      // Also validate the fully mapped outgoing form before touching live data.
      codec.exportJson();
      store.transaction(() {
        final database = store.database;
        for (final table in [
          'memberships',
          'items',
          'folders',
          'artists',
          'history',
        ]) {
          database.execute('DELETE FROM $table');
        }
        database.execute("DELETE FROM portable WHERE key LIKE 'backup.%'");
        database.execute("DELETE FROM sources WHERE mode='booru'");
        for (final source in temporary.sources(AppMode.booru)) {
          store.saveSource(source);
        }
        // Foreign-key parents precede memberships. No progress, downloads,
        // browser state or unrelated portable records are replaced.
        for (final table in [
          'folders',
          'items',
          'memberships',
          'artists',
          'history',
          'portable',
        ]) {
          for (final row in temporary.database.select('SELECT * FROM $table')) {
            final placeholders = List.filled(row.length, '?').join(',');
            database.execute('INSERT INTO $table VALUES ($placeholders)', [
              ...row.values,
            ]);
          }
        }
        for (final source in oldSources.where((s) => s.mode == AppMode.booru)) {
          database.execute('DELETE FROM settings WHERE key=?', [
            'blacklist.${source.id}',
          ]);
        }
        for (final source in temporary.sources(AppMode.booru)) {
          store.setSetting(
            'blacklist.${source.id}',
            temporary.setting('blacklist.${source.id}', ''),
          );
        }
        final selected = temporary.setting('selected.booru', <String>[]);
        store.setSetting('selected.booru', selected);
        store.setSetting('source.booru', (selected as List).firstOrNull);
        final restoredIds = incoming.map((s) => s.canonicalAddress).toSet();
        final activeIds = oldSources
            .where((s) => restoredIds.contains(s.canonicalAddress))
            .map((s) => s.id)
            .toSet();
        final archived = (store.setting('archivedSources', <String>[]) as List)
            .cast<String>()
            .where((id) => !activeIds.contains(id))
            .toList();
        store.setSetting('archivedSources', archived);
      });
    } finally {
      temporary.close();
    }
  }

  static void _seedSources(
    LibraryStore temporary,
    List<SourceConfig> local,
    List<SourceConfig> incoming,
  ) {
    for (final source in local.where((s) => s.mode == AppMode.manga)) {
      temporary.saveSource(source);
    }
    final used = <String, String>{};
    for (final source in incoming) {
      final matches = local
          .where(
            (s) =>
                s.mode == AppMode.booru &&
                s.canonicalAddress == source.canonicalAddress,
          )
          .toList();
      if (matches.length > 1) {
        throw const FormatException('Several local servers share an address.');
      }
      final id = matches.firstOrNull?.id ?? source.id;
      final collision = local.where((s) => s.id == id).firstOrNull;
      if (collision != null &&
          (collision.mode != AppMode.booru ||
              collision.canonicalAddress != source.canonicalAddress)) {
        throw const FormatException(
          'A server identifier belongs to another local connection.',
        );
      }
      if (used.containsKey(id)) {
        throw const FormatException('Server identity mapping is ambiguous.');
      }
      used[id] = source.canonicalAddress;
      temporary.saveSource(
        SourceConfig(
          id: id,
          name: source.name,
          baseUrl: source.baseUrl,
          kind: source.kind,
        ),
      );
    }
  }

  static void _retainDeviceFields(LibraryStore local, LibraryStore temporary) {
    for (final mode in AppMode.values) {
      for (final saved in temporary.items(mode)) {
        final old = local.saved(saved.item.key);
        if (old == null) continue;
        final item = saved.item;
        final payload = item.toJson();
        final metadata = <String, dynamic>{
          for (final key in [
            'backend',
            'sourceSite',
            'files',
            'gallery',
            'raw',
          ])
            if (old.item.metadata.containsKey(key)) key: old.item.metadata[key],
          ...item.metadata,
        };
        payload['metadata'] = metadata;
        payload['pageUrl'] = old.item.pageUrl?.toString();
        payload['pageCount'] = old.item.pageCount;
        if (mode == AppMode.manga) {
          payload['sourceId'] = old.item.sourceId;
          payload['thumbnailUrl'] = old.item.thumbnailUrl?.toString();
          payload['mediaUrl'] = old.item.mediaUrl?.toString();
          payload['width'] = old.item.width;
          payload['height'] = old.item.height;
          payload['mediaType'] = old.item.mediaType;
        }
        temporary.database.execute(
          'UPDATE items SET payload=?,note=? WHERE key=?',
          [
            jsonEncode(payload),
            mode == AppMode.booru ? old.note : saved.note,
            item.key,
          ],
        );
      }
    }
  }

  static Map<String, dynamic> _validatedEnvelope(String text) {
    final validation = LibraryStore.memory();
    try {
      BackupCodec(validation).inspect(text);
    } finally {
      validation.close();
    }
    final root = _map(jsonDecode(text));
    if (root['format'] != 'tegnal-library') {
      throw const FormatException(
        'Drive sync requires a complete library backup.',
      );
    }
    return root;
  }

  static Map<String, dynamic> _section(
    Map<String, dynamic> root,
    String name,
  ) => root[name] as Map<String, dynamic>;
  static Map<String, dynamic> _map(dynamic value) =>
      Map<String, dynamic>.from(value as Map);

  static Object? _canonical(Object? value) {
    if (value is Map<String, dynamic>) {
      final keys = value.keys.toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }

  static bool _hasContent(Object? value) {
    if (value == null) return false;
    if (value is String) return value.isNotEmpty;
    if (value is Map) return value.values.any(_hasContent);
    if (value is List) return value.any(_hasContent);
    return true;
  }
}
