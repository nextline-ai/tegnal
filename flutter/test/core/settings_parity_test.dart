import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/booru_credentials.dart';
import 'package:tegnal/data/library_store.dart';

void main() {
  test('new libraries default dark while explicit legacy and per-mode choices remain', () {
    final store = LibraryStore.memory();
    final c = AppController(store);
    addTearDown(() {
      c.dispose();
      store.close();
    });
    expect(c.appearanceFor(AppMode.manga), 'dark');
    expect(c.appearanceFor(AppMode.booru), 'dark');
    c.setPreference('appearance', 'system');
    expect(c.appearanceFor(AppMode.manga), 'system');
    expect(c.appearanceFor(AppMode.booru), 'system');
    c.setPreference('appearance.manga', 'light');
    c.setPreference('appearance.booru', 'dark');
    expect(c.appearanceFor(AppMode.manga), 'light');
    expect(c.appearanceFor(AppMode.booru), 'dark');
  });

  test('mode appearance, reader options and default search policy persist separately', () {
    final store = LibraryStore.memory();
    final c = AppController(store);
    addTearDown(() {
      c.dispose();
      store.close();
    });
    c.setPreference('appearance.manga', 'light');
    c.setPreference('appearance.booru', 'dark');
    expect(c.appearanceFor(AppMode.manga), 'light');
    expect(c.appearanceFor(AppMode.booru), 'dark');
    const prefs = ReaderPreferences(
      resumeBehavior: ReaderResumeBehavior.fromBeginning,
      pagesPerSpread: 3,
      prefetch: 0,
      bottomMenu: true,
      continuousPreviewSwipe: true,
      reducedData: true,
    );
    c.setReaderPreferences(AppMode.manga, prefs);
    expect(c.readerPreferences(AppMode.manga).toJson(), prefs.toJson());
    expect(c.readerPreferences(AppMode.booru).pagesPerSpread, 1);
    c.setPreference('defaultTags.manga', 'artist:flower tag:scenery');
    c.setPreference('defaultExcludedTags.manga', 'spoilers -gore');
    expect(
      c.effectiveSearchQuery('artist:flower tag:sky', AppMode.manga),
      'artist:flower tag:sky tag:scenery -spoilers -gore',
    );
    c.setPreference('safeMode.booru', true);
    c.setPreference('safeRating.booru', 'q');
    expect(c.effectiveSearchQuery('sky', AppMode.booru), 'sky rating:q');
    expect(
      c.effectiveSearchQuery('sky -rating:e', AppMode.booru),
      'sky -rating:e',
    );
    c.setMode(AppMode.manga);
    expect(c.mode, AppMode.booru);
    c.setPreference('safeMode.booru', false);
    c.setMode(AppMode.manga);
    expect(c.mode, AppMode.manga);
  });

  test('retention removes only expired searches in the selected mode', () {
    final store = LibraryStore.memory();
    final c = AppController(store);
    addTearDown(() {
      c.dispose();
      store.close();
    });
    final old = DateTime.now().subtract(const Duration(days: 8));
    store.recordSearch(AppMode.manga, 'manga', 'old', usedAt: old);
    store.recordSearch(AppMode.manga, 'manga', 'new');
    store.recordSearch(AppMode.booru, 'image', 'old', usedAt: old);
    c.setPreference('historyRetention.manga', 7);
    expect(c.history(AppMode.manga).map((entry) => entry.query), ['new']);
    expect(c.history(AppMode.booru).map((entry) => entry.query), ['old']);
  });

  test(
    'spread alignment clamps the final spread without skipping backwards',
    () {
      expect(ReaderLayout.start(4, 3), 3);
      expect(ReaderLayout.next(0, 1, 3, 8), 3);
      expect(ReaderLayout.next(3, 1, 3, 8), 6);
      expect(ReaderLayout.next(6, 1, 3, 8), 6);
      expect(ReaderLayout.next(6, -1, 3, 8), 3);
      expect(
        ReaderPreferences.fromJson({'pagesPerSpread': 50, 'prefetch': -1})
            .pagesPerSpread,
        4,
      );
      expect(ReaderPreferences.fromJson({'prefetch': -1}).prefetch, 3);
    },
  );

  test('opening a work notifies an existing analysis listener with updated activity', () {
    final store = LibraryStore.memory();
    final c = AppController(store);
    addTearDown(() {
      c.dispose();
      store.close();
    });
    final counts = <int>[];
    c.addListener(
      () => counts.add(
        c.taste
            .historyOpens(
              AppMode.booru,
              since: DateTime.fromMillisecondsSinceEpoch(0),
            )
            .length,
      ),
    );
    const item = ContentItem(
      sourceId: 'server',
      id: 1,
      mode: AppMode.booru,
      title: 'A work',
    );
    c.recordTasteOpen(item);
    expect(counts, [1]);
    c.taste.setEnabled(false);
    c.recordTasteOpen(item);
    expect(counts, [1]);
  });

  test('off prefetch schedules nothing and enabled prefetch stays bounded', () {
    expect(ReaderLoadingPolicy.adjacentPages(3, 20, 0), isEmpty);
    expect(ReaderLoadingPolicy.adjacentPages(3, 20, 3), [2, 4, 5, 6]);
    expect(ReaderLoadingPolicy.adjacentPages(19, 20, 5), [18]);
    expect(ReaderLoadingPolicy.adjacentPages(0, 20, 100).length, 5);
  });

  for (final kind in [
    SourceKind.danbooru,
    SourceKind.gelbooru,
    SourceKind.moebooru,
  ]) {
    test(
      'secure $kind credentials use native protocol and stay on one origin',
      () async {
        final source = SourceConfig(
          id: 'server',
          name: 'Server',
          baseUrl: Uri.https('source.example'),
          kind: kind,
        );
        var calls = 0;
        final client = BooruAuthenticatedClient(
          source,
          load: () async =>
              const BooruCredentials(account: 'account', secret: 'private-key'),
          inner: MockClient((request) async {
            calls++;
            if (request.url.host == 'other.example') {
              expect(request.headers['Authorization'], isNull);
              expect(
                request.url.queryParameters.values,
                isNot(contains('private-key')),
              );
            } else if (kind == SourceKind.danbooru) {
              expect(
                request.headers['Authorization'],
                'Basic ${base64Encode(utf8.encode('account:private-key'))}',
              );
              expect(request.url.queryParameters['tags'], 'sky');
            } else {
              expect(
                request.url.queryParameters[kind == SourceKind.gelbooru
                    ? 'api_key'
                    : 'password_hash'],
                'private-key',
              );
              expect(
                request.url.queryParameters[kind == SourceKind.gelbooru
                    ? 'user_id'
                    : 'login'],
                'account',
              );
              expect(request.url.queryParameters['tags'], 'sky');
              expect(request.followRedirects, isFalse);
            }
            return http.Response('ok', 200);
          }),
        );
        addTearDown(client.close);
        await client.get(
          Uri.https('source.example', '/posts', {'tags': 'sky'}),
        );
        await client.get(Uri.https('other.example', '/posts'));
        expect(calls, 2);
        expect(source.toJson().toString(), isNot(contains('private-key')));
      },
    );
  }
}
