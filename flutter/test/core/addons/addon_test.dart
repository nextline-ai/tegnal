// Ported from native-ios/TEGNALTests/AddonTests.swift.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/addons/addon_models.dart';
import 'package:tegnal/core/addons/addon_store.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/challenge/challenge_models.dart';
import 'package:tegnal/core/challenge/challenge_store.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/study/study_models.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/presentation/content/gallery_preview_models.dart';

final _rlo = String.fromCharCode(0x202E), _lri = String.fromCharCode(0x2066);

typedef Json = Map<String, Object?>;

List<int> _file(Json contents, {Json extra = const {}, String id = 'maker.sample-pack', String version = '1.0.0'}) => utf8.encode(
  jsonEncode({
    'format': 'tegnal-addon',
    'schemaVersion': 1,
    'id': id,
    'version': version,
    'name': {'en': 'Sample Pack', 'ko': '샘플 팩'},
    'author': 'Maker',
    'contents': contents,
    ...extra,
  }),
);

Json _translations([Map<String, String>? entries, String language = 'ko']) => {
  'tagTranslations': {
    'language': language,
    'entries': entries ?? {'long_hair': '긴 머리', 'female:glasses': '안경'},
  },
};

Json _trackJson() => {
  'title': {'ko': '배경 트랙'},
  'summary': {'ko': '배경을 배웁니다'},
  'color': '2F9E6E',
  'symbol': 'mountain.2',
  'groups': [
    {
      'id': 'places',
      'title': {'ko': '장소'},
      'tags': [
        {
          'name': 'lighthouse',
          'ko': '등대',
          'note': {'ko': '바닷가의 등대'},
        },
      ],
    },
  ],
  'sections': [
    {
      'id': 'one',
      'title': {'ko': '첫 구간'},
      'summary': {'ko': '요약'},
      'color': '2F9E6E',
      'lessons': [
        {
          'id': 'intro',
          'kind': 'concept',
          'symbol': 'book',
          'title': {'ko': '소개'},
          'bogus': 'dropped',
          'steps': [
            {
              'card': {
                'title': {'ko': '안녕'},
                'body': {'ko': '배경 이야기'},
              },
            },
            {
              'ask': {
                'question': {'ko': '질문'},
                'choices': [
                  {'ko': '가'},
                  {'ko': '나'},
                ],
                'answer': 0,
                'why': {'ko': '이유'},
              },
            },
          ],
        },
        {
          'id': 'tags',
          'kind': 'tags',
          'symbol': 'tag',
          'title': {'ko': '태그'},
          'tags': ['lighthouse', 'long_hair'],
        },
      ],
    },
  ],
};

Json _track() => {'learningTrack': _trackJson()};

Json _game(String id, {void Function(ChallengeDefinition)? change}) {
  final game = ChallengeDefinition.croquis()..id = id;
  change?.call(game);
  return jsonDecode(jsonEncode(game.toJson())) as Json;
}

void _refused(List<int> data, [AddonError? error]) {
  expect(() => Addon.decode(data), throwsA(error == null ? isA<AddonError>() : equals(error)));
}

InstalledAddon _installed(Addon addon, {bool enabled = true, int at = 0}) =>
    InstalledAddon(addon: addon, enabled: enabled, installed: DateTime.fromMillisecondsSinceEpoch(at * 1000), digest: '');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StudyCurriculum bundled;

  setUpAll(() {
    bundled = StudyCurriculum.parse(File('assets/study/TagStudy.json').readAsStringSync());
    StudyCurriculum.useBundled(bundled);
  });
  tearDownAll(() => StudyCurriculum.useBundled(null));
  tearDown(() => AddonRuntime.shared.apply(AddonEffects()));

  // MARK: Files

  test('a valid file decodes with its fingerprint and fills in English', () {
    final data = _file({..._translations(), ..._track()});
    final (:addon, :digest) = Addon.decode(data);
    expect(addon.id, 'maker.sample-pack');
    expect(addon.contents.kinds, [AddonKind.translations, AddonKind.track]);
    expect(digest, Addon.digest(data));
    expect(digest.length, 64);
    // Text written in Korean only gets an English wording too, so that it is never blank.
    expect(addon.contents.learningTrack!.title['en'], '배경 트랙');
    final card = (addon.contents.learningTrack!.lessons.first['steps']! as List).first as Map;
    expect((card['card'] as Map)['title'], containsPair('en', '안녕'));
  });

  test('files that are not add-ons or are newer are refused', () {
    _refused(utf8.encode('[]'), const AddonError.notAddon());
    _refused(utf8.encode('{"format":"tegnal-challenges"}'), const AddonError.notAddon());
    final newer = jsonDecode(utf8.decode(_file(_translations()))) as Json..['schemaVersion'] = 2;
    _refused(utf8.encode(jsonEncode(newer)), const AddonError.newerFormat());
    _refused(List.filled(Addon.maximumBytes + 1, 0), const AddonError.tooLarge());
    _refused(_file({}), const AddonError.empty());
  });

  test('anything not understood is refused rather than skipped', () {
    _refused(_file(_translations(), extra: {'script': 'alert(1)'}), const AddonError.unknownContent('script'));
    _refused(_file({..._translations(), 'themes': <String, Object?>{}}), const AddonError.unknownContent('themes'));
  });

  test('identifiers, versions and hidden characters are checked', () {
    _refused(_file(_translations(), id: 'Bad Id'));
    _refused(_file(_translations(), id: '../escape'));
    _refused(_file(_translations(), version: '1.0-beta'));
    // A direction override can make a name read as something else.
    _refused(_file(_translations(), extra: {'author': 'Mak${_rlo}er'}));
    _refused(_file(_translations({'long_hair': '긴\u0007머리'})));
    _refused(_file(_translations({'long_hair': '두 줄\n번역'})));
    _refused(_file(_translations({'long_hair': 'x'}, 'fr')));
    // Emoji joined with a zero-width joiner stay allowed.
    expect(() => Addon.decode(_file(_translations({'family': '👨‍👩‍👧'}))), returnsNormally);
    expect(AddonCheck.compare('1.10', '1.9'), greaterThan(0));
    expect(AddonCheck.compare('2', '2.0.0'), 0);
  });

  test('unicode property escapes catch every kind of hidden character', () {
    for (final code in [0x202E, 0x2066, 0x200B, 0x07, 0x2028, 0x2029, 0xE000, 0x0378]) {
      final text = 'a${String.fromCharCode(code)}b';
      expect(AddonCheck.line(text, max: 20), isFalse, reason: text.runes.map((r) => r.toRadixString(16)).join(' '));
    }
    expect(AddonCheck.line('a\nb', max: 20, multiline: true), isTrue);
    expect(AddonCheck.line('a\nb', max: 20), isFalse);
    expect(AddonCheck.line('긴 머리 ひらがな', max: 20), isTrue);
  });

  test('one tag has one translation', () {
    _refused(_file(_translations({'Long_Hair': '긴 머리', 'long hair': '장발'})));
    _refused(_file(_translations({'hair*': 'x'})));
  });

  test('search tags cannot widen or rewrite a search', () {
    List<int> search(Json value) => _file({'searchTags': value});
    expect(
      () => Addon.decode(
        search({
          'comics': {
            'include': ['language:korean'],
            'exclude': ['tag:gore', 'female:guro'],
          },
          'images': {
            'exclude': ['gore', 'blood -scenery', 'rating:explicit', 'artist:someone'],
          },
        }),
      ),
      returnsNormally,
    );
    _refused(
      search({
        'comics': {
          'include': ['two words'],
        },
      }),
    );
    _refused(
      search({
        'comics': {
          'include': ['-gore'],
        },
      }),
    );
    _refused(
      search({
        'comics': {
          'include': ['"quoted"'],
        },
      }),
    );
    _refused(
      search({
        'comics': {
          'include': ['unknown:space'],
        },
      }),
    );
    // A rule starting with a minus would hide everything else.
    _refused(
      search({
        'images': {
          'exclude': ['-scenery'],
        },
      }),
    );
    // No wildcards.
    _refused(
      search({
        'images': {
          'exclude': ['a*b*c*d'],
        },
      }),
    );
    _refused(
      search({
        'images': {
          'exclude': ['id:123'],
        },
      }),
    );
    _refused(
      search({
        'images': {
          'exclude': ['rating:whatever'],
        },
      }),
    );
    // Nothing to add.
    _refused(
      search({
        'comics': {'include': <String>[]},
      }),
    );
  });

  test('track cards cannot open anything and tag lessons need meanings', () {
    final track = _trackJson();
    final sections = <Json>[...(track['sections']! as List).cast<Json>()];
    final lessons = <Json>[...(sections[0]['lessons']! as List).cast<Json>()];
    sections[0] = {...sections[0], 'lessons': lessons};
    track['sections'] = sections;
    final intro = Map<String, Object?>.of(lessons[0]);
    lessons[0] = {
      ...intro,
      'steps': [
        {
          'card': {
            'title': {'en': 'Go'},
            'body': {'en': 'Spend'},
            'code': '1girl',
            'action': 'generator',
          },
        },
      ],
    };
    _refused(_file({'learningTrack': track})); // Cards in add-ons only tell.

    lessons[0] = intro;
    lessons[1] = {
      ...lessons[1],
      'tags': ['lighthouse', 'not_a_known_tag_anywhere'],
    };
    _refused(_file({'learningTrack': track})); // Every tag needs a meaning.
  });

  test('challenges follow the challenge rules and the add-on text rules', () {
    expect(
      () => Addon.decode(
        _file({
          'challenges': [_game('sketch')],
        }),
      ),
      returnsNormally,
    );
    _refused(
      _file({
        'challenges': [_game('sketch', change: (game) => game.title = 'Sketch$_lri')],
      }),
    );
    _refused(
      _file({
        'challenges': [
          _game('sketch', change: (game) => game.reels[0].options[0].tags = ['rating:explicit']),
        ],
      }),
    );
  });

  // MARK: Store and effects

  test('installing, turning off and removing takes everything back', () {
    final booru = BooruStore.inMemory();
    final store = AddonStore(booru.database);
    final (:addon, :digest) = Addon.decode(
      _file({
        ..._translations(),
        'challenges': [_game('sketch')],
        'searchTags': {
          'comics': {
            'exclude': ['tag:gore'],
          },
          'images': {
            'exclude': ['blood'],
          },
        },
      }),
    );
    store.install(addon, digest: digest);
    AddonRuntime.shared.reload(booru);

    final runtime = AddonRuntime.shared;
    expect(runtime.translation('long_hair'), '긴 머리');
    expect(runtime.translation('Long Hair'), '긴 머리');
    expect(runtime.translation('female:glasses'), '안경');
    expect(runtime.translation('tag:long_hair'), '긴 머리', reason: 'A namespaced tag falls back to its name');
    expect(runtime.translation('short_hair'), isNull);
    final group = ArtworkTagGroup.make(tags: ['long_hair']).first.tags.first;
    expect(group.name, '긴 머리');
    expect(group.query, 'long_hair', reason: 'Searches still use the tag itself');
    expect(group.original, 'long hair');

    booru.setBlacklist('spoilers', serverID: 's');
    expect(booru.filteringBlacklist('s'), 'spoilers\nblood');
    expect(booru.blacklist('s'), 'spoilers', reason: "The learner's own list never holds an add-on's rules");

    final content = ContentEnvironment(browserPreferences: MemoryPreferences());
    content.defaultTags = 'language:english';
    expect(content.searchDefaultTags, 'language:english');
    expect(content.searchExcludedTags.split(' '), contains('tag:gore'));
    expect(content.defaultExcludedTags.contains('tag:gore'), isFalse);

    final challenges = ChallengeStore(booru);
    expect(challenges.definitions().map((game) => game.id), ['addon:maker.sample-pack:sketch']);

    store.setEnabled(addon.id, false);
    AddonRuntime.shared.reload(booru);
    expect(runtime.translation('long_hair'), isNull);
    expect(booru.filteringBlacklist('s'), 'spoilers');
    expect(content.searchExcludedTags.contains('tag:gore'), isFalse);
    expect(challenges.definitions(), isEmpty, reason: 'A challenge of an add-on that is off is hidden');

    store.setEnabled(addon.id, true);
    expect(challenges.definitions().length, 1);
    store.remove(addon.id);
    AddonRuntime.shared.reload(booru);
    expect(store.installed(), isEmpty);
    expect(booru.database.read((db) => db.value<int>('SELECT COUNT(*) FROM challenges')), 0);
    expect(runtime.effects.enabledIDs, isEmpty);
  });

  test('an update keeps the on/off choice and drops challenges it no longer has', () {
    final booru = BooruStore.inMemory();
    final store = AddonStore(booru.database);
    final old = Addon.decode(
      _file({
        'challenges': [_game('first'), _game('second')],
      }),
    );
    store.install(old.addon, digest: old.digest);
    store.setEnabled(old.addon.id, false);
    final updated = Addon.decode(
      _file({
        'challenges': [_game('second')],
      }, version: '1.1'),
    );
    store.install(updated.addon, digest: updated.digest);
    final installed = store.installed();
    expect(installed.map((item) => item.addon.version), ['1.1']);
    expect(installed.first.enabled, isFalse);
    expect(booru.database.read((db) => db.column<String>('SELECT id FROM challenges')), ['addon:maker.sample-pack:second']);
  });

  test('tracks are parsed and listed only for add-ons that are on', () {
    final (:addon, digest: _) = Addon.decode(_file(_track()));
    final track = addon.contents.learningTrack!;
    expect(track.sections.length, 1);
    expect(track.lessons.map((lesson) => lesson['id']), ['intro', 'tags']);
    expect(track.lessons.every((lesson) => !lesson.containsKey('bogus')), isTrue, reason: 'Unknown keys are dropped from the kept copy');
    expect(track.groups!.single.tags.single.name, 'lighthouse');
    expect(((addon.json['contents']! as Map)['learningTrack']! as Map)['sections'], isA<List>());
    expect(bundled.tag('long_hair'), isNotNull, reason: "The app's own tags stay");

    expect(AddonEffects([_installed(addon)]).tracks.map((item) => item.id), ['maker.sample-pack']);
    expect(AddonEffects([_installed(addon, enabled: false)]).tracks, isEmpty);
    final plain = Addon.decode(_file(_translations(), id: 'maker.plain')).addon;
    expect(AddonEffects([_installed(plain)]).tracks, isEmpty, reason: 'Only add-ons with tracks are listed');
    expect(AddonEffects.lessonID('maker.sample-pack', 'intro'), 'addon:maker.sample-pack:intro');
  });

  test('later add-ons win when two translate the same tag', () {
    final first = Addon.decode(_file(_translations({'long_hair': '긴 머리'}), id: 'maker.first')).addon;
    final second = Addon.decode(_file(_translations({'long_hair': '장발'}), id: 'maker.second')).addon;
    final effects = AddonEffects([_installed(second, at: 2), _installed(first, at: 1)]);
    expect(effects.translation('long_hair'), '장발');
  });

  test('the sample add-ons in the docs folder pass', () async {
    final candidates = ['/Users/juhyungpark/Programming/tegnal/docs/addons', '../docs/addons'];
    final folder = candidates.map(Directory.new).where((directory) => directory.existsSync()).firstOrNull;
    final files = folder?.listSync().whereType<File>().where((file) => file.path.endsWith('.${Addon.fileExtension}')).toList() ?? [];
    if (files.isEmpty) {
      markTestSkipped('The samples are local only');
      return;
    }
    for (final file in files) {
      await expectLater(Addon.read(file), completes, reason: file.path);
    }
  });
}
