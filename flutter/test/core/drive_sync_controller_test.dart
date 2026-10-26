import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/drive_sync_controller.dart';
import 'package:tegnal/data/backup_codec.dart';
import 'package:tegnal/data/drive_auth.dart';
import 'package:tegnal/data/drive_repository.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/data/sync_snapshot.dart';

class _Auth implements DriveAuth {
  _Auth(this.account);
  final String account;
  @override
  DriveIdentity? identity;
  @override
  bool get configured => true;
  @override
  String? get configurationMessage => null;
  @override
  Future<DriveIdentity> connect() async =>
      identity = DriveIdentity(id: account, email: '$account@example.invalid');
  @override
  Future<bool> restore() async {
    await connect();
    return true;
  }

  @override
  Future<String> accessToken({bool interactive = false}) async => 'fixture';
  @override
  Future<void> disconnect() async => identity = null;
  @override
  void dispose() {}
}

class _History {
  final records = <DriveRevision>[];
  final contents = <String, String>{};
  DriveRevision append(String json, List<String> parents) {
    final revision = DriveRevision(
      id: 'revision-${records.length + 1}',
      parents: List.of(parents),
      checksum: sha256.convert(utf8.encode(json)).toString(),
      modifiedAt: DateTime.utc(
        2026,
        10,
        27,
      ).add(Duration(seconds: records.length)),
      bytes: utf8.encode(json).length,
    );
    records.add(revision);
    contents[revision.id] = json;
    return revision;
  }
}

class _Repository implements DriveRepository {
  _Repository(this.history);
  final _History history;
  bool failRead = false, failPublish = false;
  Completer<void>? readStarted, releaseRead, publishStarted, releasePublish;
  @override
  Future<List<DriveRevision>> revisions() async => List.of(history.records);
  @override
  Future<String> read(DriveRevision revision) async {
    if (failRead) throw const DriveSyncException('Fixture read failure');
    final text = history.contents[revision.id]!;
    if (readStarted != null && !readStarted!.isCompleted) {
      readStarted!.complete();
    }
    await releaseRead?.future;
    return text;
  }

  @override
  Future<DriveRevision> publish(String nativeJson, List<String> parents) async {
    if (failPublish) throw const DriveSyncException('Fixture upload failure');
    if (publishStarted != null && !publishStarted!.isCompleted) {
      publishStarted!.complete();
    }
    await releasePublish?.future;
    return history.append(nativeJson, parents);
  }

  @override
  void dispose() {}
}

class _Device {
  _Device(this.store, this.library, this.sync, this.repository, this.directory);
  final LibraryStore store;
  final AppController library;
  final DriveSyncController sync;
  final _Repository repository;
  final Directory directory;
  String get json => BackupCodec(store).exportJson();
  String get hash => SyncSnapshot.fingerprint(json);
  List<int> get ids =>
      store.items(AppMode.manga).map((saved) => saved.item.id).toList()..sort();
  ContentItem save(int id, {String? title}) {
    final item = ContentItem(
      sourceId: '',
      id: id,
      mode: AppMode.manga,
      title: title ?? 'Work $id',
    );
    store.saveItem(item, savedAt: DateTime.utc(2026, 10, id));
    library.changed();
    return item;
  }

  Future<Map<String, String>> state() async => {
    for (final file
        in await directory
            .list()
            .where((file) => file is File && file.path.contains('/state-'))
            .cast<File>()
            .toList())
      file.path: await file.readAsString(),
  };
  void dispose() {
    sync.dispose();
    library.dispose();
    store.close();
  }
}

void main() {
  late Directory temporary;
  late _History history;
  late List<_Device> devices;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tegnal-sync-test-');
    history = _History();
    devices = [];
  });
  tearDown(() async {
    for (final device in devices.reversed) {
      device.dispose();
    }
    await temporary.delete(recursive: true);
  });
  Future<_Device> device({
    String account = 'account-a',
    Directory? directory,
  }) async {
    final store = LibraryStore.memory();
    final library = AppController(
      store,
      sourceFactory: (_) => throw StateError('Tests remain offline'),
    );
    final repository = _Repository(history);
    final folder =
        directory ?? Directory('${temporary.path}/device-${devices.length}');
    final sync = DriveSyncController(
      library: library,
      stateDirectory: folder,
      auth: _Auth(account),
      repositoryFactory: (_) => repository,
    );
    final result = _Device(store, library, sync, repository, folder);
    devices.add(result);
    await sync.initialize();
    await sync.connect();
    expect(sync.connected, isTrue);
    return result;
  }

  Future<(_Device, _Device)> pair() async {
    final a = await device();
    a.save(1);
    await a.sync.synchronize();
    final b = await device();
    await b.sync.synchronize();
    expect(b.ids, [1]);
    expect(b.sync.error, isNull);
    return (a, b);
  }

  test(
    'first sync uploads complete native JSON and clock-only exports are no-ops',
    () async {
      final a = await device();
      a.save(1);
      final original = a.hash;
      expect(a.sync.autoSync, isFalse);
      await a.sync.synchronize();
      expect(a.sync.error, isNull);
      expect(history.records, hasLength(1));
      expect(history.records.single.parents, isEmpty);
      final snapshot = history.contents.values.single;
      expect((jsonDecode(snapshot) as Map)['format'], 'tegnal-library');
      expect(SyncSnapshot.fingerprint(snapshot), original);
      expect(BackupCodec(a.store).inspect(snapshot), isNotNull);
      expect(a.sync.lastSync, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await a.sync.synchronize();
      expect(history.records, hasLength(1));
      expect(a.sync.conflict, isNull);
    },
  );

  test(
    'clean second device pulls newer library and exactly removes deleted works',
    () async {
      final (a, b) = await pair();
      final old = a.store.items(AppMode.manga).single.item;
      a.library.unsave(old);
      a.save(2);
      await a.sync.synchronize();
      expect(history.records, hasLength(2));
      expect(history.records.last.parents, ['revision-1']);
      await b.sync.synchronize();
      expect(b.sync.error, isNull);
      expect(b.ids, [2]);
      expect(b.hash, a.hash);
      expect(history.records, hasLength(2));
      expect(await b.sync.recoveryCopies(), hasLength(2));
    },
  );

  test(
    'divergent local and Drive edits pause without overwriting either copy',
    () async {
      final (a, b) = await pair();
      a.save(2);
      await a.sync.synchronize();
      b.save(3);
      final before = b.hash;
      final baseline = await b.state();
      await b.sync.synchronize();
      expect(b.sync.conflict, isNotNull);
      expect(b.sync.error, isNull);
      expect(b.hash, before);
      expect(await b.state(), baseline);
      expect(history.records, hasLength(2));
    },
  );

  test(
    'explicit combine retains unique works and Drive wins duplicate metadata',
    () async {
      final (a, b) = await pair();
      a.save(1, title: 'Drive title');
      a.save(2);
      await a.sync.synchronize();
      b.save(1, title: 'Device title');
      b.save(3);
      await b.sync.synchronize();
      expect(b.sync.conflict, isNotNull);
      await b.sync.synchronize(resolution: DriveResolution.combine);
      expect(b.sync.error, isNull);
      expect(b.sync.conflict, isNull);
      expect(b.ids, [1, 2, 3]);
      expect(
        b.store
            .items(AppMode.manga)
            .singleWhere((saved) => saved.item.id == 1)
            .item
            .title,
        'Drive title',
      );
      expect(history.records, hasLength(3));
      expect(history.records.last.parents, ['revision-2']);
      expect(
        SyncSnapshot.fingerprint(history.contents[history.records.last.id]!),
        b.hash,
      );
    },
  );

  test('concurrent sibling uploads conflict and choosing device converges all heads', () async {
    final (a, b) = await pair();
    a.save(2);
    b.save(3);
    b.repository.publishStarted = Completer<void>();
    b.repository.releasePublish = Completer<void>();
    final uploading = b.sync.synchronize();
    await b.repository.publishStarted!.future;
    await a.sync.synchronize();
    b.repository.releasePublish!.complete();
    await uploading;
    expect(history.records, hasLength(3));
    expect(history.records[1].parents, ['revision-1']);
    expect(history.records[2].parents, ['revision-1']);
    expect(DriveSyncController.heads(history.records), hasLength(2));
    await a.sync.synchronize();
    expect(a.sync.conflict!.revisions, hasLength(2));
    await a.sync.synchronize(resolution: DriveResolution.useDevice);
    expect(a.sync.error, isNull);
    expect(a.sync.conflict, isNull);
    expect(
      history.records.last.parents,
      unorderedEquals(['revision-2', 'revision-3']),
    );
    expect(DriveSyncController.heads(history.records), hasLength(1));
    await b.sync.synchronize();
    expect(b.sync.error, isNull);
    expect(b.ids, [1, 2]);
    expect(a.hash, b.hash);
  });

  test(
    'read failure keeps local library and accepted baseline unchanged',
    () async {
      final (a, b) = await pair();
      a.save(2);
      await a.sync.synchronize();
      final before = b.hash;
      final baseline = await b.state();
      b.repository.failRead = true;
      await b.sync.synchronize();
      expect(b.sync.error, 'Fixture read failure');
      expect(b.hash, before);
      expect(await b.state(), baseline);
      expect(history.records, hasLength(2));
    },
  );

  test(
    'upload failure keeps local edits and baseline available for retry',
    () async {
      final a = await device();
      a.save(1);
      await a.sync.synchronize();
      a.save(2);
      final before = a.hash;
      final baseline = await a.state();
      a.repository.failPublish = true;
      await a.sync.synchronize();
      expect(a.sync.error, 'Fixture upload failure');
      expect(a.hash, before);
      expect(await a.state(), baseline);
      expect(history.records, hasLength(1));
      a.repository.failPublish = false;
      await a.sync.synchronize();
      expect(a.sync.error, isNull);
      expect(history.records, hasLength(2));
      expect(a.hash, before);
    },
  );

  test('local edit while awaiting remote read blocks replacement', () async {
    final (a, b) = await pair();
    a.save(2);
    await a.sync.synchronize();
    final baseline = await b.state();
    b.repository.readStarted = Completer<void>();
    b.repository.releaseRead = Completer<void>();
    final reading = b.sync.synchronize();
    await b.repository.readStarted!.future;
    b.save(3);
    final edited = b.hash;
    b.repository.releaseRead!.complete();
    await reading;
    expect(b.sync.error, contains('changed during sync'));
    expect(b.hash, edited);
    expect(b.ids, [1, 3]);
    expect(await b.state(), baseline);
    expect(history.records, hasLength(2));
  });

  test(
    'edits made during upload remain dirty and publish on the next sync',
    () async {
      final a = await device();
      a.save(1);
      a.repository.publishStarted = Completer<void>();
      a.repository.releasePublish = Completer<void>();
      final uploading = a.sync.synchronize();
      await a.repository.publishStarted!.future;
      a.save(2);
      a.repository.releasePublish!.complete();
      await uploading;
      expect(a.sync.error, isNull);
      expect(a.ids, [1, 2]);
      expect(
        SyncSnapshot.fingerprint(history.contents.values.single),
        isNot(a.hash),
      );
      await a.sync.synchronize();
      expect(a.sync.error, isNull);
      expect(history.records, hasLength(2));
      expect(
        SyncSnapshot.fingerprint(history.contents[history.records.last.id]!),
        a.hash,
      );
    },
  );

  test('a different account cannot reuse another account baseline', () async {
    final a = await device();
    a.save(1);
    await a.sync.synchronize();
    final baseline = await a.state();
    // The second account has a conflicting copy of its own Drive library.
    final separate = LibraryStore.memory();
    separate.saveItem(
      const ContentItem(
        sourceId: '',
        id: 2,
        mode: AppMode.manga,
        title: 'Other account',
      ),
    );
    final otherJson = BackupCodec(separate).exportJson();
    separate.close();
    history = _History()..append(otherJson, []);
    final b = await device(account: 'account-b', directory: a.directory);
    b.save(1);
    await b.sync.synchronize();
    expect(b.sync.conflict, isNotNull);
    expect(b.ids, [1]);
    expect(await b.state(), baseline);
    expect(b.sync.accountEmail, 'account-b@example.invalid');
    expect(history.records, hasLength(1));
  });

  test('recovery restore saves current library and disables automatic synchronization', () async {
    final (a, b) = await pair();
    a.save(2);
    await a.sync.synchronize();
    final previous = b.hash;
    await b.sync.synchronize();
    final copy = (await b.sync.recoveryCopies()).first;
    expect(SyncSnapshot.fingerprint(await copy.readAsString()), previous);
    b.save(3);
    final current = b.hash;
    b.sync.setAutoSync(true);
    expect(b.sync.autoSync, isTrue);
    await b.sync.restoreRecovery(copy);
    expect(b.sync.error, isNull);
    expect(b.sync.autoSync, isFalse);
    expect(b.ids, [1]);
    final copies = await b.sync.recoveryCopies();
    expect(copies, hasLength(3));
    expect(
      SyncSnapshot.fingerprint(await copies.first.readAsString()),
      current,
    );
    expect(history.records, hasLength(2));
  });
  test('returning to account A after account B forces review of the changed device library', () async {
    final store = LibraryStore.memory();
    final library = AppController(
      store,
      sourceFactory: (_) => throw StateError('Tests remain offline'),
    );
    final directory = Directory('${temporary.path}/account-switch');
    DriveSyncController? active;
    addTearDown(() {
      active?.dispose();
      library.dispose();
      store.close();
    });
    Future<DriveSyncController> open(String account, _History graph) async {
      active?.dispose();
      final controller = DriveSyncController(
        library: library,
        stateDirectory: directory,
        auth: _Auth(account),
        repositoryFactory: (_) => _Repository(graph),
      );
      active = controller;
      await controller.initialize();
      // Startup restoration is deliberately non-blocking in production.
      while (controller.busy) {
        await Future<void>.delayed(Duration.zero);
      }
      if (!controller.connected) await controller.connect();
      expect(controller.connected, isTrue);
      return controller;
    }

    final a = await open('account-a', history);
    library.save(
      const ContentItem(
        sourceId: '',
        id: 1,
        mode: AppMode.manga,
        title: 'Original',
      ),
    );
    await a.synchronize();
    a.setAutoSync(true);
    final b = await open('account-b', _History());
    expect(b.autoSync, isFalse);
    library.save(
      const ContentItem(
        sourceId: '',
        id: 2,
        mode: AppMode.manga,
        title: 'Changed while using B',
      ),
    );
    b.setAutoSync(true);
    final returned = await open('account-a', history);
    expect(returned.autoSync, isFalse);
    expect(returned.lastSync, isNull);
    await returned.synchronize();
    expect(returned.error, isNull);
    expect(returned.conflict, isNotNull);
    expect(history.records, hasLength(1));
    expect(store.items(AppMode.manga), hasLength(2));
  });

  test(
    'incoming replacements retain only the latest ten local recovery copies',
    () async {
      final (a, b) = await pair();
      for (var id = 2; id <= 13; id++) {
        a.save(id);
        await a.sync.synchronize();
        await b.sync.synchronize();
        expect(b.sync.error, isNull);
      }
      expect(await b.sync.recoveryCopies(), hasLength(10));
      expect(b.ids, List<int>.generate(13, (index) => index + 1));
    },
  );
  test(
    'deleting all synchronized metadata conflicts with concurrent remote edits',
    () async {
      final (a, b) = await pair();
      final baseline = await b.state();
      b.library.unsave(b.store.items(AppMode.manga).single.item);
      expect(SyncSnapshot.isEmpty(b.json), isTrue);
      a.save(2);
      await a.sync.synchronize();
      final emptyHash = b.hash;
      await b.sync.synchronize();
      expect(b.sync.error, isNull);
      expect(b.sync.conflict, isNotNull);
      expect(b.ids, isEmpty);
      expect(b.hash, emptyHash);
      expect(await b.state(), baseline);
      expect(history.records, hasLength(2));
    },
  );

  test('a baseline with numeric head values is ignored and later sync calls remain usable', () async {
    final a = await device();
    a.save(1);
    await a.sync.synchronize();
    final state = await a.state();
    final path = state.keys.single;
    final invalid = jsonDecode(state.values.single) as Map<String, dynamic>;
    invalid['heads'] = {'revision-1': 42};
    await File(path).writeAsString(jsonEncode(invalid));
    final b = await device(directory: a.directory);
    b.save(2);
    expect(b.sync.lastSync, isNull);
    await b.sync.synchronize();
    expect(b.sync.error, isNull);
    expect(b.sync.conflict, isNotNull);
    expect(b.sync.busy, isFalse);
    expect(b.ids, [2]);
    expect(history.records, hasLength(1));
    await b.sync.synchronize(resolution: DriveResolution.useDevice);
    expect(b.sync.error, isNull);
    expect(b.sync.conflict, isNull);
    expect(history.records, hasLength(2));
    await b.sync.synchronize();
    expect(b.sync.error, isNull);
    expect(history.records, hasLength(2));
  });

  test('an existing file at the state-directory path reports an error without blocking the library', () async {
    final path = '${temporary.path}/not-a-directory';
    await File(path).writeAsString('existing file must be preserved');
    final store = LibraryStore.memory();
    final library = AppController(
      store,
      sourceFactory: (_) => throw StateError('Tests remain offline'),
    );
    final auth = _Auth('account-a');
    final sync = DriveSyncController(
      library: library,
      stateDirectory: Directory(path),
      auth: auth,
      repositoryFactory: (_) => _Repository(history),
    );
    addTearDown(() {
      sync.dispose();
      library.dispose();
      store.close();
    });
    await expectLater(sync.initialize(), completes);
    expect(
      sync.error,
      'Unable to sync. Your local library is available; try again.',
    );
    expect(sync.connected, isFalse);
    expect(sync.busy, isFalse);
    expect(auth.identity, isNull);
    library.save(
      const ContentItem(
        sourceId: '',
        id: 7,
        mode: AppMode.manga,
        title: 'Still usable',
      ),
    );
    expect(store.items(AppMode.manga).single.item.title, 'Still usable');
    expect(await File(path).readAsString(), 'existing file must be preserved');
    expect(history.records, isEmpty);
  });
}
