import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/booru_source.dart';

void main() {
  SourceConfig config(SourceKind kind) => SourceConfig(
    id: kind.name,
    name: kind.name,
    baseUrl: Uri.https('booru.invalid'),
    kind: kind,
  );

  test('sort options intersect selected server capabilities', () {
    expect(
      BooruSort.supportedBy([config(SourceKind.danbooru)]),
      BooruSort.values,
    );
    expect(BooruSort.supportedBy([config(SourceKind.moebooru)]), [
      BooruSort.latest,
      BooruSort.popular,
      BooruSort.popularWeek,
      BooruSort.popularMonth,
    ]);
    expect(
      BooruSort.supportedBy([
        config(SourceKind.danbooru),
        config(SourceKind.gelbooru),
      ]),
      [BooruSort.latest, BooruSort.popular],
    );
  });

  test(
    'sort terms follow native engine mappings and retain explicit order',
    () async {
      final requests = <Uri>[];
      final source = BooruSource(
        config(SourceKind.danbooru),
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response('[]', 200);
        }),
      );
      for (final (sort, expected) in [
        (BooruSort.trending, 'order:rank'),
        (BooruSort.mostFavorited, 'order:favcount'),
        (BooruSort.mostUpvoted, 'order:upvotes'),
        (BooruSort.mostDiscussed, 'order:comment_count'),
      ]) {
        await source.searchSorted('blue', sort: sort);
        expect(requests.last.queryParameters['tags'], 'blue $expected');
      }
      await source.searchSorted(
        'blue date:2000-01-01 order:id',
        sort: BooruSort.popularWeek,
      );
      expect(
        requests.last.queryParameters['tags'],
        'blue date:2000-01-01 order:id',
      );
      await source.searchSorted('blue', sort: BooruSort.popularMonth);
      expect(
        requests.last.queryParameters['tags'],
        matches(RegExp(r'^blue date:>=\d{4}-\d{2}-\d{2} order:score$')),
      );
    },
  );

  test('Gelbooru popular uses its sort syntax and old engine bounds', () async {
    late Uri requested;
    final gelbooru = BooruSource(
      config(SourceKind.gelbooru),
      client: MockClient((request) async {
        requested = request.url;
        return http.Response('<posts count="0"></posts>', 200);
      }),
    );
    await gelbooru.searchSorted('blue', sort: BooruSort.popular);
    expect(requested.queryParameters['tags'], 'blue sort:score:desc');
    await expectLater(
      gelbooru.searchSorted('blue', sort: BooruSort.trending),
      throwsA(isA<UnsupportedBooruSort>()),
    );

    late Uri oldRequested;
    final oldGelbooru = BooruSource(
      config(SourceKind.oldGelbooru),
      client: MockClient((request) async {
        oldRequested = request.url;
        return http.Response('<html><body>No images</body></html>', 200);
      }),
    );
    await oldGelbooru.searchSorted('blue', sort: BooruSort.popular);
    expect(oldRequested.queryParameters['tags'], 'blue order:score');
  });

  test(
    'Moebooru popular period adds UTC date and preserves age filters',
    () async {
      final requests = <Uri>[];
      final source = BooruSource(
        config(SourceKind.moebooru),
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response('[]', 200);
        }),
      );
      await source.searchSorted('blue', sort: BooruSort.popularWeek);
      expect(
        requests.last.queryParameters['tags'],
        matches(RegExp(r'^blue date:>=\d{4}-\d{2}-\d{2} order:score$')),
      );
      await source.searchSorted('blue age:<5', sort: BooruSort.popularMonth);
      expect(requests.last.queryParameters['tags'], 'blue age:<5 order:score');
    },
  );

  test(
    'zero results stay empty and explicit sort rejection is typed',
    () async {
      final empty = BooruSource(
        config(SourceKind.danbooru),
        client: MockClient((_) async => http.Response('[]', 200)),
      );
      expect(
        (await empty.searchSorted('blue', sort: BooruSort.mostDiscussed)).items,
        isEmpty,
      );

      final rejected = BooruSource(
        config(SourceKind.danbooru),
        client: MockClient((_) async => http.Response('{}', 422)),
      );
      await expectLater(
        rejected.searchSorted('blue', sort: BooruSort.mostDiscussed),
        throwsA(
          isA<UnsupportedBooruSort>().having(
            (error) => error.sort,
            'sort',
            BooruSort.mostDiscussed,
          ),
        ),
      );
    },
  );
}
