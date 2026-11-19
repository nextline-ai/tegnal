// Ported from the official add-on tests in native-ios/TEGNALTests/AddonTests.swift.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/addons/addon_market.dart';
import 'package:tegnal/core/addons/addon_models.dart';
import 'package:tegnal/core/addons/addon_store.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/study/study_models.dart';

import '../../support/addon_market_fixtures.dart';

typedef Json = Map<String, Object?>;

List<int> _file({Json extra = const {}, String id = 'maker.sample-pack', String version = '1.0.0'}) => utf8.encode(
  jsonEncode({
    'format': 'tegnal-addon',
    'schemaVersion': 1,
    'id': id,
    'version': version,
    'name': {'en': 'Sample Pack'},
    'author': 'Maker',
    'contents': {
      'tagTranslations': {
        'language': 'ko',
        'entries': {'long_hair': '긴 머리'},
      },
    },
    ...extra,
  }),
);

Json _listing(List<int> data, {String id = 'maker.sample-pack', String version = '1.0.0'}) => {
  'id': id,
  'version': version,
  'name': {'en': 'Sample Pack'},
  'author': 'TEGNAL',
  'kinds': ['translations'],
  'size': data.length,
  'sha256': Addon.digest(data),
};

void main() {
  setUpAll(() => StudyCurriculum.useBundled(StudyCurriculum.parse(File('assets/study/TagStudy.json').readAsStringSync())));

  test('only a catalog signed with the key is read, and bad entries are left out', () {
    final key = TestSigningKey(), other = TestSigningKey();
    final addon = _file();
    final broken = {..._listing(addon, id: 'maker.broken'), 'sha256': 'XYZ'};
    final data = utf8.encode(
      jsonEncode({
        'format': 'tegnal-addon-catalog',
        'schemaVersion': 1,
        'addons': [
          _listing(addon),
          _listing(addon),
          broken,
          {'id': 5},
          {..._listing(addon, id: 'maker.later'), 'schemaVersion': 9},
        ],
      }),
    );
    final signature = key.sign(data);
    final read = AddonMarket.verify(data, signature, key.public);
    expect(read.addons.map((entry) => entry.id), ['maker.sample-pack', 'maker.later'], reason: 'Duplicates and broken entries are left out');
    expect(AddonListingState.of(read.addons.last, null), AddonListingState.unsupported);

    expect(() => AddonMarket.verify(data, signature, other.public), throwsA(const AddonMarketError.unsigned()));
    final tampered = [...data]..[data.length - 2] ^= 1;
    expect(() => AddonMarket.verify(tampered, signature, key.public), throwsA(const AddonMarketError.unsigned()));
    expect(() => AddonMarket.verify(data, utf8.encode('nope'), key.public), throwsA(const AddonMarketError.unsigned()));
  });

  test('a download is installed only when it matches the catalog', () async {
    final key = TestSigningKey();
    final addon = _file();
    final data = utf8.encode(
      jsonEncode({
        'format': 'tegnal-addon-catalog',
        'schemaVersion': 1,
        'addons': [_listing(addon)],
      }),
    );
    final envelope = utf8.encode(jsonEncode({'payload': base64.encode(data), 'signature': base64.encode(key.sign(data))}));
    final served = <String, List<int>>{'catalog.json': envelope, 'files/maker.sample-pack/1.0.0.tegnaladdon': addon};
    final base = Uri.parse('https://addons.invalid/v1/');
    AddonMarket market() => AddonMarket(
      base: base,
      publicKey: key.public,
      fetch: (url, limit) async {
        final file = served[url.toString().substring(base.toString().length)];
        if (file == null) throw const AddonMarketError.server(404);
        if (file.length > limit) throw const AddonMarketError.damaged();
        return file;
      },
    );
    final catalog = await market().catalog();
    final entry = catalog.addons.single;
    final read = await market().download(entry);
    expect(read.addon.id, 'maker.sample-pack');
    expect(read.digest, entry.sha256);

    served['files/maker.sample-pack/1.0.0.tegnaladdon'] = [...addon]..[addon.length - 3] = 0x20;
    await expectLater(market().download(entry), throwsA(const AddonMarketError.damaged()));

    // A file signed into the catalog under another add-on's name is refused too.
    final renamed = AddonListing.fromJson({..._listing(addon), 'id': 'maker.other'})!;
    expect(() => AddonMarket.check(addon, renamed), throwsA(const AddonMarketError.damaged()));
  });

  test('official copies are marked and a file copy is not', () {
    final store = AddonStore(BooruStore.inMemory().database);
    final data = _file();
    final official = Addon.decode(data);
    store.install(official.addon, digest: official.digest, official: true);
    final entry = AddonListing.fromJson(_listing(data))!;
    expect(store.installed().first.official, isTrue);
    expect(AddonListingState.of(entry, store.installed().first), AddonListingState.installed);

    final newer = AddonListing.fromJson({..._listing(data), 'version': '1.1.0', 'sha256': 'a' * 64})!;
    expect(AddonListingState.of(newer, store.installed().first), AddonListingState.update);

    final copy = Addon.decode(
      _file(
        extra: {
          'summary': {'en': 'Edited'},
        },
      ),
    );
    store.install(copy.addon, digest: copy.digest);
    expect(store.installed().first.official, isFalse, reason: 'A file opened by hand replaces the official mark');
    expect(AddonListingState.of(entry, store.installed().first), AddonListingState.fromFile);
    expect(AddonListingState.of(entry, null), AddonListingState.get);
  });

  test('the live key decodes', () {
    expect(AddonMarket.live.publicKey.Q, isNotNull);
  });

  test('the published catalog in the docs folder verifies with the app key', () {
    final candidates = ['/Users/juhyungpark/Programming/tegnal/docs/addons/market/dist/v1', '../docs/addons/market/dist/v1'];
    final folder = candidates.map(Directory.new).where((directory) => File('${directory.path}/catalog.json').existsSync()).firstOrNull;
    if (folder == null) {
      markTestSkipped('The published catalog is local only');
      return;
    }
    final catalog = AddonMarket.open(File('${folder.path}/catalog.json').readAsBytesSync(), AddonMarket.live.publicKey);
    expect(catalog.addons, isNotEmpty);
    for (final entry in catalog.addons) {
      expect(() => AddonMarket.check(File('${folder.path}/${entry.path}').readAsBytesSync(), entry), returnsNormally, reason: entry.id);
    }
  });
}
