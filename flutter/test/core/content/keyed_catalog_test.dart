// Ported from native-ios/TEGNALTests/KeyedCatalogTests.swift.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/content_errors.dart';
import 'package:tegnal/core/content/content_transport.dart';
import 'package:tegnal/core/content/content_url.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/content/gallery_id_parser.dart';
import 'package:tegnal/core/content/keyed_catalog_source.dart';
import 'package:tegnal/core/content/manga_content_source.dart';
import 'package:tegnal/core/content/manga_urls.dart';
import 'package:tegnal/core/content/site_account.dart';

import 'content_test_support.dart';

String key(int id) => id.toRadixString(16).padLeft(10, '0');

late Uint8List sheet;

Future<Uint8List> makeSheet() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 100, 150), ui.Paint()..color = const ui.Color(0xFFFF0000));
  canvas.drawRect(const ui.Rect.fromLTWH(100, 0, 100, 150), ui.Paint()..color = const ui.Color(0xFF0000FF));
  final image = await recorder.endRecording().toImage(200, 150);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

Future<(int, int)> imageSize(List<int> data) async {
  final frame = await (await ui.instantiateImageCodec(Uint8List.fromList(data))).getNextFrame();
  return (frame.image.width, frame.image.height);
}

String listing(List<int> ids, {int? next}) {
  final rows = ids
      .map((id) => '<tr><td class="gl3c"><a href="https://keyed.example/g/$id/${key(id)}/"><div class="glink">Sample $id</div></a></td></tr>')
      .join();
  final nav = next == null
      ? '<div class="searchnav"><span id="unext">Next &gt;</span></div>'
      : '<div class="searchnav"><a id="unext" href="https://keyed.example/?f_search=x&amp;next=$next">Next &gt;</a></div>';
  return '<html><body><form><input type="text" id="f_search" name="f_search"></form><table class="itg">$rows</table>$nav</body></html>';
}

String detail(int id, {required int page}) {
  final entries = page == 0
      ? [('1111111111', 1, 'one.jpg', '$id-0.png', 0), ('2222222222', 2, 'two.jpg', '$id-0.png', -100)]
      : [('3333333333', 3, 'three.jpg', '$id-1.png', 0)];
  final links = entries
      .map(
        (entry) =>
            '<a href="https://keyed.example/s/${entry.$1}/$id-${entry.$2}"><div title="Page ${entry.$2}: ${entry.$3}" style="width:100px;height:150px;background:transparent url(https://sheets.example/${entry.$4}) ${entry.$5}px 0 no-repeat"></div></a>',
      )
      .join();
  return '<html><script>var api_url = "https://api.keyed.example/api.php";\nvar login_url = "https://keyed.example/bounce_login.php?b=d&bt=1";</script><div id="gdt">$links</div></html>';
}

class KeyedFixture {
  final requests = <Uri>[];
  final cookies = <String>[];
  final favoriteForms = <String>[];
  bool failFirstNode = false;
  bool allowanceUsed = false;
  final image = List.filled(64, 0x42);

  int count(String path) => requests.where((url) => url.path == path).length;
  ContentTransport transport() => ContentTransport(fetcher: FixtureFetcher(reply));

  String _details(List<int> body) {
    final request = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
    if (request['method'] == 'tagsuggest') {
      return jsonEncode({
        'tags': {
          '1': {'ns': 'parody', 'tn': 'sample series'},
          '2': {'ns': 'temp', 'tn': 'sample alias', 'mns': 'female', 'mtn': 'sample tag'},
          '3': {'ns': 'temp', 'tn': 'loose word'},
        },
      });
    }
    final items = (request['gidlist'] as List).cast<List>().map((pair) {
      final id = pair[0] as int;
      if (pair[1] != key(id)) return {'gid': id, 'error': 'Key missing, or incorrect key provided.'};
      final tags = [id == 2999 ? 'language:japanese' : 'language:korean', 'artist:sample artist', 'parody:sample series', 'other:sample tag'];
      if (id != 2999) tags.add('language:translated');
      if (id == 3002) tags.add('female:marked tag');
      return {
        'gid': id,
        'token': key(id),
        'title': 'Sample $id',
        'title_jpn': '原題 $id',
        'category': id == 3001 ? 'Manga' : 'Doujinshi',
        'thumb': 'https://covers.example/$id.jpg',
        'filecount': '3',
        'tags': tags,
      };
    }).toList();
    return jsonEncode({'gmetadata': items});
  }

  FixtureReply reply(HttpExchange request) {
    final url = request.url;
    requests.add(url);
    final cookie = request.headers.entries.where((entry) => entry.key.toLowerCase() == 'cookie').firstOrNull?.value;
    if (cookie != null) cookies.add(cookie);
    final items = ContentURL.queryItems(url);
    String? item(String name) => items.where((entry) => entry.$1 == name).firstOrNull?.$2;
    switch (url.host) {
      case 'covers.example':
        return FixtureReply(200, image, {'Content-Type': 'image/jpeg'});
      case 'sheets.example':
        return FixtureReply(200, sheet, {'Content-Type': 'image/png'});
      case 'node1.volunteer.example':
        return failFirstNode ? FixtureReply(503) : FixtureReply(200, image, {'Content-Type': 'image/webp'});
      case 'node2.volunteer.example':
        return FixtureReply(200, image, {'Content-Type': 'image/webp'});
      case 'notice.example':
        return FixtureReply(200, image, {'Content-Type': 'image/gif'});
      case 'api.keyed.example' || 'api.members.example':
        return FixtureReply.text(200, _details(request.body ?? const []), {'Content-Type': 'application/json'});
      case 'members.example':
        if (!(cookie ?? '').contains('app_member_id=42')) return FixtureReply.redirect(Uri.parse('https://account.example/remoteapi.php?ex=token'));
        if (url.path == '/') return FixtureReply.text(200, listing([3002, 3001, 3000]), {'Content-Type': 'text/html', 'Set-Cookie': 'access=granted; path=/'});
        return FixtureReply.text(200, detail(3002, page: 0), {'Content-Type': 'text/html'});
      case 'keyed.example':
        break;
      default:
        return FixtureReply(404);
    }
    switch (url.path) {
      case '/':
        final search = item('f_search');
        if (search != null && search.startsWith('gid:')) {
          final id = int.tryParse(search.substring(4));
          if (id != null) return FixtureReply.text(200, listing([id]), {'Content-Type': 'text/html'});
        }
        final next = item('next');
        final ids = next == null ? [3002, 3001, 3000] : [2999, 2998];
        var shown = ids;
        final mask = int.tryParse(item('f_cats') ?? '');
        if (mask != null && mask & 4 == 0) shown = ids.where((id) => id == 3001).toList();
        return FixtureReply.text(200, listing(shown, next: next == null ? 2999 : null), {'Content-Type': 'text/html'});
      case '/popular':
        return FixtureReply.text(200, listing([2999, 3000, 3001]), {'Content-Type': 'text/html'});
      case '/favorites.php':
        if (!(cookie ?? '').contains('app_member_id=42')) {
          return FixtureReply.text(200, '<html><form><input type="password" name="PassWord"></form></html>', {'Content-Type': 'text/html'});
        }
        final next = item('next');
        return FixtureReply.text(200, next == null ? listing([2998, 2990], next: 2990) : listing([2980]), {'Content-Type': 'text/html'});
      case '/gallerypopups.php':
        favoriteForms.add(utf8.decode(request.body ?? const []));
        return FixtureReply.text(200, '<html><script>window.opener.location.reload();</script></html>', {'Content-Type': 'text/html'});
      default:
        final parts = url.pathSegments.where((part) => part.isNotEmpty).toList();
        if (parts.length == 3 && parts[0] == 'g' && int.tryParse(parts[1]) != null && parts[2] == key(int.parse(parts[1]))) {
          return FixtureReply.text(200, detail(int.parse(parts[1]), page: url.query == 'p=1' ? 1 : 0), {'Content-Type': 'text/html'});
        }
        if (parts.length == 3 && parts[0] == 's') {
          final number = parts[2].split('-').last;
          final reload = item('nl');
          final host = allowanceUsed
              ? 'https://notice.example/g/509.gif'
              : reload == null
              ? 'https://node1.volunteer.example:8440/h/$number.webp'
              : 'https://node2.volunteer.example:8440/h/$number.webp';
          return FixtureReply.text(
            200,
            '<html><div id="i3"><a href="/next"><img id="img" src="$host" onerror="this.onerror=null; nl(\'alt-$number\')"></a></div><p>reader page with enough text to be a real page</p></html>',
            {'Content-Type': 'text/html'},
          );
        }
        return FixtureReply(404);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => sheet = await makeSheet());
  setUp(() => resetContent(site: 'keyed.example'));

  test('listing resolves the protocol and follows the cursor', () async {
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    final first = await source.list(const GalleryQuery(language: 'all'), offset: 0, count: 3);
    expect(first.ids, [3002, 3001, 3000]);
    expect(first.hasMore, isTrue);
    expect(MangaUrls.backend, MangaBackend.keyed);
    expect(MangaUrls.keyedAPI.toString(), 'https://api.keyed.example/api.php');
    expect(MangaUrls.signInURL.toString(), 'https://keyed.example/bounce_login.php?b=d&bt=1');
    expect(MangaUrls.galleryUrl(3000), 'https://keyed.example/g/3000/${key(3000)}/');
    expect(GallerySort.available, [GallerySort.latest, GallerySort.today]);
    expect(GalleryCategory.available.contains('western'), isTrue);

    final second = await source.list(const GalleryQuery(language: 'all'), offset: 3, count: 3);
    expect(second.ids, [2999, 2998]);
    expect(second.hasMore, isFalse);
    expect(fixture.requests.any((url) => url.query.contains('next=2999')), isTrue);

    final preview = source.cachedPreview(3000)!;
    expect(preview.title, 'Sample 3000', reason: 'A translation leads with its translated title');
    expect(source.cachedPreview(2999)?.title, '原題 2999', reason: 'A work still in Japanese leads with its original title');
    expect(source.cachedPreview(3001)?.type, 'manga');
    expect(preview.artists, ['sample artist']);
    expect(preview.language, 'korean');
    expect(preview.tags.contains('series:sample series'), isTrue);
    expect(preview.tags.contains('tag:sample tag'), isTrue);
    expect(fixture.count('/api.php'), 2, reason: 'Each listing page reads its details in one batch');
  });

  test('searches send tags categories and exclusions in the site spelling', () async {
    const query = GalleryQuery(language: 'korean', artist: 'sample artist', text: 'female:big_breasts series:sample -tag:excluded type:manga');
    final url = KeyedCatalogSource.searchURL(
      query,
      site: 'https://keyed.example/',
      categories: KeyedCatalogSource.selectedCategories(query),
      language: 'korean',
      next: '2999',
    );
    final items = ContentURL.queryItems(url);
    String? item(String name) => items.where((entry) => entry.$1 == name).firstOrNull?.$2;
    expect(item('f_search'), r'female:"big breasts$" parody:"sample$" language:"korean$" artist:"sample artist$" -other:"excluded$"');
    expect(item('f_cats'), '${1023 & ~4}');
    expect(item('next'), '2999');
    final plain = KeyedCatalogSource.searchURL(
      const GalleryQuery(language: 'all'),
      site: 'https://keyed.example/',
      categories: KeyedCatalogSource.allCategories,
    );
    expect(plain.hasQuery, isFalse);

    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    final filtered = await source.list(const GalleryQuery(language: 'all', text: '-female:marked_tag'), offset: 0, count: 5);
    expect(filtered.ids.contains(3002), isFalse, reason: 'Exclusions also apply to rows the site still returned');
    final manga = await source.list(const GalleryQuery(language: 'all', text: 'type:manga'), offset: 0, count: 5);
    expect(manga.ids, [3001]);
  });

  test('work pages previews and reader images', () async {
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    await source.list(const GalleryQuery(language: 'all'), offset: 0, count: 3);
    final gallery = await source.gallery(3000);
    expect(gallery.pages.length, 3);
    expect(gallery.pages[1].name, 'two.jpg');
    expect(gallery.pages[0].thumbnailURL.toString(), 'https://covers.example/3000.jpg', reason: 'The first page shows the cover');

    final cover = await source.image(gallery.pages[0], galleryID: 3000, thumbnail: true);
    expect(cover, fixture.image);
    final tile = await source.image(gallery.pages[1], galleryID: 3000, thumbnail: true);
    expect(await imageSize(tile), (100, 150), reason: 'A page preview is cut out of the sheet of previews');
    await source.image(gallery.pages[0], galleryID: 3000, thumbnail: false);
    expect(fixture.count('/3000-0.png'), 1, reason: 'Tiles of one sheet share one download');

    await source.image(gallery.pages[2], galleryID: 3000, thumbnail: true);
    // Swift's `URL.path` drops the trailing slash that Dart's keeps.
    expect(
      fixture.requests.any((url) => url.path == '/g/3000/${key(3000)}/' && url.query == 'p=1'),
      isTrue,
      reason: 'Pages past the first sheet are read when they are needed',
    );

    fixture.failFirstNode = true;
    final page = await source.image(gallery.pages[1], galleryID: 3000, thumbnail: false);
    expect(page, fixture.image);
    expect(
      fixture.requests.any((url) => url.host == 'node2.volunteer.example' && url.port == 8440),
      isTrue,
      reason: 'A failed host is replaced by another one',
    );
    expect(fixture.requests.any((url) => url.query == 'nl=alt-2'), isTrue);
  });

  test('image allowance notice is reported instead of shown', () async {
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    final gallery = await source.gallery(3000);
    fixture.allowanceUsed = true;
    await expectLater(source.image(gallery.pages[1], galleryID: 3000, thumbnail: false), throwsA(ContentError.imageLimit));
  });

  test('forgotten key is found by searching the number', () async {
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    await source.list(const GalleryQuery(language: 'all'), offset: 0, count: 1);
    GalleryKeys.shared.removeAll();
    expect(MangaUrls.galleryUrl(2990), 'https://keyed.example/?f_search=gid:2990');
    final gallery = await source.gallery(2990);
    expect(gallery.id, 2990);
    expect(fixture.requests.any((url) => ContentURL.queryItems(url).contains(('f_search', 'gid:2990'))), isTrue);
    expect(GalleryKeys.shared.key(2990), key(2990));
  });

  test('members only site asks for sign in then sends only the identity', () async {
    MangaUrls.preferences.set('manga.site_address', 'members.example');
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    await expectLater(source.list(const GalleryQuery(language: 'all'), offset: 0, count: 2), throwsA(ContentError.signInRequired));
    expect(MangaUrls.requiresSignIn, isTrue);
    expect(MangaUrls.accountHost, 'account.example');
    expect(MangaUrls.signInURL.toString(), 'https://account.example/index.php?act=Login&CODE=00');

    expect(
      SiteAccount.signIn(const [
        SiteCookie(name: 'app_member_id', value: '42'),
        SiteCookie(name: 'app_pass_hash', value: 'secret'),
        SiteCookie(name: 'tracking', value: '1'),
      ]),
      isTrue,
    );
    MangaUrls.resetResolvedBackend();
    final batch = await source.list(const GalleryQuery(language: 'all'), offset: 0, count: 2);
    expect(batch.ids, [3002, 3001]);
    final header = fixture.cookies.last;
    expect(header.contains('app_member_id=42') && header.contains('app_pass_hash=secret') && header.contains('nw=1'), isTrue);
    expect(header.contains('tracking'), isFalse, reason: 'Only the account identity is kept from sign-in');
    expect(header.contains('access=granted'), isTrue, reason: 'Cookies the site grants are sent back to it');
    expect(SiteAccount.cookieHeader(Uri.parse('https://covers.example/3000.jpg')), isNull, reason: 'The identity never reaches other hosts');

    MangaUrls.preferences.set('manga.site_address', 'catalog.example');
    expect(SiteAccount.cookieHeader(Uri.parse('https://catalog.example/')), isNull, reason: 'Sites that do not use accounts never receive it');
  });

  test('account favorites import and mirror bookmarks', () async {
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    await source.list(const GalleryQuery(language: 'all'), offset: 0, count: 1);
    await expectLater(source.accountFavorites(), throwsA(ContentError.signInRequired));
    expect(SiteAccount.signIn(const [SiteCookie(name: 'app_member_id', value: '42'), SiteCookie(name: 'app_pass_hash', value: 'secret')]), isTrue);
    final first = await source.accountFavorites();
    expect(first.$1, [2998, 2990]);
    expect(first.$2, '2990');
    final last = await source.accountFavorites(after: first.$2);
    expect(last.$1, [2980]);
    expect(last.$2, isNull);
    expect(source.cachedPreview(2980), isNotNull, reason: 'Imported favorites carry their titles and tags');

    await source.setAccountFavorite(3000, saved: true);
    await source.setAccountFavorite(3000, saved: false);
    expect(fixture.favoriteForms, ['favcat=0&favnote=&apply=Add+to+Favorites&update=1', 'favcat=favdel&favnote=&update=1']);
    expect(fixture.requests.any((url) => url.path == '/gallerypopups.php' && url.query.contains('t=${key(3000)}')), isTrue);
  });

  test('popular narrows by search language and category', () async {
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    final all = await source.list(const GalleryQuery(language: 'all', sort: GallerySort.today), offset: 0, count: 10);
    expect(all.ids, [2999, 3000, 3001]);
    final korean = await source.list(const GalleryQuery(language: 'korean', sort: GallerySort.today), offset: 0, count: 10);
    expect(korean.ids, [3000, 3001]);
    final manga = await source.list(const GalleryQuery(language: 'all', text: 'type:manga', sort: GallerySort.today), offset: 0, count: 10);
    expect(manga.ids, [3001]);
    expect(fixture.count('/popular'), 1);
  });

  test('suggestions use the app namespaces and canonical tags', () async {
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    final suggestions = await source.suggestions('-sample');
    expect(suggestions.map((item) => item.token), ['series:sample_series', 'female:sample_tag']);
    final narrowed = await source.suggestions('series:sam');
    expect(narrowed.map((item) => item.token), ['series:sample_series']);
  });

  test('site links and searches open in the app', () {
    final link = 'https://keyed.example/g/3000/${key(3000)}/';
    expect(ContentRoute.initial(link), const GalleryRoute(3000));
    expect(GalleryKeys.shared.key(3000), key(3000));
    expect(GalleryIDParser.parse('look at $link'), [3000]);
    expect(ContentRoute.initial('https://keyed.example/?f_search=gid%3A3000'), const GalleryRoute(3000));
    expect(
      ContentRoute.initial('https://keyed.example/?f_search=artist%3A%22sample+artist%24%22+-other%3A%22x+y%24%22'),
      const QueryRoute('artist:sample_artist -tag:x_y'),
    );
    expect(ContentRoute.initial('https://other.example/g/3000/${key(3000)}/'), isNull);
  });

  test('preview tiles are cut from the sheet', () async {
    final tile = await KeyedCatalogSource.cropped(sheet, const CropRect(100, 0, 100, 150));
    expect(await imageSize(tile), (100, 150));
    final entries = KeyedCatalogSource.entries(detail(3000, page: 0), 3000);
    expect(entries[1]?.thumb?.crop, const CropRect(100, 0, 100, 150));
    expect(entries[1]?.key, '2222222222');
    final first = entries[0]!.thumb!;
    expect(KeyedCatalogSource.thumbFrom(KeyedCatalogSource.encoded(first)), first);
  });
}
