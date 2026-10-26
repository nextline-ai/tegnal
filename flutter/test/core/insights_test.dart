import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/insights.dart';
import 'package:tegnal/core/library.dart';

void main() {
  final now = DateTime.utc(2026, 10, 26, 12);
  ContentItem item(
    int id, {
    String source = 'a',
    AppMode mode = AppMode.booru,
    List<String> tags = const ['blue', 'sky'],
    List<String> artists = const [],
    Map<String, dynamic> metadata = const {},
    int pages = 0,
  }) => ContentItem(
    sourceId: source,
    id: id,
    mode: mode,
    title: 'Work $id',
    tags: tags,
    artists: artists,
    metadata: metadata,
    pageCount: pages,
  );
  SavedItem saved(ContentItem content, {int days = 1}) => SavedItem(
    item: content,
    savedAt: now.subtract(Duration(days: days)),
  );
  SourceConfig source(String id, {AppMode mode = AppMode.booru}) =>
      SourceConfig(
        id: id,
        name: id,
        baseUrl: Uri.parse('https://$id.invalid'),
        kind: mode == AppMode.manga ? SourceKind.manga : SourceKind.danbooru,
      );
  TasteSnapshot profile([List<SavedItem>? entries]) => TasteAnalyzer.analyze(
    entries ?? [saved(item(1))],
    mode: AppMode.booru,
    now: now,
  );

  test('profiles deduplicate works and tags, isolate modes and filter technical metadata', () {
    final entries = [
      saved(
        item(
          1,
          tags: ['Blue', 'blue', 'highres', 'custom_meta', '1girl', 'rating:s'],
          artists: ['Author', 'Author'],
          pages: 12,
        ),
      ),
      saved(
        item(
          1,
          tags: ['blue', 'highres', 'custom_meta', '1girl', 'rating:s'],
          artists: ['Author'],
          pages: 12,
        ),
        days: 0,
      ),
      saved(
        item(
          2,
          tags: ['blue', 'custom_meta'],
          metadata: {
            'metadataTags': ['custom_meta'],
          },
          pages: -5,
        ),
      ),
      saved(item(3, mode: AppMode.manga, tags: ['other'], pages: 100)),
      saved(
        item(
          4,
          source: 'b',
          tags: ['custom_meta'],
          metadata: {'metadataTags': 'invalid legacy shape'},
        ),
      ),
    ];
    final report = profile(entries);
    expect(report.totalWorks, 3);
    expect(report.totalPages, 12);
    expect(report.tagCounts, {'blue': 2, 'custom_meta': 1});
    expect(report.artists, {'author': 1});
    expect(report.categories, {'rating:s': 1});
    expect(report.sourceCounts, {'a': 2, 'b': 1});
    expect(report.generatedByAI, isFalse);
  });

  test('7 and 30 day recaps use exact half-open previous periods and ignore future dates', () {
    final entries = [
      for (final day in [1, 7, 8, 30, 31, 61, -1])
        saved(item(day + 100), days: day),
    ];
    final report = profile(entries);
    expect(report.weekly.saves, 2);
    expect(report.weekly.previousSaves, 1);
    expect(report.monthly.saves, 4);
    expect(report.monthly.previousSaves, 1);
    expect(report.findings.first.pattern, InsightPattern.rising);
    expect(report.findings.first.count, 4);
    expect(report.findings.first.previousCount, 1);
  });

  test('manga exclusions repair legacy aliases without changing explicit namespaces', () {
    final report = TasteAnalyzer.analyze(
      [
        saved(
          item(
            1,
            mode: AppMode.manga,
            tags: [
              'female:solo_female',
              'sole_female',
              'male:sole_female',
              'creative',
              'language:ja',
              'type:manga',
            ],
          ),
        ),
      ],
      mode: AppMode.manga,
      now: now,
    );
    expect(report.tagCounts, {'creative': 1, 'male:sole_female': 1});
    expect(report.categories, {'language:ja': 1, 'type:manga': 1});
    final preferences = InsightPreferences(
      mode: AppMode.manga,
      excludedTags: {'creative'},
      excludedBySource: {
        'a': {'male:sole_female'},
      },
    );
    expect(preferences.allows('creative', 'a'), isTrue);
    expect(preferences.allows('creative', 'b'), isFalse);
    expect(preferences.allows('male:sole_female', 'a'), isFalse);
  });

  test(
    'association findings require five overlapping works from the same source',
    () {
      final report = profile([
        for (var i = 1; i <= 5; i++) saved(item(i), days: 70),
      ]);
      expect(report.findings.first.pattern, InsightPattern.association);
      expect(report.findings.first.count, 5);
      expect(report.findings.first.related?.name, 'sky');
      final sparse = profile([saved(item(1), days: 70)]);
      expect(sparse.findings.first.pattern, InsightPattern.frequent);
    },
  );

  test('candidate ranking excludes saved, blocked, wrong-source and unsupported metadata', () async {
    final service = RecommendationService(
      load: (_, query) async => ContentPage([
        item(1),
        item(2, tags: ['blue', 'sky', 'blocked']),
        item(3, source: 'elsewhere'),
        item(4, tags: ['unrelated']),
        item(5),
        item(6, tags: ['blue', 'sky', for (var i = 0; i < 15; i++) 'noise$i']),
      ], hasMore: false),
    );
    final result = await service.fetch(
      snapshot: profile(),
      sources: [source('a')],
      blacklists: {'a': 'blocked'},
    );
    expect(result.items.map((entry) => entry.item.id), [5, 6]);
    expect(result.items.first.score, greaterThan(result.items.last.score));
    expect(result.items.first.generatedByAI, isFalse);
    expect(result.generatedByAI, isFalse);
    expect(result.skippedUnscored, 2);
    expect(result.requestCount, 2);
  });

  test('candidate retrieval is explicit and bounded to six requests with concurrency two', () async {
    var requests = 0, active = 0, maximum = 0;
    final entries = [
      for (final id in ['a', 'b', 'c', 'd']) saved(item(1, source: id)),
    ];
    final service = RecommendationService(
      load: (_, query) async {
        requests++;
        active++;
        if (active > maximum) maximum = active;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        active--;
        return const ContentPage([], hasMore: false);
      },
    );
    expect(requests, 0);
    final result = await service.fetch(
      snapshot: profile(entries),
      sources: [
        for (final id in ['a', 'b', 'c', 'd']) source(id),
      ],
    );
    expect(requests, 6);
    expect(maximum, 2);
    expect(result.requestCount, 6);
    expect(result.omittedSources, 1);
  });

  test('source failures stay partial and duplicate candidates have deterministic reasons', () async {
    final report = profile([saved(item(1)), saved(item(1, source: 'b'))]);
    Future<TasteRecommendations> fetch(bool reverse) => RecommendationService(
      load: (config, query) async {
        if (config.id == 'b') throw const ContentException('Fixture offline');
        await Future<void>.delayed(
          Duration(milliseconds: (query == 'blue') == reverse ? 2 : 0),
        );
        return ContentPage([item(9)], hasMore: false);
      },
    ).fetch(snapshot: report, sources: [source('a'), source('b')]);
    final first = await fetch(false), second = await fetch(true);
    expect(first.items.single.item.id, 9);
    expect(first.items.single.reason.name, 'blue');
    expect(second.items.single.reason.name, first.items.single.reason.name);
    expect(first.failures.length, 1);
    expect(first.failures.single.sourceId, 'b');
  });

  test('new saves after retrieval and cancelled fetches do not appear as recommendations', () async {
    final newlySaved = <String>{};
    final service = RecommendationService(
      load: (_, query) async {
        final candidate = item(7);
        newlySaved.add(candidate.key);
        return ContentPage([candidate], hasMore: false);
      },
    );
    final result = await service.fetch(
      snapshot: profile(),
      sources: [source('a')],
      currentSavedKeys: () => newlySaved,
    );
    expect(result.items, isEmpty);
    final cancelled = await service.fetch(
      snapshot: profile(),
      sources: [source('a')],
      cancelled: () => true,
      currentSavedKeys: () =>
          throw StateError('Cancelled fetch must not query the store'),
    );
    expect(cancelled.requestCount, 0);
  });
}
