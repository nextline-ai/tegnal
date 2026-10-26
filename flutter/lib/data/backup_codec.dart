import 'dart:convert';

import '../core/content.dart';
import '../core/library.dart';
import 'library_store.dart';

class BackupSummary {
  const BackupSummary({required this.workCount, required this.folderCount});
  final int workCount;
  final int folderCount;
}

/// Native-compatible, metadata-only backup. Every section validates before writes.
class BackupCodec {
  BackupCodec(this.store);
  final LibraryStore store;
  static const maximumBytes = 128 * 1024 * 1024;
  static final _swiftEpoch = DateTime.utc(2001);

  BackupSummary inspect(String text) => _decode(text).summary;

  BackupSummary importJson(String text) {
    final data = _decode(text);
    store.transaction(() {
      if (data.comics case final section?) _importComics(section);
      if (data.images case final section?) _importImages(section);
      if (data.challenges case final section?) {
        final previous = store.portable('backup.challenges');
        final games = <String, dynamic>{
          for (final game in _records(previous?['games'] ?? []))
            game['id'] as String: game,
          for (final game in _records(section['games']))
            game['id'] as String: game,
        };
        store.setPortable('backup.challenges', {
          ...?previous,
          ...section,
          'games': games.values.toList(),
        });
      }
      if (data.extras.isNotEmpty) {
        store.setPortable('backup.extras', {
          ...?store.portable('backup.extras'),
          ...data.extras,
        });
      }
    });
    return data.summary;
  }

  String exportJson() {
    final object = <String, dynamic>{
      ...?store.portable('backup.extras'),
      'format': 'tegnal-library',
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'comics': _exportComics(),
      'images': _exportImages(),
      'challenges':
          store.portable('backup.challenges') ??
          {
            'format': 'tegnal-challenges',
            'schemaVersion': 1,
            'games': <dynamic>[],
          },
    };
    final encoded = const JsonEncoder.withIndent('  ')
        .convert(_safeMap(object));
    _decode(encoded); // Never produce an envelope native readers cannot decode.
    return encoded;
  }

  _Import _decode(String text) {
    _require(
      utf8.encode(text).length <= maximumBytes,
      'Backup exceeds 128 MiB.',
    );
    final root = _map(jsonDecode(text));
    Map<String, dynamic>? comics, images, challenges;
    switch (root['format']) {
      case 'tegnal-library':
        _require(root['version'] == 1, 'Unsupported library backup version.');
        _iso(root['exportedAt']);
        comics = _map(root['comics']);
        images = _map(root['images']);
        challenges = _map(root['challenges']);
      case 'tegnal-image-library' || 'number-memo-image-library':
        _require(
          utf8.encode(text).length <= 64 * 1024 * 1024,
          'Image backup exceeds 64 MiB.',
        );
        images = {...root, 'format': 'tegnal-image-library'};
      case 'tegnal-challenges' || 'number-memo-challenges':
        _require(
          utf8.encode(text).length <= 10 * 1024 * 1024,
          'Challenge backup exceeds 10 MiB.',
        );
        challenges = {...root, 'format': 'tegnal-challenges'};
      case null:
        comics = root;
      default:
        throw const FormatException('Unsupported backup format.');
    }
    if (comics != null) _validateComics(comics);
    if (images != null) _validateImages(images);
    if (challenges != null) _validateChallenges(challenges);
    return _Import(
      comics: comics == null ? null : _safeMap(comics),
      images: images == null ? null : _safeMap(images),
      challenges: challenges == null ? null : _safeMap(challenges),
      extras: root['format'] == 'tegnal-library'
          ? _safeMap({
              for (final entry in root.entries)
                if (!{
                  'format',
                  'version',
                  'exportedAt',
                  'comics',
                  'images',
                  'challenges',
                }.contains(entry.key))
                  entry.key: entry.value,
            })
          : {},
    );
  }

  void _validateComics(Map<String, dynamic> value) {
    _require(
      [1, 2].contains(value['version']),
      'Unsupported comics backup version.',
    );
    final folders = _records(value['folders']);
    _unique(folders.map((v) => _text(v['name'])), 'Duplicate comics folder.');
    final names = folders.map((v) => v['name']).toSet();
    for (final folder in folders) {
      if (folder['id'] != null) _integer(folder['id']);
      _color(folder['color'] ?? 0xFF2563EB);
      if (folder['sort_order'] != null) _integer(folder['sort_order']);
      final legacy = folder.keys
          .where((k) => k != 'source_group_id' && k.endsWith('_group_id'))
          .toList();
      if (folder['source_group_id'] == null && legacy.length == 1) {
        folder['source_group_id'] = folder[legacy.single];
        folder.remove(legacy.single);
      }
      if (folder['source_group_id'] != null) {
        _integer(folder['source_group_id']);
      }
      _optionalStrings(folder, ['description']);
    }
    final works = _records(value['works']);
    _unique(
      works.map((v) => _positive(v['gallery_id'])),
      'Duplicate gallery ID.',
    );
    for (final work in works) {
      if (work['thumb_page'] != null) _positive(work['thumb_page']);
      _optionalStrings(work, [
        'title',
        'artists',
        'note',
        'bookmarked_at',
        'language',
        'type',
        'series',
        'groups',
        'tags',
        'published_at',
      ]);
      if (work['bookmarked_at'] != null) _iso(work['bookmarked_at']);
      _require(
        _strings(work['folders'] ?? []).every(names.contains),
        'Unknown comics folder.',
      );
    }
    final artists = _records(value['artists']);
    _unique(
      artists.map((v) => '${_text(v['name'])}\u0000${_kind(v['kind'] ?? 0)}'),
      'Duplicate artist.',
    );
    for (final artist in artists) {
      _optionalStrings(artist, ['note']);
    }
    for (final record in _records(value['history'] ?? [])) {
      _text(record['query']);
      _unix(record['used_at']);
    }
    for (final query in _strings(value['saved_searches'] ?? [])) {
      _text(query);
    }
    if (value['exported_at'] != null) _iso(value['exported_at']);
  }

  void _validateImages(Map<String, dynamic> value) {
    _require(
      [
            'tegnal-image-library',
            'number-memo-image-library',
          ].contains(value['format']) &&
          value['version'] == 1,
      'Unsupported image backup version.',
    );
    value['format'] = 'tegnal-image-library';
    _swift(value['exportedAt']);
    final sources = _records(value['servers']);
    final ids = <String>{}, origins = <String>{};
    for (final source in sources) {
      final id = _text(source['id']);
      _require(ids.add(id), 'Duplicate server ID.');
      _text(source['name']);
      _require(
        SourceKind.values.any((kind) => kind.name == source['engine']),
        'Unsupported server engine.',
      );
      final config = SourceConfig.fromJson(source);
      _require(
        config.mode == AppMode.booru && origins.add(_canonical(config.baseUrl)),
        'Duplicate or unsupported image server.',
      );
    }
    final folders = _records(value['folders']);
    final folderIds = <String>{};
    for (final folder in folders) {
      final id = _text(folder['id']);
      _require(folderIds.add(id), 'Duplicate image folder.');
      if (id != 'unsorted') {
        _text(folder['name']);
      } else {
        _string(folder['name']);
      }
      _color(folder['color']);
    }
    final postIds = <String>{};
    for (final favorite in _records(value['favorites'])) {
      final post = _map(favorite['post']);
      final server = _text(post['serverID']);
      final id = _positive(post['postID']);
      _require(
        ids.contains(server) &&
            folderIds.contains(favorite['folderID']) &&
            postIds.add('$server:$id'),
        'Invalid favorite reference or duplicate.',
      );
      _unix(favorite['savedAt']);
      for (final key in ['width', 'height', 'score']) {
        _integer(post[key]);
      }
      _strings(post['tags']);
      _strings(post['artists']);
      _string(post['rating']);
      _string(post['fileExtension']);
      for (final id in _list(post['poolIDs'])) {
        _integer(id);
      }
      for (final key in [
        'previewURL',
        'sampleURL',
        'fileURL',
        'reducedDataURL',
      ]) {
        if (post[key] != null) _remote(post[key]);
      }
      for (final key in ['favoriteCount', 'upvoteCount', 'commentCount']) {
        if (post[key] != null) _integer(post[key]);
      }
      if (post['metadataTags'] != null) _strings(post['metadataTags']);
      if (post['tagCategories'] != null) {
        for (final v in _map(post['tagCategories']).values) {
          _integer(v);
        }
      }
      if (post['animated'] != null) {
        _require(post['animated'] is bool, 'Invalid animation flag.');
      }
    }
    for (final history in _records(value['history'])) {
      _require(ids.contains(history['serverID']), 'Unknown history server.');
      _text(history['query']);
      _unix(history['usedAt']);
    }
    for (final tag in _records(value['savedTags'])) {
      _require(
        ids.contains(tag['serverID']) &&
            ['tag', 'artist', 'search'].contains(tag['kind']),
        'Invalid saved tag.',
      );
      _text(tag['name']);
    }
    for (final entry in _map(value['blacklist']).entries) {
      _require(ids.contains(entry.key), 'Unknown blacklist server.');
      _string(entry.value);
    }
    _require(
      _strings(value['selectedServerIDs']).every(ids.contains),
      'Unknown selected server.',
    );
  }

  void _validateChallenges(Map<String, dynamic> value) {
    _require(
      [
            'tegnal-challenges',
            'number-memo-challenges',
          ].contains(value['format']) &&
          value['schemaVersion'] == 1,
      'Unsupported challenge backup version.',
    );
    value['format'] = 'tegnal-challenges';
    final games = _records(value['games']);
    _require(games.length <= 200, 'Too many challenges.');
    _unique(games.map((g) => _text(g['id'], max: 128)), 'Duplicate challenge.');
    for (final game in games) {
      _text(game['title'], max: 200);
      _boundedString(game['detail'], 4000);
      final reels = _records(game['reels']), groups = _records(game['groups']);
      _require(
        reels.length == 2 && groups.length <= 12,
        'Invalid challenge reels.',
      );
      final all = [...reels, ...groups];
      _unique(
        all.map((g) => _text(g['id'], max: 128)),
        'Duplicate challenge group.',
      );
      for (final group in all) {
        _text(group['title'], max: 200);
        _boundedString(group['filter'], 200);
        final options = _records(group['options']);
        _require(
          options.isNotEmpty && options.length <= 1000,
          'Invalid draw options.',
        );
        _unique(
          options.map((o) => _text(o['id'], max: 128)),
          'Duplicate draw option.',
        );
        var eligible = false;
        for (final option in options) {
          _text(option['text']);
          _boundedString(option['group'], 200);
          _rangeInt(option['weight'], 1, 10000);
          _require(option['enabled'] is bool, 'Invalid enabled flag.');
          eligible |=
              option['enabled'] == true &&
              (group['filter'] == '' || group['filter'] == option['group']);
          final tags = _strings(option['tags']);
          _require(
            tags.length <= 20 &&
                tags.every(
                  (tag) =>
                      tag.isNotEmpty &&
                      tag.length <= 128 &&
                      !RegExp(r'[\s:{}]').hasMatch(tag) &&
                      !tag.startsWith('-') &&
                      !tag.startsWith('~'),
                ),
            'Invalid atomic search tag.',
          );
        }
        _require(eligible, 'Challenge group has no eligible options.');
      }
      final goal = _map(game['goal']);
      _require(
        ['time', 'count', 'mixed'].contains(goal['mode']),
        'Invalid challenge goal.',
      );
      for (final (key, limit) in [('time', 86400), ('count', 10000)]) {
        final range = _map(goal[key]);
        final min = _rangeInt(range['minimum'], 1, limit),
            max = _rangeInt(range['maximum'], min, limit);
        final step = _rangeInt(range['step'], 1, limit);
        _require((max - min) % step == 0, 'Invalid goal step.');
      }
      _rangeInt(goal['timeWeight'], 1, 10000);
      _rangeInt(goal['countWeight'], 1, 10000);
      final target = _rangeInt(game['target'], 1, 100000);
      _require(
        [0.5, 1, 1.5, 2].contains(game['multiplier']),
        'Invalid score multiplier.',
      );
      final bands = _records(game['bands']);
      _require(bands.isNotEmpty && bands.length <= 100, 'Invalid score bands.');
      _unique(
        bands.map((b) => _text(b['id'], max: 128)),
        'Duplicate score band.',
      );
      var through = -1;
      for (final band in bands) {
        through = _rangeInt(band['through'], through + 1, 100000);
        final min = _rangeInt(band['minimum'], 1, 100000);
        _rangeInt(band['maximum'], min, 100000);
      }
      _require(through >= target - 1, 'Score bands do not cover target.');
      final endings = _records(game['endings']);
      _require(endings.isNotEmpty && endings.length <= 100, 'Invalid endings.');
      _unique(
        endings.map((e) => _text(e['id'], max: 128)),
        'Duplicate ending.',
      );
      for (final ending in endings) {
        _text(ending['title'], max: 200);
        _boundedString(ending['detail'], 4000);
        _boundedString(ending['badge'], 40);
        _rangeInt(ending['weight'], 1, 10000);
        _require(
          [
            'purple',
            'pink',
            'green',
            'orange',
            'blue',
          ].contains(ending['color']),
          'Invalid ending color.',
        );
      }
      _require(
        game['fixedEndingID'] == null ||
            endings.any((e) => e['id'] == game['fixedEndingID']),
        'Unknown fixed ending.',
      );
      final help = _records(game['helpPages'] ?? []);
      _require(help.length <= 12, 'Too many help pages.');
      _unique(
        help.map((p) => _text(p['id'], max: 128)),
        'Duplicate help page.',
      );
      for (final page in help) {
        _require(page['id'] != 'overview', 'Reserved help page ID.');
        _text(page['title'], max: 200);
        _text(page['body'], max: 16000);
      }
      final template = _text(game['template']);
      final variables = {
        'reel1',
        'reel2',
        'goal',
        for (var i = 0; i < groups.length; i++) 'extra${i + 1}',
      };
      final pattern = RegExp(r'\{([^{}]*)\}');
      _require(
        pattern
                .allMatches(template)
                .every((m) => variables.contains(m.group(1))) &&
            !template.replaceAll(pattern, '').contains(RegExp(r'[{}]')),
        'Invalid mission variables.',
      );
    }
  }

  void _importComics(Map<String, dynamic> section) {
    final previous = store.portable('backup.comics') ?? {};
    final existingFolders = store.folders(AppMode.manga);
    final mapping = <String, String>{};
    final records = _records(section['folders']);
    final ordered = records.toList()
      ..sort(
        (a, b) => ((a['sort_order'] as int?) ?? records.indexOf(a)).compareTo(
          (b['sort_order'] as int?) ?? records.indexOf(b),
        ),
      );
    final folderMetadata = _map(previous['folderMetadata'] ?? {});
    for (final (position, folder) in ordered.indexed) {
      final name = folder['name'] as String;
      final existing = existingFolders.where((f) => f.name == name).firstOrNull;
      final id = existing?.id ?? _folderId(AppMode.manga, name);
      mapping[name] = id;
      store.saveFolder(
        LibraryFolder(
          id: id,
          mode: AppMode.manga,
          name: name,
          color: folder['color'] as int? ?? existing?.color ?? 0xFF2563EB,
          position: position,
        ),
      );
      folderMetadata[id] = {
        ...?_nullableMap(folderMetadata[id]),
        for (final entry in folder.entries)
          if (entry.value != null) entry.key: entry.value,
      };
    }
    var position = ordered.length;
    for (final folder in existingFolders.where(
      (f) => !mapping.values.contains(f.id),
    )) {
      store.saveFolder(
        LibraryFolder(
          id: folder.id,
          mode: folder.mode,
          name: folder.name,
          color: folder.color,
          position: position++,
        ),
      );
    }
    final source = store.sources(AppMode.manga).firstOrNull?.id ?? '';
    final existingItems = {
      for (final saved in store.items(AppMode.manga)) saved.item.id: saved,
    };
    for (final record in _records(section['works'])) {
      final id = record['gallery_id'] as int;
      final old = existingItems[id];
      final merged = {
        ...?_nullableMap(old?.item.metadata['nativeBackup']),
        for (final key in [
          'language',
          'type',
          'series',
          'groups',
          'published_at',
          'thumb_page',
        ])
          if (old?.item.metadata[key] != null) key: old!.item.metadata[key],
        for (final entry in record.entries)
          if (entry.value != null) entry.key: entry.value,
      }..remove('nativeBackup');
      final item = ContentItem(
        sourceId: old?.item.sourceId ?? source,
        id: id,
        mode: AppMode.manga,
        title: record['title'] as String? ?? old?.item.title ?? '#$id',
        thumbnailUrl: old?.item.thumbnailUrl,
        mediaUrl: old?.item.mediaUrl,
        pageUrl: old?.item.pageUrl,
        tags: record['tags'] == null
            ? old?.item.tags ?? []
            : _csv(record['tags']),
        artists: record['artists'] == null
            ? old?.item.artists ?? []
            : _csv(record['artists']),
        pageCount: old?.item.pageCount ?? 0,
        metadata: {...merged, 'nativeBackup': merged},
      );
      store.saveItem(
        item,
        folderIds: {
          ...?old?.folderIds,
          ..._strings(record['folders'] ?? []).map((name) => mapping[name]!),
        }.toList(),
        note: record['note'] as String? ?? old?.note,
        savedAt: record['bookmarked_at'] == null
            ? old?.savedAt
            : _iso(record['bookmarked_at']),
      );
    }
    for (final artist in _records(section['artists'])) {
      final old = store
          .artists(AppMode.manga)
          .where(
            (a) => a.name == artist['name'] && a.kind == (artist['kind'] ?? 0),
          )
          .firstOrNull;
      store.saveArtist(
        ArtistEntry(
          name: artist['name'] as String,
          mode: AppMode.manga,
          sourceId: old?.sourceId ?? source,
          kind: artist['kind'] as int? ?? 0,
          note: artist['note'] as String? ?? old?.note ?? '',
        ),
      );
    }
    for (final history in _records(section['history'] ?? [])) {
      store.recordSearch(
        AppMode.manga,
        source,
        history['query'] as String,
        usedAt: _unix(history['used_at']),
      );
    }
    store.setPortable('backup.comics', {
      ...previous,
      ...section,
      'folderMetadata': folderMetadata,
      'saved_searches': {
        ..._strings(previous['saved_searches'] ?? []),
        ..._strings(section['saved_searches'] ?? []),
      }.toList(),
    });
  }

  void _importImages(Map<String, dynamic> section) {
    final previous = store.portable('backup.images') ?? {};
    final mapping = <String, String>{};
    final sourceMetadata = _map(previous['sourceMetadata'] ?? {});
    for (final record in _records(section['servers'])) {
      final source = SourceConfig.fromJson(record);
      final existing = store
          .sources(AppMode.booru)
          .where((s) => _canonical(s.baseUrl) == _canonical(source.baseUrl))
          .firstOrNull;
      var id = existing?.id ?? source.id;
      if (existing == null) {
        var suffix = 1;
        final used = store.sources().map((s) => s.id).toSet();
        while (used.contains(id)) {
          id = '${source.id}-import-${suffix++}';
        }
        store.saveSource(
          SourceConfig(
            id: id,
            name: source.name,
            baseUrl: source.baseUrl,
            kind: source.kind,
          ),
        );
      }
      mapping[source.id] = id;
      sourceMetadata[id] = {
        ...?_nullableMap(sourceMetadata[id]),
        ...record,
        'id': id,
      };
    }
    final archived = (store.setting(
      'archivedSources',
      <String>[],
    ) as List).cast<String>().toSet()..removeAll(mapping.values);
    store.setSetting('archivedSources', archived.toList());
    final folderMap = <String, String>{};
    final folderMetadata = _map(previous['folderMetadata'] ?? {});
    final oldFolders = store.folders(AppMode.booru);
    for (final (position, record) in _records(section['folders']).indexed) {
      final original = record['id'] as String;
      final existing = oldFolders
          .where(
            (f) =>
                _nullableMap(folderMetadata[f.id])?['nativeID'] == original ||
                f.id == original,
          )
          .firstOrNull;
      final id = existing?.id ?? _folderId(AppMode.booru, original);
      folderMap[original] = id;
      store.saveFolder(
        LibraryFolder(
          id: id,
          mode: AppMode.booru,
          name: original == 'unsorted'
              ? 'Uncategorized'
              : record['name'] as String,
          color: record['color'] as int,
          position: position,
        ),
      );
      folderMetadata[id] = {...record, 'nativeID': original};
    }
    var position = folderMap.length;
    for (final folder in oldFolders.where(
      (f) => !folderMap.values.contains(f.id),
    )) {
      store.saveFolder(
        LibraryFolder(
          id: folder.id,
          mode: folder.mode,
          name: folder.name,
          color: folder.color,
          position: position++,
        ),
      );
    }
    for (final record in _records(section['favorites'])) {
      final post = {..._map(record['post'])};
      final source = mapping[post['serverID']]!;
      post['serverID'] = source;
      final id = post['postID'] as int;
      final item = ContentItem(
        sourceId: source,
        id: id,
        mode: AppMode.booru,
        title: post['title'] as String? ?? '#$id',
        thumbnailUrl: _optionalUri(post['previewURL']),
        mediaUrl: _optionalUri(post['sampleURL'] ?? post['fileURL']),
        tags: _strings(post['tags']),
        artists: _strings(post['artists']),
        width: post['width'] as int,
        height: post['height'] as int,
        score: post['score'] as int,
        mediaType: ['mp4', 'webm', 'mov', 'm4v'].contains(post['fileExtension'])
            ? 'video'
            : 'image',
        metadata: {...post, 'nativeBackup': post, 'nativeFavorite': record},
      );
      store.saveItem(
        item,
        folderIds: [folderMap[record['folderID']]!],
        savedAt: _unix(record['savedAt']),
      );
    }
    for (final record in _records(section['history'])) {
      store.recordSearch(
        AppMode.booru,
        mapping[record['serverID']]!,
        record['query'] as String,
        usedAt: _unix(record['usedAt']),
      );
    }
    final savedTags = <String, Map<String, dynamic>>{};
    for (final record in [
      ..._records(previous['savedTags'] ?? []),
      ..._records(section['savedTags'])
          .map((r) => {...r, 'serverID': mapping[r['serverID']]!}),
    ]) {
      savedTags[jsonEncode([
            record['serverID'],
            record['kind'],
            record['name'],
          ])] =
          record;
    }
    for (final entry in _map(section['blacklist']).entries) {
      store.setSetting('blacklist.${mapping[entry.key]!}', entry.value);
    }
    final selected = _strings(section['selectedServerIDs'])
        .map((id) => mapping[id]!)
        .toList();
    if (selected.isNotEmpty) {
      store.setSetting('selected.booru', selected);
      store.setSetting('source.booru', selected.first);
    }
    for (final record in _records(section['savedTags'])) {
      if (record['kind'] == 'search') continue;
      final sourceId = mapping[record['serverID']]!;
      final kind = record['kind'] == 'artist' ? 0 : 1;
      final existing = store
          .artists(AppMode.booru)
          .where(
            (a) =>
                a.sourceId == sourceId &&
                a.kind == kind &&
                a.name == record['name'],
          )
          .firstOrNull;
      store.saveArtist(
        ArtistEntry(
          name: record['name'] as String,
          mode: AppMode.booru,
          sourceId: sourceId,
          kind: kind,
          note: record['note'] is String
              ? record['note'] as String
              : existing?.note ?? '',
        ),
      );
    }
    store.setPortable('backup.images', {
      ...previous,
      ...section,
      'folderMetadata': folderMetadata,
      'sourceMetadata': sourceMetadata,
      'savedTags': savedTags.values.toList(),
      'blacklist': {
        ..._map(previous['blacklist'] ?? {}),
        for (final entry in _map(section['blacklist']).entries)
          mapping[entry.key]!: entry.value,
      },
      'selectedServerIDs': _strings(section['selectedServerIDs']).isEmpty
          ? _strings(previous['selectedServerIDs'] ?? [])
          : _strings(section['selectedServerIDs'])
                .map((id) => mapping[id]!)
                .toList(),
    });
  }

  Map<String, dynamic> _exportComics() {
    final old = store.portable('backup.comics') ?? {};
    final folders = store.folders(AppMode.manga);
    final metadata = _map(old['folderMetadata'] ?? {});
    final names = {for (final f in folders) f.id: f.name};
    return {
      ...old,
      'version': 2,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'folders': [
        for (final (index, f) in folders.indexed)
          {
            ...?_nullableMap(metadata[f.id]),
            'id': index + 1,
            'name': f.name,
            'color': f.color,
            'sort_order': f.position,
          },
      ],
      'works': [
        for (final saved in store.items(AppMode.manga))
          {
            ...?_nullableMap(saved.item.metadata['nativeBackup']),
            for (final key in [
              'language',
              'type',
              'series',
              'groups',
              'published_at',
              'thumb_page',
            ])
              if (saved.item.metadata[key] != null)
                key: saved.item.metadata[key],
            'gallery_id': saved.item.id,
            'title': saved.item.title,
            'artists': saved.item.artists.join(', '),
            'tags': saved.item.tags.join(', '),
            'note': saved.note,
            'bookmarked_at': saved.savedAt.toUtc().toIso8601String(),
            'folders': [
              for (final id in saved.folderIds)
                if (names.containsKey(id)) names[id],
            ],
          },
      ],
      'artists': [
        for (final artist in store.artists(AppMode.manga))
          {'name': artist.name, 'kind': artist.kind, 'note': artist.note},
      ],
      'history': [
        for (final entry in store.history(AppMode.manga, limit: null))
          {
            'query': entry.query,
            'used_at': entry.usedAt.microsecondsSinceEpoch / 1000000,
          },
      ],
      'saved_searches': _strings(old['saved_searches'] ?? []),
    }..remove('folderMetadata');
  }

  Map<String, dynamic> _exportImages() {
    final old = store.portable('backup.images') ?? {};
    final sources = store.sources(AppMode.booru);
    final sourceIDs = sources.map((s) => s.id).toSet();
    final folders = store.folders(AppMode.booru);
    final metadata = _map(old['folderMetadata'] ?? {});
    final folderIds = {
      for (final f in folders)
        f.id: (_nullableMap(metadata[f.id])?['nativeID'] ?? f.id) as String,
    };
    final favorites = store.items(AppMode.booru);
    final needsUnsorted = favorites.any((s) => s.folderIds.isEmpty);
    final exportedFolders = <Map<String, dynamic>>[
      for (final f in folders)
        {
          ...?_nullableMap(metadata[f.id]),
          'id': folderIds[f.id],
          'name': folderIds[f.id] == 'unsorted' ? '' : f.name,
          'color': f.color,
        }..remove('nativeID'),
    ];
    if (needsUnsorted && !exportedFolders.any((f) => f['id'] == 'unsorted')) {
      exportedFolders.add({'id': 'unsorted', 'name': '', 'color': 0xFF5E5CE6});
    }
    return {
        ...old,
        'format': 'tegnal-image-library',
        'version': 1,
        'exportedAt':
            DateTime.now().toUtc().difference(_swiftEpoch).inMicroseconds /
            1000000,
        'servers': [
          for (final source in sources)
            {
              ...?_nullableMap(_map(old['sourceMetadata'] ?? {})[source.id]),
              ...source.toJson(),
            },
        ],
        'folders': exportedFolders,
        'favorites': [
          for (final saved in favorites)
            {
              ...?_nullableMap(saved.item.metadata['nativeFavorite']),
              'post': _exportPost(saved.item),
              'folderID': saved.folderIds.isEmpty
                  ? 'unsorted'
                  : folderIds[saved.folderIds.first],
              'savedAt': saved.savedAt.microsecondsSinceEpoch / 1000000,
            },
        ],
        'history': [
          for (final h in store.history(AppMode.booru, limit: null))
            if (sourceIDs.contains(h.sourceId))
              {
                'serverID': h.sourceId,
                'query': h.query,
                'usedAt': h.usedAt.microsecondsSinceEpoch / 1000000,
              },
        ],
        'savedTags': [
          ..._records(old['savedTags'] ?? []).where(
            (r) => r['kind'] == 'search' && sourceIDs.contains(r['serverID']),
          ),
          for (final artist in store.artists(AppMode.booru))
            if (sourceIDs.contains(artist.sourceId))
              {
                ...?_records(old['savedTags'] ?? [])
                    .where(
                      (r) =>
                          r['serverID'] == artist.sourceId &&
                          r['name'] == artist.name &&
                          r['kind'] == (artist.kind == 0 ? 'artist' : 'tag'),
                    )
                    .firstOrNull,
                'serverID': artist.sourceId,
                'name': artist.name,
                'kind': artist.kind == 0 ? 'artist' : 'tag',
                if (artist.note.isNotEmpty) 'note': artist.note,
              },
        ],
        'blacklist': {
          for (final source in sources)
            source.id: store.setting(
              'blacklist.${source.id}',
              _map(old['blacklist'] ?? {})[source.id] ?? '',
            ),
        },
        'selectedServerIDs': _strings(
          store.setting('selected.booru', old['selectedServerIDs'] ?? []),
        ).where(sourceIDs.contains).toList(),
      }
      ..remove('folderMetadata')
      ..remove('sourceMetadata');
  }

  Map<String, dynamic> _exportPost(ContentItem item) => {
    ...?_nullableMap(item.metadata['nativeBackup']),
    for (final key in [
      'rating',
      'fileExtension',
      'poolIDs',
      'metadataTags',
      'favoriteCount',
      'upvoteCount',
      'commentCount',
      'reducedDataURL',
      'tagCategories',
      'animated',
    ])
      if (item.metadata[key] != null) key: item.metadata[key],
    'serverID': item.sourceId,
    'postID': item.id,
    'title': item.title,
    'width': item.width,
    'height': item.height,
    'tags': item.tags,
    'artists': item.artists,
    'score': item.score,
    'rating': item.metadata['rating'] ?? '',
    'fileExtension':
        item.metadata['fileExtension'] ??
        (item.mediaUrl?.path.split('.').last ?? ''),
    'poolIDs': item.metadata['poolIDs'] ?? [],
    if (_isRemote(item.thumbnailUrl))
      'previewURL': item.thumbnailUrl.toString(),
    if (_isRemote(item.mediaUrl)) 'sampleURL': item.mediaUrl.toString(),
    if (_isRemote(_optionalUri(item.metadata['fileURL'])))
      'fileURL': item.metadata['fileURL'],
  };

  String _folderId(AppMode mode, String value) {
    final base = '${mode.name}:${Uri.encodeComponent(value)}';
    final existing = [
      ...store.folders(AppMode.manga),
      ...store.folders(AppMode.booru),
    ].map((f) => f.id).toSet();
    var result = base, suffix = 1;
    while (existing.contains(result)) {
      result = '$base-import-${suffix++}';
    }
    return result;
  }

  static String _canonical(Uri uri) {
    var host = uri.host.toLowerCase();
    if ({
      'www.gelbooru.com',
      'www.safebooru.org',
      'www.danbooru.donmai.us',
    }.contains(host)) {
      host = host.substring(4);
    }
    var path = uri.path
        .replaceFirst(RegExp(r'/index\.php/?$'), '')
        .replaceFirst(RegExp(r'/+$'), '');
    return Uri(
      scheme: 'https',
      host: host,
      port: uri.hasPort && uri.port != 443 ? uri.port : null,
      path: path,
    ).toString();
  }

  static Map<String, dynamic> _map(dynamic v) {
    _require(
      v is Map && v.keys.every((key) => key is String),
      'Expected a JSON object.',
    );
    return v is Map<String, dynamic> ? v : Map<String, dynamic>.from(v as Map);
  }

  static Map<String, dynamic>? _nullableMap(dynamic v) =>
      v is Map<String, dynamic> ? v : null;
  static List<dynamic> _list(dynamic v) {
    _require(v is List, 'Expected a JSON array.');
    return v as List;
  }

  static List<Map<String, dynamic>> _records(dynamic v) =>
      _list(v).map(_map).toList();
  static List<String> _strings(dynamic v) => _list(v).map(_string).toList();
  static String _string(dynamic v) {
    _require(v is String, 'Expected text.');
    return v as String;
  }

  static String _text(dynamic v, {int max = 4000}) {
    final s = _string(v);
    _require(s.trim().isNotEmpty && s.length <= max, 'Invalid or empty text.');
    return s;
  }

  static void _boundedString(dynamic v, int max) {
    _require(_string(v).length <= max, 'Text exceeds its limit.');
  }

  static int _integer(dynamic v) {
    _require(v is int, 'Expected an integer.');
    return v as int;
  }

  static int _positive(dynamic v) => _rangeInt(v, 1, 0x7FFFFFFFFFFFFFFF);
  static int _rangeInt(dynamic v, int min, int max) {
    final n = _integer(v);
    _require(n >= min && n <= max, 'Integer is out of range.');
    return n;
  }

  static void _color(dynamic v) => _rangeInt(v, 0, 0xFFFFFFFF);
  static int _kind(dynamic v) => _rangeInt(v, 0, 1);
  static void _unique(Iterable<Object> values, String error) {
    final all = values.toList();
    _require(all.toSet().length == all.length, error);
  }

  static DateTime _iso(dynamic v) {
    final d = DateTime.tryParse(_string(v));
    _require(d != null, 'Invalid date.');
    return d!.toUtc();
  }

  static DateTime _unix(dynamic v) {
    _require(v is num && v.isFinite, 'Invalid timestamp.');
    final micros = (v as num) * 1000000;
    _require(micros.abs() <= 8640000000000000000, 'Timestamp is out of range.');
    return DateTime.fromMicrosecondsSinceEpoch(micros.round(), isUtc: true);
  }

  static DateTime _swift(dynamic v) =>
      _swiftEpoch.add(_unix(v).difference(DateTime.utc(1970)));
  static List<String> _csv(dynamic v) =>
      _string(v)
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
  static Uri? _optionalUri(dynamic v) => v is String ? Uri.tryParse(v) : null;
  static bool _isRemote(Uri? uri) =>
      uri != null &&
      ['https', 'http'].contains(uri.scheme) &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
  static void _remote(dynamic v) {
    _require(_isRemote(_optionalUri(_string(v))), 'Invalid media URL.');
  }

  static void _optionalStrings(Map<String, dynamic> value, List<String> keys) {
    for (final key in keys) {
      if (value[key] != null) _string(value[key]);
    }
  }

  static void _require(bool condition, String message) {
    if (!condition) throw FormatException(message);
  }

  // Unknown portable metadata survives, but device state and secrets never do.
  static Map<String, dynamic> _safeMap(Map<String, dynamic> input) => {
    for (final entry in input.entries)
      if (!_privateKey(entry.key)) entry.key: _safeValue(entry.value),
  };
  static dynamic _safeValue(dynamic value) {
    if (value is Map<String, dynamic>) return _safeMap(value);
    if (value is List) return value.map(_safeValue).toList();
    if (value is String &&
        (value.startsWith('file:') ||
            value.startsWith('data:') ||
            value.startsWith('/Users/') ||
            value.startsWith('/data/user/'))) {
      return null;
    }
    return value;
  }

  static bool _privateKey(String key) => {
    'raw',
    'credentials',
    'password',
    'apikey',
    'accesstoken',
    'refreshtoken',
    'token',
    'cookie',
    'cookies',
    'authorization',
    'headers',
    'localpath',
    'thumbpath',
    'cachepath',
    'mediapath',
    'downloadpath',
    'settings',
    'preferences',
    'downloads',
    'sessions',
    'foldermetadata',
    'nativeid',
  }.contains(key.toLowerCase().replaceAll(RegExp(r'[_-]'), ''));
}

class _Import {
  const _Import({
    this.comics,
    this.images,
    this.challenges,
    this.extras = const {},
  });
  final Map<String, dynamic>? comics, images, challenges;
  final Map<String, dynamic> extras;
  BackupSummary get summary => BackupSummary(
    workCount:
        ((comics?['works'] as List?)?.length ?? 0) +
        ((images?['favorites'] as List?)?.length ?? 0),
    folderCount:
        ((comics?['folders'] as List?)?.length ?? 0) +
        ((images?['folders'] as List?)?.length ?? 0),
  );
}
