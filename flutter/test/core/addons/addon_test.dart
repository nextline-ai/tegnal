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
import 'package:tegnal/core/study/study_path.dart';
import 'package:tegnal/core/taste/taste_models.dart' show TasteMode;
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/presentation/content/gallery_preview_models.dart';
import 'package:tegnal/presentation/navigation/app_state.dart' show AppMode;

final _rlo = String.fromCharCode(0x202E), _lri = String.fromCharCode(0x2066);

typedef Json = Map<String, Object?>;

List<int> _file(Json contents, {Json extra = const {}, String id = 'maker.sample-pack', String version = '1.0.0', String mode = 'images'}) => utf8.encode(
  jsonEncode({
    'format': 'tegnal-addon',
    'schemaVersion': 1,
    'id': id,
    'version': version,
    'mode': mode,
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
    List<int> search(Json value) => _file({'searchTags': value}, mode: value['images'] == null ? 'comics' : 'images');
    expect(
      () => Addon.decode(
        search({
          'comics': {
            'include': ['language:korean'],
            'exclude': ['tag:gore', 'female:guro'],
          },
        }),
      ),
      returnsNormally,
    );
    expect(
      () => Addon.decode(
        search({
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
          'images': {
            'exclude': ['blood'],
          },
        },
      }),
    );
    store.install(addon, digest: digest);
    AddonRuntime.shared.reload(booru);

    final runtime = AddonRuntime.shared;
    expect(runtime.translation('long_hair', AddonMode.images), '긴 머리');
    expect(runtime.translation('Long Hair', AddonMode.images), '긴 머리');
    expect(runtime.translation('female:glasses', AddonMode.images), '안경');
    expect(runtime.translation('tag:long_hair', AddonMode.images), '긴 머리', reason: 'A namespaced tag falls back to its name');
    expect(runtime.translation('short_hair', AddonMode.images), isNull);
    expect(runtime.translation('long_hair', AddonMode.comics), isNull, reason: 'An image add-on never renames comics tags');
    expect(runtime.effects.enabledCount(AddonMode.images), 1);
    expect(runtime.effects.enabledCount(AddonMode.comics), 0);
    expect(ArtworkTagGroup.make(tags: ['long_hair'], mode: AddonMode.comics).first.tags.first.original, isNull);
    final group = ArtworkTagGroup.make(tags: ['long_hair'], mode: AddonMode.images).first.tags.first;
    expect(group.name, '긴 머리');
    expect(group.query, 'long_hair', reason: 'Searches still use the tag itself');
    expect(group.original, 'long hair');

    booru.setBlacklist('spoilers', serverID: 's');
    expect(booru.filteringBlacklist('s'), 'spoilers\nblood');
    expect(booru.blacklist('s'), 'spoilers', reason: "The learner's own list never holds an add-on's rules");

    final content = ContentEnvironment(browserPreferences: MemoryPreferences());
    content.defaultTags = 'language:english';
    expect(content.searchDefaultTags, 'language:english');

    final challenges = ChallengeStore(booru);
    expect(challenges.definitions().map((game) => game.id), ['addon:maker.sample-pack:sketch']);

    store.setEnabled(addon.id, false);
    AddonRuntime.shared.reload(booru);
    expect(runtime.translation('long_hair', AddonMode.images), isNull);
    expect(booru.filteringBlacklist('s'), 'spoilers');
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

  test('a track becomes a path of its own, under the add-on, with its tags as a unit after the app\'s', () {
    final addon = Addon.decode(_file(_track())).addon;
    final track = AddonEffects([_installed(addon)]).tracks.single;
    expect(track.id, 'maker.sample-pack');
    expect(track.title, addon.contents.learningTrack!.title);
    expect(track.title['ko'], '배경 트랙');
    expect(track.summary['ko'], '배경을 배웁니다');
    expect(track.color, '2F9E6E');
    expect(track.symbol, 'mountain.2', reason: 'Every name is kept until the app says which it can draw');
    expect(track.path.version, 3);
    expect(track.path.sections.single.id, 'addon:maker.sample-pack:one');
    expect(track.path.sections.single.color, '2F9E6E');
    expect(track.path.lessons.map((lesson) => lesson.id), ['addon:maker.sample-pack:intro', 'addon:maker.sample-pack:tags']);
    expect(track.path.lessons.map((lesson) => lesson.id), [AddonEffects.lessonID(addon.id, 'intro'), AddonEffects.lessonID(addon.id, 'tags')]);
    expect(track.path.lessons.first.kind, StudyPathLessonKind.concept);
    expect(track.path.lessons.first.steps!.length, 2);
    expect(track.path.lessons.first.steps!.first.card!.title['ko'], '안녕');
    expect(track.path.lessons.last.tags, ['lighthouse', 'long_hair']);
    expect(track.unit!.id, 'addon:maker.sample-pack');
    expect(track.unit!.title, track.title);
    expect(track.unit!.tags.map((tag) => tag.name), ['lighthouse']);

    expect(track.complete({}), isFalse);
    final intro = StudyLessonRecord(lesson: track.path.lessons.first.id, stars: 3, runs: 1);
    expect(track.complete({intro.lesson: intro}), isFalse);
    final tags = StudyLessonRecord(lesson: track.path.lessons.last.id, stars: 1, runs: 1);
    expect(track.complete({intro.lesson: intro, tags.lesson: tags}), isTrue);
    expect(StudyTrack(id: 'empty', title: const {}, summary: const {}, color: '000000', symbol: 'book', path: const StudyPath()).complete({}), isFalse);
  });

  test('a track with no tags of its own brings no unit, and its unknown symbols give way to stand-ins', () {
    final json = (jsonDecode(jsonEncode(_trackJson())) as Json)..remove('groups');
    final sections = json['sections']! as List;
    final lessons = (sections.single as Json)['lessons']! as List;
    lessons.removeLast();
    final steps = (lessons.single as Json)['steps']! as List;
    (steps.first as Json)['card'] = {
      'title': {'ko': '안녕'},
      'body': {'ko': '배경 이야기'},
      'symbol': 'no.such.symbol',
    };
    final addon = Addon.decode(_file({'learningTrack': json})).addon;
    final previous = AddonEffects.symbolExists;
    addTearDown(() => AddonEffects.symbolExists = previous);
    AddonEffects.symbolExists = (name) => name == 'tag';
    final track = AddonEffects([_installed(addon)]).tracks.single;
    expect(track.unit, isNull);
    expect(track.symbol, 'graduationcap.fill');
    expect(track.path.lessons.single.symbol, 'book.fill');
    final card = track.path.lessons.single.steps!.first.card!;
    expect(card.symbol, 'sparkles');
    expect(card.action, isNull);

    AddonEffects.symbolExists = (name) => true;
    final kept = AddonEffects([_installed(addon)]).tracks.single;
    expect(kept.path.lessons.single.symbol, 'book');
    expect(kept.path.lessons.single.steps!.first.card!.symbol, 'no.such.symbol');
    expect(kept.path.lessons.single.steps!.first.card!.action, isNull);
  });

  test('tracks follow the order the add-ons were installed in', () {
    final first = Addon.decode(_file(_track(), id: 'maker.first')).addon;
    final second = Addon.decode(_file(_track(), id: 'maker.second')).addon;
    final effects = AddonEffects([_installed(second, at: 2), _installed(first, at: 1)]);
    expect(effects.tracks.map((track) => track.id), ['maker.first', 'maker.second']);
    expect(effects.tracks.last.path.lessons.first.id, 'addon:maker.second:intro');
  });

  test('later add-ons win when two translate the same tag', () {
    final first = Addon.decode(_file(_translations({'long_hair': '긴 머리'}), id: 'maker.first')).addon;
    final second = Addon.decode(_file(_translations({'long_hair': '장발'}), id: 'maker.second')).addon;
    final effects = AddonEffects([_installed(second, at: 2), _installed(first, at: 1)]);
    expect(effects.translation('long_hair', AddonMode.images), '장발');
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

  // MARK: Modes and grades

  test('comics and image add-ons stay apart', () {
    _refused(_file(_translations(), mode: 'both'), const AddonError.invalid('mode'));
    final noMode = jsonDecode(utf8.decode(_file(_translations()))) as Json..remove('mode');
    _refused(utf8.encode(jsonEncode(noMode)), const AddonError.invalid('mode'));
    _refused(_file(_track(), mode: 'comics'), const AddonError.invalid('learningTrack'));
    _refused(
      _file({
        'challenges': [_game('sketch')],
      }, mode: 'comics'),
      const AddonError.invalid('challenges'),
    );
    _refused(
      _file({
        'searchTags': {
          'images': {
            'exclude': ['gore'],
          },
        },
      }, mode: 'comics'),
      const AddonError.invalid('searchTags.images'),
    );
    _refused(
      _file({
        'searchTags': {
          'comics': {
            'exclude': ['tag:gore'],
          },
        },
      }),
      const AddonError.invalid('searchTags.comics'),
    );
    expect(Addon.decode(_file(_translations())).addon.json['mode'], 'images', reason: 'The kept copy holds its mode');

    final comics = Addon.decode(
      _file(
        {
          ..._translations({'character:reimu_hakurei': '하쿠레이 레이무'}),
          'searchTags': {
            'comics': {
              'exclude': ['female:guro'],
            },
          },
        },
        id: 'maker.comics',
        mode: 'comics',
      ),
    ).addon;
    final images = Addon.decode(_file(_translations({'reimu_hakurei': '레이무'}), id: 'maker.images')).addon;
    final effects = AddonEffects([_installed(comics), _installed(images)]);
    expect(effects.translation('character:reimu hakurei', AddonMode.comics), '하쿠레이 레이무');
    expect(effects.translation('reimu_hakurei', AddonMode.images), '레이무');
    expect(effects.translation('hakurei', AddonMode.comics), isNull);
    expect(effects.comicsExclude, ['female:guro']);
    expect(effects.enabledCount(AddonMode.comics), 1);
    expect(effects.enabledCount(AddonMode.images), 1);
    expect(AddonMode.fromApp(AppMode.manga), AddonMode.comics);
    expect(AddonMode.fromTaste(TasteMode.booru), AddonMode.images);
    expect(const AddonError.otherMode(AddonMode.comics).errorDescription, contains('Comics Mode'));
    expect(const AddonError.otherMode(AddonMode.images).errorDescription, contains('Image Mode'));

    final booru = BooruStore.inMemory();
    final (addon: kept, :digest) = Addon.decode(
      _file({
        'searchTags': {
          'comics': {
            'exclude': ['tag:gore'],
          },
        },
      }, mode: 'comics'),
    );
    AddonStore(booru.database).install(kept, digest: digest);
    AddonRuntime.shared.reload(booru);
    addTearDown(() => AddonRuntime.shared.apply(AddonEffects()));
    expect(AddonStore(booru.database).installed().single.addon.mode, AddonMode.comics, reason: 'The mode is read back');
    final content = ContentEnvironment(browserPreferences: MemoryPreferences());
    expect(content.searchExcludedTags.split(' '), contains('tag:gore'));
    expect(content.defaultExcludedTags.contains('tag:gore'), isFalse);
  });

  // MARK: - Comics tag names and searches

  AddonEffects comicsTranslations() {
    final addon = Addon.decode(
      _file(
        _translations({'character:teitoku': '제독', 'tag:big_breasts': '큰 가슴', 'tag:glasses': '안경', 'series:kantai_collection': '함대 컬렉션', 'nakadashi': '질내 사정'}),
        id: 'maker.comics',
        mode: 'comics',
      ),
    ).addon;
    return AddonEffects([_installed(addon)]);
  }

  test('female and male tags use their general translation', () {
    final effects = comicsTranslations();
    expect(effects.translation('female:big breasts', AddonMode.comics), '큰 가슴', reason: 'female: falls back to the tag: name');
    expect(effects.translation('male:glasses', AddonMode.comics), '안경');
    expect(effects.translation('mixed:big_breasts', AddonMode.comics), '큰 가슴');
    expect(effects.translation('big breasts', AddonMode.comics), '큰 가슴', reason: 'A tag with no namespace finds its tag: name');
    expect(effects.translation('female:nakadashi', AddonMode.comics), '질내 사정', reason: 'A translation with no namespace still serves');
    expect(effects.translation('character:glasses', AddonMode.comics), isNull, reason: 'Only general namespaces borrow the tag: name');
    expect(effects.translation('character:teitoku', AddonMode.comics), '제독');
  });

  test('translated names are suggested and searched as their tags', () {
    final effects = comicsTranslations();
    expect(effects.tags(matching: '제', mode: AddonMode.comics).map((item) => item.tag), ['character:teitoku']);
    expect(effects.tags(matching: '가슴', mode: AddonMode.comics).map((item) => item.tag), ['tag:big_breasts'], reason: 'Korean words match inside a name too');
    expect(effects.tags(matching: '함대', mode: AddonMode.comics).first.words, '함대 컬렉션');
    expect(
      effects.tags(matching: '제', mode: AddonMode.images),
      isEmpty,
      reason: 'Comics names are not suggested in Image Mode',
    );

    expect(effects.searchQuery('제독 -안경', AddonMode.comics), 'character:teitoku -tag:glasses');
    expect(
      effects.searchQuery('큰 가슴 함대 컬렉션 english', AddonMode.comics),
      'tag:big_breasts series:kantai_collection english',
      reason: 'Names of several words are found',
    );
    expect(effects.searchQuery('glasses', AddonMode.comics), 'glasses', reason: 'English searches stay as typed');
    expect(effects.searchQuery('모르는말', AddonMode.comics), '모르는말');
    expect(effects.searchQuery('제독', AddonMode.images), '제독');

    final completion = AddonSearchCompletion.parse('language:korean -제')!;
    expect(completion.excluded, isTrue);
    expect(completion.term, '제');
    expect(completion.inserting('character:teitoku'), 'language:korean -character:teitoku ');
    expect(AddonSearchCompletion.parse('제독 '), isNull);
  });

  test('the official Korean comics names, as published, name the tags a work page shows, gender tags included', () async {
    final candidates = [
      '/Users/juhyungpark/Programming/tegnal/docs/addons/market/official/comics-tags-ko.tegnaladdon',
      '../docs/addons/market/official/comics-tags-ko.tegnaladdon',
    ];
    final file = candidates.map(File.new).where((file) => file.existsSync()).firstOrNull;
    if (file == null) {
      markTestSkipped('The official files are local only');
      return;
    }
    final (:addon, :digest) = await Addon.read(file);
    expect(addon.contents.tagTranslations!.entries.keys.where((key) => key.split(':').length > 2), isEmpty, reason: 'No key carries two namespaces');
    AddonRuntime.shared.apply(AddonEffects([InstalledAddon(addon: addon, enabled: true, installed: DateTime.now(), digest: digest)]));
    addTearDown(() => AddonRuntime.shared.apply(AddonEffects()));
    final tags = ArtworkTagGroup.make(
      tags: ['female:big breasts', 'male:sole male', 'character:reimu hakurei', 'series:touhou project', 'tag:full color'],
      mode: AddonMode.comics,
    ).expand((group) => group.tags);
    for (final tag in tags) {
      expect(tag.original, isNotNull, reason: '${tag.query} is shown in Korean');
      expect(RegExp(r'^(female|male|mixed|other|tag):').hasMatch(tag.name), isFalse, reason: '${tag.query} is shown without a namespace, got ${tag.name}');
    }
    expect(tags.firstWhere((tag) => tag.query == 'female:big breasts').name, '거유');
    expect(
      addon.contents.tagTranslations!.entries.values.where((words) => RegExp(r'^(female|male|mixed|other|tag):', caseSensitive: false).hasMatch(words)),
      isEmpty,
      reason: 'No shown name starts with a namespace',
    );
    expect(AddonRuntime.shared.effects.tags(matching: '거유', mode: AddonMode.comics).first.tag, 'female:big_breasts');
  });
}
