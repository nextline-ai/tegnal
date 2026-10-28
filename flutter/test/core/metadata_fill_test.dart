import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/library_store.dart';

class _MetadataSource implements ContentSource {
  _MetadataSource(this.id);
  final String id;
  final calls = <int>[];
  int active = 0, maximumActive = 0;
  Future<ContentItem> Function(int)? respond;
  ContentItem item(int work) => ContentItem(
    sourceId: id,
    id: work,
    mode: AppMode.manga,
    title: 'Fetched $work',
    thumbnailUrl: Uri.https('images.invalid', '/$work.jpg'),
    pageUrl: Uri.https('source.invalid', '/reader/$work.html'),
    tags: const ['tag'],
    artists: const ['artist'],
  );
  @override
  Future<ContentItem> detail(int work) async {
    calls.add(work);
    active++;
    if (active > maximumActive) maximumActive = active;
    try {
      return await (respond?.call(work) ?? Future.value(item(work)));
    } finally {
      active--;
    }
  }

  @override
  Future<List<ReaderPage>> pages(ContentItem item) async => [];
  @override
  Future<ContentPage> search(
    String query, {
    int page = 1,
    bool popular = false,
  }) async => const ContentPage([], hasMore: false);
  @override
  Future<List<String>> suggestions(String query) async => [];
  @override
  void close() {}
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 400; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Metadata state did not settle.');
}

void main() {
  late LibraryStore store;
  late AppController controller;
  late _MetadataSource source;
  setUp(() {
    store = LibraryStore.memory();
    controller = AppController(
      store,
      sourceFactory: (config) => source = _MetadataSource(config.id),
    );
  });
  tearDown(() {
    controller.dispose();
    store.close();
  });

  void placeholder(int id) => store.saveItem(
    ContentItem(sourceId: '', id: id, mode: AppMode.manga, title: '#$id'),
    savedAt: DateTime.utc(2024, 1, id),
  );
  void connect() {
    final config = controller.addSource(
      'https://source.invalid',
      SourceKind.manga,
    );
    controller.client(config);
  }

  test(
    'successful import starts newest-first enrichment and cover warming once',
    () async {
      connect();
      placeholder(1);
      placeholder(2);
      final cached = <int>[];
      controller.setMetadataCoverCache((item) async {
        cached.add(item.id);
      });
      controller.libraryRestored(fillMissingMetadata: true);
      await _until(
        () =>
            controller.metadataFillCompleted == 2 &&
            !controller.metadataFillRunning,
      );
      expect(source.calls, [2, 1]);
      expect(cached, [2, 1]);
      expect(source.maximumActive, 1);
      expect(store.saved('manga:1')!.item.title, 'Fetched 1');
      expect(store.setting('metadata.fillPending'), false);
      expect(controller.metadataFillNoticeVisible, false);
      expect(
        controller.taste.historyOpens(AppMode.manga, since: DateTime.utc(2020)),
        isEmpty,
      );
    },
  );

  test(
    'missing source is visible and resumes when the user connects one',
    () async {
      placeholder(1);
      controller.libraryRestored(fillMissingMetadata: true);
      await _until(() => controller.metadataFillWaitingForSource);
      expect(controller.metadataFillNoticeVisible, true);
      expect(store.sources(), isEmpty);
      expect(store.setting('metadata.fillPending'), true);
      connect();
      await _until(
        () =>
            controller.metadataFillCompleted == 1 &&
            !controller.metadataFillRunning,
      );
      expect(source.calls, [1]);
      expect(controller.metadataFillWaitingForSource, false);
      expect(store.saved('manga:1')!.item.tags, ['tag']);
    },
  );

  test('pause and immediate resume serialize outstanding requests', () async {
    connect();
    placeholder(1);
    final first = Completer<ContentItem>(), second = Completer<ContentItem>();
    source.respond = (_) =>
        source.calls.length == 1 ? first.future : second.future;
    final initial = controller.fillMissingMetadata();
    await _until(() => source.calls.length == 1);
    controller.pauseMetadataFill();
    final resumed = controller.fillMissingMetadata();
    expect(identical(initial, resumed), true);
    expect(source.calls, [1]);
    first.complete(source.item(1));
    await _until(() => source.calls.length == 2);
    expect(store.saved('manga:1')!.item.title, '#1');
    second.complete(source.item(1));
    await _until(
      () =>
          controller.metadataFillCompleted == 1 &&
          !controller.metadataFillRunning,
    );
    expect(source.maximumActive, 1);
    expect(store.saved('manga:1')!.item.title, 'Fetched 1');
  });

  test(
    'backgrounding persists an unfinished cover and resumes it in foreground',
    () async {
      connect();
      placeholder(1);
      var covers = 0;
      final cover = Completer<void>();
      controller.setMetadataCoverCache((_) {
        covers++;
        return covers == 1 ? cover.future : Future.value();
      });
      final run = controller.fillMissingMetadata();
      await _until(() => covers == 1);
      expect(store.setting('metadata.coverRetryIds'), ['manga:1']);
      controller.setMetadataFillForeground(false);
      cover.complete();
      await run;
      expect(controller.needsMetadata(store.saved('manga:1')!.item), true);
      controller.setMetadataFillForeground(true);
      await _until(() => covers == 2 && !controller.metadataFillRunning);
      expect(store.setting('metadata.coverRetryIds'), isEmpty);
      expect(source.maximumActive, 1);
    },
  );

  test(
    'three consecutive connection failures stop the pass until explicit retry',
    () async {
      connect();
      for (var id = 1; id <= 5; id++) {
        placeholder(id);
      }
      source.respond = (_) async => throw const ContentException('Offline');
      await controller.fillMissingMetadata();
      expect(source.calls, [5, 4, 3]);
      expect(controller.metadataFillCompleted, 3);
      expect(controller.metadataFillTotal, 5);
      expect(controller.metadataFillFailed, 3);
      expect(controller.metadataFillError, isNotNull);
      expect(store.setting('metadata.fillPending'), true);
      controller.setMetadataFillForeground(false);
      controller.setMetadataFillForeground(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(source.calls, hasLength(3));
      source.respond = null;
      await controller.fillMissingMetadata();
      expect(source.calls, hasLength(8));
      expect(controller.metadataFillError, isNull);
      expect(store.setting('metadata.fillPending'), false);
    },
  );

  test(
    'a missing work does not prevent later works from being filled',
    () async {
      connect();
      for (var id = 1; id <= 3; id++) {
        placeholder(id);
      }
      source.respond = (id) async {
        if (id == 3) throw const ContentException('Not found', statusCode: 404);
        return source.item(id);
      };
      await controller.fillMissingMetadata();
      expect(source.calls, [3, 2, 1]);
      expect(controller.metadataFillFailed, 1);
      expect(store.saved('manga:3')!.item.title, '#3');
      expect(store.saved('manga:1')!.item.title, 'Fetched 1');
    },
  );

  test(
    'in-flight enrichment preserves edits and cannot resurrect a removed work',
    () async {
      connect();
      placeholder(1);
      final response = Completer<ContentItem>();
      source.respond = (_) => response.future;
      final run = controller.fillMissingMetadata();
      await _until(() => source.calls.isNotEmpty);
      store.saveItem(
        const ContentItem(
          sourceId: '',
          id: 1,
          mode: AppMode.manga,
          title: 'User title',
          tags: ['user-tag'],
          metadata: {'metadata_source': 'manual'},
        ),
        note: 'User note',
      );
      response.complete(source.item(1));
      await run;
      expect(store.saved('manga:1')!.item.title, 'User title');
      expect(store.saved('manga:1')!.item.tags, ['user-tag']);
      expect(store.saved('manga:1')!.note, 'User note');
      expect(store.saved('manga:1')!.savedAt, DateTime.utc(2024, 1, 1));
      placeholder(2);
      final removed = Completer<ContentItem>();
      source.respond = (_) => removed.future;
      final later = controller.fillMissingMetadata();
      await _until(() => source.calls.contains(2));
      controller.unsave(store.saved('manga:2')!.item);
      removed.complete(source.item(2));
      await later;
      expect(store.saved('manga:2'), isNull);
    },
  );

  test(
    'restoration without an import request does not start network enrichment',
    () async {
      connect();
      placeholder(1);
      controller.libraryRestored();
      await Future<void>.delayed(Duration.zero);
      expect(source.calls, isEmpty);
      expect(controller.metadataFillNoticeVisible, false);
      expect(store.setting('metadata.fillPending'), isNull);
    },
  );

  test(
    'persisted incomplete covers remain retryable after controller recreation',
    () async {
      connect();
      placeholder(1);
      controller.setMetadataCoverCache(
        (_) async => throw const ContentException('Cover offline'),
      );
      await controller.fillMissingMetadata();
      expect(store.setting('metadata.coverRetryIds'), ['manga:1']);
      controller.pauseMetadataFill();
      final restored = AppController(
        store,
        sourceFactory: (config) => _MetadataSource(config.id),
      );
      try {
        expect(restored.metadataFillPaused, true);
        expect(restored.needsMetadata(store.saved('manga:1')!.item), true);
        var covers = 0;
        restored.setMetadataCoverCache((_) async {
          covers++;
        });
        await Future<void>.delayed(Duration.zero);
        expect(covers, 0);
        await restored.fillMissingMetadata();
        expect(covers, 1);
        expect(store.setting('metadata.coverRetryIds'), isEmpty);
      } finally {
        restored.dispose();
      }
    },
  );
}
