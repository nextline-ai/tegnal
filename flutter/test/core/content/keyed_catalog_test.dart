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
import 'package:tegnal/core/content/keyed_work_extras.dart';
import 'package:tegnal/core/content/manga_content_source.dart';
import 'package:tegnal/core/content/manga_urls.dart';
import 'package:tegnal/core/content/site_account.dart';
import 'package:tegnal/core/support/l10n.dart';

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

String detail(int id, {required int page, List<String> comments = const []}) {
  final entries = page == 0
      ? [('1111111111', 1, 'one.jpg', '$id-0.png', 0), ('2222222222', 2, 'two.jpg', '$id-0.png', -100)]
      : [('3333333333', 3, 'three.jpg', '$id-1.png', 0)];
  final links = entries
      .map(
        (entry) =>
            '<a href="https://keyed.example/s/${entry.$1}/$id-${entry.$2}"><div title="Page ${entry.$2}: ${entry.$3}" style="width:100px;height:150px;background:transparent url(https://sheets.example/${entry.$4}) ${entry.$5}px 0 no-repeat"></div></a>',
      )
      .join();
  final thread = [
    for (final (index, text) in comments.indexed)
      '<div class="c1"><div class="c2"><div class="c3">Posted on 01 January 2026, 00:00 by: &nbsp; <a href="https://keyed.example/uploader/me">me</a></div></div><div class="c6" id="comment_${index + 1}">$text</div></div>',
  ].join();
  final extras =
      '<div id="taglist"><table><tr><td class="tc">female:</td><td><div id="td_female:sample_tag" class="gt"><a id="ta_female:sample_tag" href="https://keyed.example/tag/female:sample+tag" class="tup" onclick="return toggle_tagmenu(1,\'female:sample tag\',this)">sample tag</a></div></td></tr><tr><td class="tc">parody:</td><td><div id="td_parody:sample_series" class="gtl"><a id="ta_parody:sample_series" href="https://keyed.example/tag/parody:sample+series" class="" onclick="return toggle_tagmenu(2,\'parody:sample series\',this)">sample series</a></div></td></tr></table></div>'
      '<p class="g2"><a href="#" onclick="return popUp(\'https://keyed.example/archiver.php?gid=$id&amp;token=${key(id)}\',480,320)">Archive Download</a></p>'
      '<div id="cdiv">$thread</div><div id="formdiv" style="display:none"><form method="post" action="#cnew"><textarea name="commenttext_new"></textarea></form></div>';
  return '<html><script>var api_url = "https://api.keyed.example/api.php";\nvar login_url = "https://keyed.example/bounce_login.php?b=d&bt=1";\nvar apiuid = 42;\nvar apikey = "0123abcd4567";</script><div id="gdt">$links</div>${page == 0 ? extras : ''}</html>';
}

const archivePage = '''
<html><body><div id="db"><h1>Sample 3000</h1><p>Current Funds:</p><p>1,200 GP [<a href="#">?</a>] &nbsp; 393 Credits [<a href="#">?</a>]</p>
<div><div style="width:180px; float:left"><div style="text-align:center">Download Cost: &nbsp; <strong>446 GP</strong></div>
<form action="https://keyed.example/archiver.php?gid=3000&amp;token=0000000bb8" method="post"><input type="hidden" name="dltype" value="org"><div><input type="submit" name="dlcheck" value="Download Original Archive"></div></form>
<p>Estimated Size: &nbsp; <strong>21.24 MiB</strong></p></div>
<div style="width:180px; float:right; color:#CCCCCC"><div style="text-align:center">Download Cost: &nbsp; <strong>N/A</strong></div>
<form action="https://keyed.example/archiver.php?gid=3000&amp;token=0000000bb8" method="post"><input type="hidden" name="dltype" value="res"><div><input type="submit" name="dlcheck" value="Download Resample Archive"></div></form>
<p>Estimated Size: &nbsp; <strong>N/A</strong></p></div></div></div></body></html>
''';

/// A work page for an account that reads in the multi-page viewer: its pages link there.
String viewerDetail(int id) {
  final links = [
    for (var number = 1; number <= 3; number++)
      '<a href="https://keyed.example/mpv/$id/${key(id)}/#page$number"><div title="Page $number: x" style="width:100px;height:150px;background:transparent url(https://sheets.example/$id-0.png) -${(number - 1) * 100}px 0 no-repeat"></div></a>',
  ].join();
  return '<html><div id="gdt">$links</div><p>a work page with enough text to be a real page</p></html>';
}

const viewerPage = r'''
<html><body><div id="pane_images"></div><script type="text/javascript">
var gid=3000;
var mpvkey = "0123456789a";
var imagelist = [{"n":"one.jpg","k":"aaaaaaaaaa","t":"https:\/\/sheets.example\/large-1.jpg"},{"n":"two &amp; three.jpg","k":"bbbbbbbbbb","t":"https:\/\/sheets.example\/large-2.jpg"},{"n":"","k":"cccccccccc","t":"https:\/\/sheets.example\/large-3.jpg"}];
</script></body></html>
''';

class KeyedFixture {
  final requests = <Uri>[];
  final cookies = <String>[];
  final favoriteForms = <String>[];
  bool failFirstNode = false;
  bool allowanceUsed = false;

  /// Words the first image host sends instead of the image.
  String? textAnswer;

  /// How many details requests fail before they answer.
  int failDetails = 0;

  /// The note the favorites form shows, as the page writes it.
  String favoriteNote = '';
  String favoriteReply = '<html><script>window.opener.location.reload();</script></html>';

  /// The account reads in the multi-page viewer, so work pages link there instead of to each page.
  bool viewer = false;
  final image = List.filled(64, 0x42);

  /// Tag votes, comments and archive forms as the website received them.
  final voteRequests = <Map<String, Object?>>[];
  final posted = <String>[];
  final archiveForms = <String>[];

  /// What the website answers a comment it does not take.
  String? commentRefusal;

  /// Reader pages link each page's original, which the website sends only while the account can pay for it.
  bool offersOriginals = false;
  bool grantsOriginals = true;

  int count(String path) => requests.where((url) => url.path == path).length;
  ContentTransport transport() => ContentTransport(fetcher: FixtureFetcher(reply));

  String _details(List<int> body) {
    final request = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
    if (request['method'] == 'taggallery') {
      voteRequests.add(request);
      final vote = request['vote'] as int? ?? 0;
      return jsonEncode({
        'tagpane':
            '<div id="taglist"><a id="ta_female:sample_tag" class="${vote > 0 ? 'tup' : 'tdn'}" onclick="return toggle_tagmenu(1,\'female:sample tag\',this)">sample tag</a></div>',
      });
    }
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
        if (url.path.startsWith('/large-')) return FixtureReply(200, image, {'Content-Type': 'image/jpeg'});
        return FixtureReply(200, sheet, {'Content-Type': 'image/png'});
      case 'node1.volunteer.example':
        if (textAnswer case final words?) return FixtureReply.text(200, words, {'Content-Type': 'text/html; charset=UTF-8'});
        return failFirstNode ? FixtureReply(503) : FixtureReply(200, image, {'Content-Type': 'image/webp'});
      case 'node2.volunteer.example':
        return FixtureReply(200, image, {'Content-Type': 'image/webp'});
      case 'notice.example':
        return FixtureReply(200, image, {'Content-Type': 'image/gif'});
      case 'api.keyed.example' || 'api.members.example':
        if (failDetails > 0) {
          failDetails -= 1;
          return FixtureReply(503);
        }
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
        if (mask != null && mask != 0 && mask & 4 == 0) shown = ids.where((id) => id == 3001).toList();
        return FixtureReply.text(200, listing(shown, next: next == null ? 2999 : null), {'Content-Type': 'text/html'});
      case '/popular':
        return FixtureReply.text(200, listing([2999, 3000, 3001]), {'Content-Type': 'text/html'});
      case '/uconfig.php':
        final chosen = (cookie ?? '').contains('sp=2') ? 2 : 1;
        final options = [
          for (final (id, name) in const [(1, 'Default Profile'), (2, 'Reading in the App')])
            '<option value="$id"${id == chosen ? ' selected="selected"' : ''}>$name</option>',
        ].join();
        return FixtureReply.text(
          200,
          '<html><body><div id="profile_outer"><select name="profile_set" onchange="do_profile_post()">$options</select></div><p>settings page with enough text to read</p></body></html>',
          {'Content-Type': 'text/html'},
        );
      case '/archiver.php':
        if (request.method != 'POST') return FixtureReply.text(200, archivePage, {'Content-Type': 'text/html'});
        archiveForms.add(utf8.decode(request.body ?? const []));
        return FixtureReply.text(
          200,
          '<html><body><script type="text/javascript">document.location = "https://node1.volunteer.example:8440/archive/3000/abcdef/0";</script><p>Your archive is ready, the download starts in a moment.</p></body></html>',
          {'Content-Type': 'text/html'},
        );
      case '/favorites.php':
        if (!(cookie ?? '').contains('app_member_id=42')) {
          return FixtureReply.text(200, '<html><form><input type="password" name="PassWord"></form></html>', {'Content-Type': 'text/html'});
        }
        final next = item('next');
        return FixtureReply.text(200, next == null ? listing([2998, 2990], next: 2990) : listing([2980]), {'Content-Type': 'text/html'});
      case '/gallerypopups.php':
        if (request.method != 'POST') {
          return FixtureReply.text(
            200,
            '<html><body><div id="galpop"><form method="post"><textarea name="favnote" maxlength="200">$favoriteNote</textarea></form></div></body></html>',
            {'Content-Type': 'text/html'},
          );
        }
        favoriteForms.add(utf8.decode(request.body ?? const []));
        return FixtureReply.text(200, favoriteReply, {'Content-Type': 'text/html'});
      default:
        final parts = url.pathSegments.where((part) => part.isNotEmpty).toList();
        if (parts.length == 3 && parts[0] == 'g' && int.tryParse(parts[1]) != null && parts[2] == key(int.parse(parts[1]))) {
          final id = int.parse(parts[1]);
          if (request.method == 'POST') {
            final text = Uri.splitQueryString(utf8.decode(request.body ?? const []))['commenttext_new'] ?? '';
            if (commentRefusal case final refusal?) {
              final page = detail(id, page: 0, comments: posted).replaceFirst('<html>', '<html><p class="br">$refusal</p>');
              return FixtureReply.text(200, page, {'Content-Type': 'text/html'});
            }
            posted.add(text);
          }
          return FixtureReply.text(200, viewer ? viewerDetail(id) : detail(id, page: url.query == 'p=1' ? 1 : 0, comments: posted), {
            'Content-Type': 'text/html',
          });
        }
        if (parts.isNotEmpty && parts[0] == 'fullimg') {
          return grantsOriginals
              ? FixtureReply(200, List.filled(96, 0x77), {'Content-Type': 'image/png'})
              : FixtureReply.text(200, 'Downloading original files of this gallery during peak hours requires GP, and you do not have enough.', {
                  'Content-Type': 'text/html',
                });
        }
        if (parts.length == 3 && parts[0] == 'mpv' && int.tryParse(parts[1]) != null && parts[2] == key(int.parse(parts[1]))) {
          return FixtureReply.text(200, viewerPage, {'Content-Type': 'text/html'});
        }
        if (parts.length == 3 && parts[0] == 's') {
          final number = parts[2].split('-').last;
          final reload = item('nl');
          final host = allowanceUsed
              ? 'https://notice.example/g/509.gif'
              : reload == null
              ? 'https://node1.volunteer.example:8440/h/$number.webp'
              : 'https://node2.volunteer.example:8440/h/$number.webp';
          final original = offersOriginals
              ? '<div id="i6"><a href="https://keyed.example/fullimg/3000/$number/okey123/orig.png">Download original 2400 x 3400 3.1 MiB source</a></div>'
              : '';
          return FixtureReply.text(
            200,
            '<html><div id="i3"><a href="/next"><img id="img" src="$host" onerror="this.onerror=null; nl(\'alt-$number\')"></a></div>$original<p>reader page with enough text to be a real page</p></html>',
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
    expect(ContentURL.queryItems(plain), [
      ('f_cats', '0'),
    ], reason: "Every category is asked for outright, so an account's default exclusions don't narrow the list");

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

  test('image hosts answering in words report the allowance or the ban', () async {
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    final gallery = await source.gallery(3000);
    fixture.textAnswer = 'You have reached the image limit, and do not have sufficient GP to buy a download quota.';
    await expectLater(source.image(gallery.pages[1], galleryID: 3000, thumbnail: false), throwsA(ContentError.imageLimit));
    expect(fixture.requests.any((url) => url.query.startsWith('nl=')), isFalse, reason: "The notice is the site's answer, so no other host is asked");
    expect(fixture.count('/s/2222222222/3000-2'), 1);
    fixture.textAnswer = 'Your IP address has been temporarily banned for excessive pageloads which indicates that you are using automated mirroring/harvesting software. The ban expires in 59 minutes and 48 seconds';
    await expectLater(source.image(gallery.pages[1], galleryID: 3000, thumbnail: false), throwsA(ContentError.temporarilyBlocked));
    expect(fixture.requests.any((url) => url.query.startsWith('nl=')), isFalse);
    expect(KeyedCatalogSource.textNotice(utf8.encode('<html><body>An error has occurred.</body></html>'), mimeType: 'text/html'), isNull);
    expect(KeyedCatalogSource.textNotice(utf8.encode('You have reached the image limit'), mimeType: 'image/webp'), isNull);
  });

  test('number lookups ignore the account\'s own filters', () async {
    final url = KeyedCatalogSource.keySearchURL(2990, site: 'https://keyed.example/');
    expect(Map.fromEntries(ContentURL.queryItems(url).map((item) => MapEntry(item.$1, item.$2))), {
      'f_search': 'gid:2990',
      'f_cats': '0',
      'advsearch': '1',
      'f_sfl': 'on',
      'f_sfu': 'on',
      'f_sft': 'on',
    });
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    await source.list(const GalleryQuery(language: 'all'), offset: 0, count: 1);
    GalleryKeys.shared.removeAll();
    await source.gallery(2990);
    final lookup = fixture.requests.firstWhere((url) => ContentURL.queryItems(url).contains(('f_search', 'gid:2990')));
    expect(ContentURL.queryItems(lookup).contains(('f_sfl', 'on')), isTrue);
  });

  test('cards read works from the details endpoint without opening them', () async {
    final fixture = KeyedFixture();
    await MangaContentSource(transport: fixture.transport()).list(const GalleryQuery(language: 'all'), offset: 0, count: 3);
    // A source whose cached details are gone, as after the system emptied its caches.
    final source = MangaContentSource(transport: fixture.transport());
    expect(source.cachedPreview(3000), isNull);
    final detailsBefore = fixture.count('/api.php');
    final workPagesBefore = fixture.requests.where((url) => url.path.startsWith('/g/')).length;
    final works = await Future.wait([source.preview(3000), source.preview(3001), source.preview(3002)]);
    expect(works.map((work) => work.id), [3000, 3001, 3002]);
    expect(works[0].pageCount, 3);
    expect(works[0].pages.first.thumbnailURL.toString(), 'https://covers.example/3000.jpg');
    expect(fixture.count('/api.php') - detailsBefore, 1, reason: 'Cards asking together share one details request');
    expect(fixture.requests.where((url) => url.path.startsWith('/g/')).length, workPagesBefore, reason: "A card never opens the work's own page");
    expect(source.cachedPreview(3001), isNotNull);
  });

  test('a failed details request is asked once more', () async {
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    fixture.failDetails = 1;
    await source.list(const GalleryQuery(language: 'all'), offset: 0, count: 3);
    expect(source.cachedPreview(3000), isNotNull, reason: 'Details lost to one failed request come with the next');
    expect(fixture.count('/api.php'), 2);
  });

  test('a remembered key the site refuses is looked up again', () async {
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    await source.list(const GalleryQuery(language: 'all'), offset: 0, count: 1);
    GalleryKeys.shared.remember(2990, 'ffffffffff');
    final gallery = await source.gallery(2990);
    expect(gallery.id, 2990);
    expect(GalleryKeys.shared.key(2990), key(2990), reason: 'The key the site accepts replaces the refused one');
    expect(fixture.requests.any((url) => ContentURL.queryItems(url).contains(('f_search', 'gid:2990'))), isTrue);
  });

  test('page loads on one website are paced and other websites are not held up', () async {
    final pacer = PagePacer(burst: 2, interval: const Duration(milliseconds: 100));
    final clock = Stopwatch()..start();
    for (var index = 0; index < 2; index++) {
      await pacer.wait('a.example');
    }
    expect(clock.elapsedMilliseconds, lessThan(50), reason: 'A short burst goes at once');
    clock.reset();
    for (var index = 0; index < 2; index++) {
      await pacer.wait('a.example');
    }
    expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(180), reason: 'Then one page load per interval');
    clock.reset();
    await pacer.wait('b.example');
    expect(clock.elapsedMilliseconds, lessThan(50));
  });

  void signIn() => expect(
    SiteAccount.signIn(const [
      SiteCookie(name: 'app_member_id', value: '42'),
      SiteCookie(name: 'app_pass_hash', value: 'secret'),
    ], host: MangaUrls.configuredHost),
    isTrue,
  );

  test('work pages show tag votes the comment form and the archive', () {
    final extras = KeyedWorkPage.extras(detail(3000, page: 0));
    expect(extras.tagVotes, const [WorkTagVote('female:sample tag', 1), WorkTagVote('parody:sample series', 0)]);
    expect(extras.tagVotes[1].localNamespace, 'series');
    expect(extras.canComment, isTrue);
    expect(extras.canRate, isTrue);
    expect(extras.archiveURL.toString(), 'https://keyed.example/archiver.php?gid=3000&token=0000000bb8');
    final offer = KeyedWorkPage.archiveOffer(archivePage);
    expect(offer.funds, '1,200 GP · 393 Credits');
    expect(offer.options, const [
      WorkArchiveOption(kind: 'org', button: 'Download Original Archive', cost: '446 GP', size: '21.24 MiB', available: true),
      WorkArchiveOption(kind: 'res', button: 'Download Resample Archive', cost: 'N/A', size: 'N/A', available: false),
    ], reason: "An archive the page greys out can't be chosen");
  });

  test("tag votes go to the details endpoint with the work's key", () async {
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    await source.list(const GalleryQuery(language: 'all'), offset: 0, count: 3);
    signIn();
    final votes = await source.voteTag(3000, tag: 'female:sample tag', vote: -1);
    expect(votes, const [WorkTagVote('female:sample tag', -1)], reason: 'The votes come back as they now stand');
    final request = fixture.voteRequests.last;
    expect(request['tags'], 'female:sample tag');
    expect(request['token'], key(3000));
    expect(request['apiuid'], 42);
    expect(request['vote'], -1);
  });

  test("comments are posted and confirmed on the work's page", () async {
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    await source.list(const GalleryQuery(language: 'all'), offset: 0, count: 3);
    signIn();
    await expectLater(source.postComment(3000, 'short'), throwsA(SiteMessage(L10n.text('A comment is too short.'))));
    expect(fixture.posted, isEmpty, reason: 'A short comment never reaches the website');

    final comments = await source.postComment(3000, 'A lovely work & thanks\nsecond line');
    expect(comments.any((comment) => comment.text.contains('A lovely work & thanks')), isTrue, reason: "The comment shows on the work's page");
    expect(fixture.posted.last, 'A lovely work & thanks\nsecond line');

    fixture.commentRefusal = 'You can only post one comment every minute.';
    await expectLater(
      source.postComment(3000, 'Another comment that is long enough'),
      throwsA(const SiteMessage('You can only post one comment every minute.')),
      reason: "A comment the website didn't take must not pass as posted",
    );
  });

  test('archives show their cost and download from the address the website hands out', () async {
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    await source.list(const GalleryQuery(language: 'all'), offset: 0, count: 3);
    signIn();
    final offer = await source.archiveOffer(3000);
    final original = offer.options.firstWhere((option) => option.isOriginal);
    expect(fixture.archiveForms, isEmpty, reason: 'Looking at the offer costs nothing');
    final address = await source.archiveDownloadURL(3000, original);
    expect(address.toString(), 'https://node1.volunteer.example:8440/archive/3000/abcdef/0?start=1');
    expect(fixture.archiveForms, ['dltype=org&dlcheck=Download+Original+Archive']);
    await expectLater(
      source.archiveDownloadURL(3000, offer.options.firstWhere((option) => !option.available)),
      throwsA(ContentError.invalidQuery),
      reason: 'An archive the page greys out is never requested',
    );
  });

  test('original images load when chosen and the resized page shows when refused', () async {
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    final gallery = await source.gallery(3000);
    fixture.offersOriginals = true;
    signIn();
    await source.image(gallery.pages[1], galleryID: 3000, thumbnail: false);
    expect(fixture.requests.any((url) => url.path.startsWith('/fullimg/')), isFalse, reason: 'Originals load only when chosen');

    KeyedCatalogSource.setLoadsOriginals(true, host: 'keyed.example');
    addTearDown(() => KeyedCatalogSource.setLoadsOriginals(false, host: 'keyed.example'));
    final original = await source.image(gallery.pages[0], galleryID: 3000, thumbnail: false);
    expect(original, List.filled(96, 0x77));

    fixture.grantsOriginals = false;
    final resized = await MangaContentSource(transport: fixture.transport()).image(gallery.pages[2], galleryID: 3000, thumbnail: false);
    expect(resized, fixture.image, reason: 'A page whose original the website keeps for GP shows resized');
  });

  test('the chosen settings profile is sent with every page', () async {
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    await source.list(const GalleryQuery(language: 'all'), offset: 0, count: 3);
    signIn();
    final profiles = await source.settingsProfiles();
    expect(profiles, const [SiteSettingsProfile(1, 'Default Profile', selected: true), SiteSettingsProfile(2, 'Reading in the App')]);
    await source.useSettingsProfile(2);
    final chosen = await source.settingsProfiles();
    expect(chosen.where((profile) => profile.selected).first.id, 2);
    expect(fixture.cookies.last.contains('sp=2'), isTrue);
  });

  test('favorites keep their note and a refused change is reported', () async {
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    await source.list(const GalleryQuery(language: 'all'), offset: 0, count: 1);
    expect(
      SiteAccount.signIn(const [
        SiteCookie(name: 'app_member_id', value: '42'),
        SiteCookie(name: 'app_pass_hash', value: 'secret'),
      ], host: MangaUrls.configuredHost),
      isTrue,
    );
    fixture.favoriteNote = 'read later &amp; 다시';
    await source.setAccountFavorite(3000, saved: true, category: 2);
    expect(
      fixture.favoriteForms.last,
      'favcat=2&favnote=read+later+%26+%EB%8B%A4%EC%8B%9C&apply=Add+to+Favorites&update=1',
      reason: 'Moving a favorite sends its note back so the site keeps it',
    );
    fixture.favoriteReply = 'Key missing, or incorrect key provided.';
    await expectLater(source.setAccountFavorite(3000, saved: false), throwsA(ContentError.galleryNotFound));
    expect(KeyedCatalogSource.favoriteNote('<textarea name="favnote">a &lt;b&gt;</textarea>'), 'a <b>');
  });

  test('viewer accounts keep the previews their work page shows', () {
    final shown = KeyedCatalogSource.viewerPreviews(viewerDetail(3000), galleryID: 3000);
    expect(shown[1], KeyedThumb(Uri.parse('https://sheets.example/3000-0.png'), const CropRect(100, 0, 100, 150)));
    const viewer =
        r'<script>var imagelist = [{"n":"one.jpg","k":"aaaaaaaaaa","t":"(https://sheets.example/3000-0.png) -0px 0"},{"n":"two.jpg","k":"bbbbbbbbbb","t":"https:\/\/sheets.example\/large-2.jpg"}];</script>';
    final entries = KeyedCatalogSource.viewerEntries(viewer, previews: shown);
    expect(entries[0]?.thumb, shown[0], reason: "A listed preview that is not a plain address takes the work page's");
    expect(entries[1]?.thumb?.url.toString(), 'https://sheets.example/large-2.jpg', reason: 'A plain listed address still wins');
  });

  test('viewer and page links open in the app', () {
    expect(GalleryIDParser.parse('https://keyed.example/mpv/3000/${key(3000)}/#page2'), [3000]);
    expect(GalleryKeys.shared.key(3000), key(3000), reason: "A viewer link carries the work's key");
    expect(GalleryIDParser.parse('see https://keyed.example/s/abcdef1234/3001-5'), [3001]);
    expect(GalleryKeys.shared.key(3001), isNull, reason: "A page link's key belongs to the page, not the work");
    expect(ContentRoute.initial('https://keyed.example/mpv/3000/${key(3000)}/'), isA<GalleryRoute>().having((route) => route.id, 'id', 3000));
    expect(
      ContentRoute.initial('https://keyed.example/s/abcdef1234/3001-5'),
      isA<ReaderRoute>().having((route) => route.id, 'id', 3001).having((route) => route.page, 'page', 5),
    );
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
      ], host: MangaUrls.configuredHost),
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
    expect(
      SiteAccount.signIn(const [
        SiteCookie(name: 'app_member_id', value: '42'),
        SiteCookie(name: 'app_pass_hash', value: 'secret'),
      ], host: MangaUrls.configuredHost),
      isTrue,
    );
    final first = await source.accountFavorites();
    expect(first.$1, [2998, 2990]);
    expect(first.$2, '2990');
    final last = await source.accountFavorites(after: first.$2);
    expect(last.$1, [2980]);
    expect(last.$2, isNull);
    expect(source.cachedPreview(2980), isNotNull, reason: 'Imported favorites carry their titles and tags');

    await source.setAccountFavorite(3000, saved: true);
    await source.setAccountFavorite(3000, saved: false);
    expect(fixture.favoriteForms, [
      'favcat=0&favnote=&apply=Add+to+Favorites&update=1',
      'favcat=favdel&favnote=&apply=Apply+Changes&update=1',
    ], reason: 'Removing sends the submit button the form shows for it');
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

  test('accounts reading in the multi-page viewer open works from its page list', () async {
    final fixture = KeyedFixture(), source = MangaContentSource(transport: fixture.transport());
    await source.list(const GalleryQuery(language: 'all'), offset: 0, count: 3);
    fixture.viewer = true;
    final gallery = await source.gallery(3000);
    expect(gallery.pages.map((page) => page.name), ['one.jpg', 'two & three.jpg', '3']);
    expect(gallery.pages[1].thumbnailURL.toString(), 'https://sheets.example/large-2.jpg');
    expect(fixture.count('/mpv/3000/${key(3000)}/'), 1);
    expect(await source.image(gallery.pages[1], galleryID: 3000, thumbnail: false), fixture.image);
    expect(fixture.requests.any((url) => url.path == '/s/bbbbbbbbbb/3000-2'), isTrue, reason: 'Each page opens with the key the viewer lists for it');
    expect(await source.image(gallery.pages[1], galleryID: 3000, thumbnail: true), fixture.image);
  });

  test('large previews are whole images', () {
    const page =
        '<div id="gdt" class="gt200"><a href="https://keyed.example/s/1111111111/3000-1"><div title="Page 1: one.jpg" style="width:200px;height:283px;background:transparent url(https://sheets.example/large-1.webp) 0 0 no-repeat"></div></a></div>';
    final entry = KeyedCatalogSource.entries(page, 3000)[0];
    expect(entry?.thumb, KeyedThumb(Uri.parse('https://sheets.example/large-1.webp'), null));
    expect(entry?.name, 'one.jpg');
    const relative =
        '<a href="https://keyed.example/s/1111111111/3000-1"><div title="Page 1: one.jpg" style="width:100px;height:150px;background:transparent url(/t/sheet.jpg) -100px 0 no-repeat"></div></a>';
    final resolved = KeyedCatalogSource.entries(relative, 3000)[0]?.thumb;
    expect(
      resolved,
      KeyedThumb(Uri.parse('https://keyed.example/t/sheet.jpg'), const CropRect(100, 0, 100, 150)),
      reason: 'A preview starting at the root belongs to the page link beside it',
    );
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
