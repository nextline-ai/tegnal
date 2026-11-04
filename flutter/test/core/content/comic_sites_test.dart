// `testConnectedSitesKeepWhatWasLearnedAndKnowWhichShareNumbers` and
// `testASavedWorkKeepsTheFirstSiteItWasSavedFrom` from native-ios/TEGNALTests/MangaBackendTests.swift.

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/content/manga_urls.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/preferences.dart';

void main() {
  setUp(() => ContentPreferences.defaults = MemoryPreferences());

  test('connected sites keep what was learned and know which share numbers', () {
    final preferences = ContentPreferences.defaults;
    void learn(String site, MangaBackend backend) {
      preferences
        ..set('manga.site_address', site)
        ..set('manga.resolved_data_host', site)
        ..set('manga.resolved_cdn_host', site)
        ..set('manga.resolved_protocol', backend.name)
        ..set('manga.resolved_backend_site', MangaUrls.homeForSite(site))
        ..set('manga.resolved_media_hosts', ['media.$site']);
      ComicSites.add(site);
    }

    learn('keyed-one.example', MangaBackend.keyed);
    ComicSites.switchSite(from: 'keyed-one.example', to: 'keyed-two.example');
    learn('keyed-two.example', MangaBackend.keyed);
    ComicSites.switchSite(from: 'keyed-two.example', to: 'indexed.example');
    learn('indexed.example', MangaBackend.indexed);
    expect(ComicSites.all, ['keyed-one.example', 'keyed-two.example', 'indexed.example']);

    ComicSites.switchSite(from: 'indexed.example', to: 'keyed-one.example');
    preferences.set('manga.site_address', 'keyed-one.example');
    expect(MangaUrls.hasResolvedBackend, isTrue, reason: 'Switching back needs no new check');
    expect(MangaUrls.backend, MangaBackend.keyed);
    expect(preferences.object('manga.resolved_media_hosts'), ['media.keyed-one.example'], reason: 'Lists come back as text lists');
    expect(ComicSites.sharesNumbers('keyed-one.example', 'keyed-two.example'), isTrue);
    expect(ComicSites.sharesNumbers('keyed-one.example', 'indexed.example'), isFalse);
    expect(ComicSites.siblings('keyed-one.example'), ['keyed-two.example']);

    ComicSites.remove('keyed-two.example');
    expect(ComicSites.siblings('keyed-one.example'), isEmpty);
    expect(ComicSites.backendOf('keyed-two.example'), isNull, reason: 'A removed site forgets what was learned');
  });

  test('a site connected before the list existed stays when another is added', () {
    final preferences = ContentPreferences.defaults;
    preferences.set('manga.site_address', 'comics-older.net');
    final content = ContentEnvironment(browserPreferences: preferences);
    content.verifySite('comics-newer.net');
    expect(content.comicSites, ['comics-older.net', 'comics-newer.net']);
    expect(content.mangaSiteAddress, 'comics-newer.net');
  });

  test('a saved work keeps the first site it was saved from', () {
    final db = AppDatabase.inMemory();
    db.upsertWork(galleryId: 10, site: 'one.example');
    db.upsertWork(galleryId: 10, title: 'Later', site: 'two.example');
    expect(db.getWork(10)?.site, 'one.example');
    db.upsertWork(galleryId: 11);
    db.upsertWork(galleryId: 11, site: 'two.example');
    expect(db.getWork(11)?.site, 'two.example', reason: 'An unknown site is filled in when it becomes known');
  });
}
