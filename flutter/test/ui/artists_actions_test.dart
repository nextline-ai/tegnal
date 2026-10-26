import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/backup_codec.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/features/artists_screen.dart';

void main() {
  late LibraryStore store;
  late AppController controller;

  setUp(() {
    store = LibraryStore.memory();
    controller = AppController(
      store,
      sourceFactory: (_) => throw StateError('Widget tests must stay offline.'),
    );
  });
  tearDown(() {
    controller.dispose();
    store.database.close();
  });

  SourceConfig source(String id, AppMode mode) {
    final config = SourceConfig(
      id: id,
      name: id,
      baseUrl: Uri.https('$id.invalid'),
      kind: mode == AppMode.booru ? SourceKind.danbooru : SourceKind.manga,
    );
    store.saveSource(config);
    return config;
  }

  Future<void> pumpArtists(
    WidgetTester tester,
    AppMode mode, {
    ValueChanged<String>? onSearch,
  }) async {
    tester.view.physicalSize = const Size(480, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    controller.setMode(mode);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        home: ArtistsScreen(
          controller: controller,
          onOpen: (_) {},
          onSearch: onSearch ?? (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final mode in AppMode.values) {
    testWidgets(
      '${mode.name} history bookmark survives clearing and native backup round trip',
      (tester) async {
        source('primary', mode);
        source('other', mode);
        const query = 'scenery sky';
        const existing = 'existing landscape';
        store.recordSearch(
          mode,
          'primary',
          query,
          usedAt: DateTime.utc(2026, 10, 25),
        );
        if (mode == AppMode.manga) {
          store.setPortable('backup.comics', {
            'saved_searches': [existing],
          });
        } else {
          store.setPortable('backup.images', {
            'savedTags': [
              {
                'serverID': 'other',
                'kind': 'search',
                'name': existing,
                'portableSearchExtra': 'preserve',
              },
            ],
          });
        }
        await pumpArtists(tester, mode);
        await tester.tap(find.byIcon(Icons.star_border));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.star), findsOneWidget);
        expect(find.text(query), findsNWidgets(2));

        await tester.tap(find.byIcon(Icons.delete_outline));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Cancel'),
          ),
        );
        await tester.pumpAndSettle();
        expect(store.history(mode).single.query, query);
        await tester.tap(find.byIcon(Icons.delete_outline));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Clear History'),
          ),
        );
        await tester.pumpAndSettle();
        expect(store.history(mode), isEmpty);
        expect(find.text(query), findsOneWidget);

        final encoded = BackupCodec(store).exportJson();
        final exported = jsonDecode(encoded) as Map<String, dynamic>;
        if (mode == AppMode.manga) {
          expect(
            (exported['comics'] as Map)['saved_searches'],
            unorderedEquals([existing, query]),
          );
        } else {
          final savedTags = ((exported['images'] as Map)['savedTags'] as List)
              .cast<Map<String, dynamic>>();
          expect(
            savedTags,
            contains(
              allOf(
                containsPair('serverID', 'primary'),
                containsPair('kind', 'search'),
                containsPair('name', query),
              ),
            ),
          );
          expect(
            savedTags,
            contains(
              allOf(
                containsPair('serverID', 'other'),
                containsPair('name', existing),
                containsPair('portableSearchExtra', 'preserve'),
              ),
            ),
          );
        }
        final restored = LibraryStore.memory();
        try {
          BackupCodec(restored).importJson(encoded);
          expect(restored.history(mode), isEmpty);
          if (mode == AppMode.manga) {
            expect(
              restored.portable('backup.comics')!['saved_searches'],
              unorderedEquals([existing, query]),
            );
          } else {
            final records =
                restored.portable('backup.images')!['savedTags'] as List;
            expect(
              records,
              contains(
                allOf(
                  containsPair('serverID', 'primary'),
                  containsPair('kind', 'search'),
                  containsPair('name', query),
                ),
              ),
            );
          }
        } finally {
          restored.database.close();
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('saved search opens exact query on its own source', (
    tester,
  ) async {
    final first = source('primary', AppMode.booru);
    source('other', AppMode.booru);
    controller.selectSource(first);
    const query = 'artist:some_artist scenery';
    store.setPortable('backup.images', {
      'savedTags': [
        {'serverID': 'other', 'kind': 'search', 'name': query},
      ],
    });
    String? searched;
    await pumpArtists(
      tester,
      AppMode.booru,
      onSearch: (value) => searched = value,
    );
    await tester.tap(find.text('artist:some artist scenery'));
    await tester.pumpAndSettle();

    expect(searched, query);
    expect(controller.selectedSource(AppMode.booru)!.id, 'other');
    expect(controller.selectedSources(AppMode.booru).map((value) => value.id), [
      'other',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling saved search removal preserves the bookmark', (
    tester,
  ) async {
    source('primary', AppMode.booru);
    store.setPortable('backup.images', {
      'savedTags': [
        {'serverID': 'primary', 'kind': 'search', 'name': 'keep this'},
      ],
    });
    await pumpArtists(tester, AppMode.booru);
    await tester.longPress(find.text('keep this'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('Cancel'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('keep this'), findsOneWidget);
    expect(store.portable('backup.images')!['savedTags'], hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
