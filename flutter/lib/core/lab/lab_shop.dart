import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';

import '../addons/addon_market.dart';
import '../addons/addon_models.dart';
import 'lab_course.dart';

// The shop list, read from TEGNAL's server. Ported from `LabShop.swift`; format in `docs/features/live-shop.md`.

/// What 보석 buys. The list is not in the app: TEGNAL publishes it beside the add-ons (`v1/lab/shop.json`, signed with the
/// add-on key), and the app keeps the last copy it read. Goods that need files (course files, add-ons, home scenes) are
/// downloaded after they are bought and checked against the size and SHA-256 the signed list gives (`LabGoods`).
class LabShop {
  const LabShop({this.currency = defaultCurrency, this.note, required this.sections});

  static const format = 'tegnal-lab-shop';
  static const schemaVersion = 1;
  static const maximumBytes = 512 * 1024;
  static const defaultCurrency = LabText({'ko': '보석', 'en': 'Gems', 'ja': 'ジェム'});

  /// No list read yet: the currency's name, and nothing for sale.
  static const empty = LabShop(sections: []);

  /// What the app itself can sell while the server's list cannot be read (offline, or a list for a later app): the course it
  /// carries and the prompt analyzer (user, 2026-11-24). Their prices match the published list (`docs/live/shop.json`); a test
  /// keeps the two the same.
  static const builtIn = LabShop(
    sections: [
      LabShopSection(
        title: LabText({'ko': '코스', 'en': 'Courses', 'ja': 'コース'}),
        items: [
          LabShopItem(
            id: 'course.tags',
            kind: 'course',
            name: LabText({'ko': '2D AI 배우기', 'en': 'Learn 2D AI', 'ja': '2D AIを学ぶ'}),
            summary: LabText({'ko': 'AI로 그리는 2D 일러스트', 'en': '2D illustrations drawn with AI', 'ja': 'AIで描く2Dイラスト'}),
            symbol: 'paintbrush.pointed',
            price: 500,
            course: '2d-ai',
            color: '7C5CFF',
            detail: LabText({
              'ko': '실제 그림으로 태그를 익히고, 배운 프롬프트로 직접 그려 보는 코스입니다.\n\n- 레슨 62개, 섹션 11개\n- 레슨·별 세 개·섹션을 처음 마칠 때마다 보석\n- 배운 태그로 바로 그리는 생성기',
              'en': 'Learn tags from real pictures, then draw with the prompts you learned.\n\n- 62 lessons in 11 sections\n- Gems the first time you finish a lesson, get three stars or finish a section\n- A generator that draws with the tags you learned',
              'ja': '実際の絵でタグを覚え、学んだプロンプトで描いてみるコースです。\n\n- 11セクション、62レッスン\n- レッスン・星3つ・セクションを初めて終えるたびにジェム\n- 学んだタグですぐ描けるジェネレーター',
            }),
          ),
        ],
      ),
      LabShopSection(
        title: LabText({'ko': '도구', 'en': 'Tools', 'ja': 'ツール'}),
        items: [
          LabShopItem(
            id: 'feature.prompt-analyzer',
            kind: 'feature',
            name: LabText({'ko': '프롬프트 분석기', 'en': 'Prompt Analyzer', 'ja': 'プロンプトアナライザー'}),
            summary: LabText({
              'ko': '바로 쓰는 AI 프롬프트, 원 클릭 이미지 생성',
              'en': 'Ready-to-use AI prompts, one-click image generation',
              'ja': 'すぐ使えるAIプロンプト、ワンクリックで画像生成',
            }),
            symbol: 'text.viewfinder',
            price: 200,
            requires: 'course.tags',
            feature: 'prompt-analyzer',
            color: '0A84FF',
            detail: LabText({
              'ko': '마음에 든 그림을 그대로 쓸 수 있는 AI 프롬프트로 바꾸고, 한 번 눌러 바로 이미지를 생성합니다.\n\n- 즉시 쓰는 프롬프트: 이미지 생성 AI가 읽는 순서로 정리돼 복사해서 바로 사용\n- 원 클릭 생성: 그 프롬프트 그대로 생성기에서 바로 그리기\n- 프롬프트 · 괄호 이스케이프 · 검색 태그 세 가지 형식\n- 그림 속 2D AI 배우기 태그를 바로 연습',
              'en': 'Turns a picture you like into an AI prompt you can use as it is, and generates an image from it in one click.\n\n- Ready-to-use prompts, in the order image generators read, copied in one tap\n- One-click generation: draw with that very prompt in the generator\n- Three formats: prompt, escaped brackets and search tags\n- Practise the picture\'s Learn 2D AI tags right away',
              'ja': '気に入った絵を、そのまま使えるAIプロンプトに変え、ワンクリックで画像を生成します。\n\n- すぐ使えるプロンプト：画像生成AIが読む順に整理され、コピーしてそのまま使用\n- ワンクリック生成：そのプロンプトのままジェネレーターで描く\n- プロンプト・括弧エスケープ・検索タグの3形式\n- 絵の中の「2D AIを学ぶ」のタグをすぐ練習',
            }),
          ),
        ],
      ),
    ],
  );

  final LabText currency;
  final LabText? note;
  final List<LabShopSection> sections;

  List<LabShopItem> get items => [for (final section in sections) ...section.items];
  LabShopItem? item(String id) => items.where((item) => item.id == id).firstOrNull;

  /// The permanent goods together: what can be owned once, not used up. The cards are priced against this.
  int get permanentTotal => items.where((item) => !item.isRepeat).fold(0, (total, item) => total + (item.price ?? 0));

  /// Reads a list's JSON. Throws [LabShopError.newer] for a list written for a later app.
  static LabShop decode(List<int> data) {
    if (data.length > maximumBytes) throw LabShopError.invalid;
    final Object? top;
    try {
      top = jsonDecode(utf8.decode(data));
    } on Object {
      throw LabShopError.invalid;
    }
    if (top is! Map || top['format'] != format || top['schemaVersion'] is! int || (top['schemaVersion'] as int) < 1) throw LabShopError.invalid;
    if ((top['schemaVersion'] as int) > schemaVersion) throw LabShopError.newer;
    try {
      return LabShop(
        currency: LabText.parse(top['currency']),
        note: LabText.parseOrNull(top['note']),
        sections: [
          for (final value in top['sections'] as List) LabShopSection(title: LabText.parse((value as Map)['title']), items: _items(value['items'] as List)),
        ],
      );
    } on LabShopError {
      rethrow;
    } on Object {
      throw LabShopError.invalid;
    }
  }

  /// An item that is not shaped like one at all is left out, rather than hiding the whole shop.
  static List<LabShopItem> _items(List values) {
    final seen = <String>{};
    return [
      for (final value in values)
        if (LabShopItem.parse(value) case final item? when seen.add(item.id)) item,
    ];
  }
}

enum LabShopError implements Exception { invalid, newer, unsigned }

class LabShopSection {
  const LabShopSection({required this.title, required this.items});
  final LabText title;
  final List<LabShopItem> items;
}

/// A file the shop delivers, as the signed list names it. Its path is under the add-on server's `v1/`.
class LabShopFile {
  const LabShopFile({required this.path, required this.size, required this.sha256});
  final String path;
  final int size;
  final String sha256;

  static const maximumBytes = 40 * 1024 * 1024;

  /// An item's picture.
  static const imageBytes = 2 * 1024 * 1024;
  static final _path = RegExp(r'^[A-Za-z0-9._/-]+$');
  static final _hash = RegExp(r'^[0-9a-f]{64}$');

  /// Letters, digits, `.`, `-`, `_` and `/` only, no `..` and nothing absolute, so a path can only name a file on TEGNAL's server.
  bool get valid =>
      path.isNotEmpty &&
      path.length <= 200 &&
      _path.hasMatch(path) &&
      path.split('/').every((part) => part.isNotEmpty && part != '.' && part != '..') &&
      size >= 1 &&
      size <= maximumBytes &&
      _hash.hasMatch(sha256);
  String get name => path.split('/').last;

  static LabShopFile? parse(Object? json) {
    if (json is! Map || json['path'] is! String || json['size'] is! int || json['sha256'] is! String) return null;
    return LabShopFile(path: json['path'] as String, size: json['size'] as int, sha256: json['sha256'] as String);
  }
}

/// An official add-on the shop sells. Its file sits where the free official add-ons do; it is not in their list.
class LabShopAddon {
  const LabShopAddon({required this.id, required this.version, required this.mode, required this.file});
  final String id;
  final String version;
  final AddonMode mode;
  final LabShopFile file;
  bool get valid => AddonCheck.identifier(id) && AddonCheck.version(version) && file.valid && file.size <= Addon.maximumBytes;

  static LabShopAddon? parse(Object? json) {
    if (json is! Map || json['id'] is! String || json['version'] is! String) return null;
    final mode = AddonMode.values.where((mode) => mode.name == json['mode']).firstOrNull;
    final file = LabShopFile.parse(json['file']);
    if (mode == null || file == null) return null;
    return LabShopAddon(id: json['id'] as String, version: json['version'] as String, mode: mode, file: file);
  }
}

/// A home scene: its opening film, its loop, the opening's first frame blurred, and optionally its music and colours.
class LabShopHome {
  const LabShopHome({required this.intro, required this.loop, required this.still, this.theme, this.palette});
  final LabShopFile intro;
  final LabShopFile loop;
  final LabShopFile still;
  final LabShopFile? theme;

  /// `sky`, `ground` and `dusk` as six hexadecimal digits.
  final Map<String, String>? palette;

  List<(String, LabShopFile)> get files => [('intro', intro), ('loop', loop), ('still', still), if (theme case final theme?) ('theme', theme)];
  bool get valid =>
      files.every((entry) => entry.$2.valid) &&
      (palette ?? const {}).entries.every((entry) => const ['sky', 'ground', 'dusk'].contains(entry.key) && hex(entry.value) != null);

  static int? hex(String value) => RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(value) ? int.parse(value, radix: 16) : null;

  static LabShopHome? parse(Object? json) {
    if (json is! Map) return null;
    final intro = LabShopFile.parse(json['intro']), loop = LabShopFile.parse(json['loop']), still = LabShopFile.parse(json['still']);
    if (intro == null || loop == null || still == null) return null;
    final theme = json['theme'] == null ? null : LabShopFile.parse(json['theme']);
    if (json['theme'] != null && theme == null) return null;
    final palette = json['palette'];
    if (palette != null && palette is! Map) return null;
    return LabShopHome(
      intro: intro,
      loop: loop,
      still: still,
      theme: theme,
      palette: palette == null ? null : {for (final entry in (palette as Map).entries) '${entry.key}': '${entry.value}'},
    );
  }
}

/// Features of the app the shop sells the key to. The code is in the app; buying `feature.<id>` opens it.
enum LabFeature {
  promptAnalyzer('prompt-analyzer');

  const LabFeature(this.id);
  final String id;
  String get item => 'feature.$id';
  static LabFeature? named(String? id) => values.where((feature) => feature.id == id).firstOrNull;
}

class LabShopItem {
  const LabShopItem({
    required this.id,
    required this.kind,
    required this.name,
    this.version,
    this.summary,
    this.symbol,
    this.price,
    this.limited,
    this.repeat,
    this.soon,
    this.requires,
    this.course,
    this.file,
    this.feature,
    this.addon,
    this.home,
    this.count,
    this.color,
    this.detail,
    this.image,
  });

  /// The kinds of goods this app knows how to deliver, and the newest item fields it reads.
  static const kinds = {'course', 'feature', 'addon', 'home', 'ticket'};
  static const fieldsVersion = 1;

  /// The courses in the app that the shop sells, by course id, with the item that sells each.
  static const bundledCourses = {'2d-ai': 'course.tags'};

  final String id;

  /// `course`, `feature`, `addon`, `home` or `ticket`.
  final String kind;

  /// The version of the item's fields. One newer than the app's asks for an update.
  final int? version;
  final LabText name;
  final LabText? summary;
  final String? symbol;
  final int? price;

  /// Sold with a limited-sale label: it may not stay on sale.
  final bool? limited;

  /// Can be bought again, such as tickets that are used up.
  final bool? repeat;

  /// Shown, but not on sale yet.
  final bool? soon;

  /// The item that must be owned first, such as 2D AI 배우기 for the tickets its picture generator uses.
  final String? requires;

  /// `course`: a course bundled in the app (`LearningCourse.id`).
  final String? course;

  /// `course`: a course file to download (`tegnal-lab-course`).
  final LabShopFile? file;

  /// `feature`: the feature it opens ([LabFeature]).
  final String? feature;
  final LabShopAddon? addon;
  final LabShopHome? home;

  /// `ticket`: tickets one purchase brings.
  final int? count;

  /// The card's colour, six hexadecimal digits. Null: the colour of its kind (`LabShopStyle`).
  final String? color;

  /// What the item's page says beyond the summary, as Markdown ([LabMarkdown]).
  final LabText? detail;

  /// A picture that fills the item's card and page in place of its colour and symbol (`LabShopImages`).
  final LabShopFile? image;

  bool get isLimited => limited ?? false;
  bool get isRepeat => repeat ?? false;
  bool get isSoon => soon ?? false;

  /// True when this app knows what the item is and how to deliver it. Anything else is shown with "update the app to buy it".
  bool get supported {
    if (!kinds.contains(kind) || (version ?? 1) > fieldsVersion) return false;
    // Something shown but not on sale yet needs nothing more.
    if (isSoon) return true;
    return switch (kind) {
      'course' => course != null ? bundledCourses[course] == id : (file?.valid ?? false),
      'feature' => LabFeature.named(feature)?.item == id,
      'addon' => addon?.valid ?? false,
      'home' => home?.valid ?? false,
      'ticket' => (count ?? 0) > 0,
      _ => false,
    };
  }

  /// Bought here but brought by files that each device downloads for itself.
  bool get downloads => file != null || addon != null || home != null;

  LabShopItem copyWith({bool? soon, int? count}) => LabShopItem(
    id: id,
    kind: kind,
    name: name,
    version: version,
    summary: summary,
    symbol: symbol,
    price: price,
    limited: limited,
    repeat: repeat,
    soon: soon ?? this.soon,
    requires: requires,
    course: course,
    file: file,
    feature: feature,
    addon: addon,
    home: home,
    count: count ?? this.count,
    color: color,
    detail: detail,
    image: image,
  );

  static final _identifier = RegExp(r'^[a-z0-9][a-z0-9._-]*$');

  /// Reads the fields every item has strictly and the rest leniently: a later app may shape them differently, which only makes
  /// the item unsupported. Null for something not shaped like an item.
  static LabShopItem? parse(Object? json) {
    if (json is! Map || json['id'] is! String || json['kind'] is! String) return null;
    final id = json['id'] as String;
    if (id.length < 3 || id.length > 48 || !_identifier.hasMatch(id)) return null;
    final LabText name;
    try {
      name = LabText.parse(json['name']);
    } on Object {
      return null;
    }
    T? read<T>(String key) => json[key] is T ? json[key] as T : null;
    LabText? text(String key) {
      try {
        return LabText.parseOrNull(json[key]);
      } on Object {
        return null;
      }
    }

    final price = read<int>('price');
    return LabShopItem(
      id: id,
      kind: json['kind'] as String,
      name: name,
      version: read<int>('version'),
      summary: text('summary'),
      symbol: read<String>('symbol'),
      price: price != null && price >= 0 ? price : null,
      limited: read<bool>('limited'),
      repeat: read<bool>('repeat'),
      soon: read<bool>('soon'),
      requires: read<String>('requires'),
      course: read<String>('course'),
      file: LabShopFile.parse(json['file']),
      feature: read<String>('feature'),
      addon: LabShopAddon.parse(json['addon']),
      home: LabShopHome.parse(json['home']),
      count: read<int>('count'),
      color: switch (read<String>('color')) {
        final hex? when LabShopHome.hex(hex) != null => hex,
        _ => null,
      },
      detail: text('detail'),
      image: switch (LabShopFile.parse(json['image'])) {
        final file? when file.valid && file.size <= LabShopFile.imageBytes => file,
        _ => null,
      },
    );
  }
}

// MARK: - Reading the list

/// Downloads the shop list from TEGNAL's add-on server and keeps the last good copy.
class LabShopSource {
  static final url = AddonMarket.liveBase.resolve('lab/shop.json');

  /// Fixture runs never reach the network.
  static const _fixture = String.fromEnvironment('TEGNAL_FIXTURE');

  /// `TEGNAL_LAB_SHOP`: a file to read an unsigned list from instead, for tests and screenshots.
  static const _local = String.fromEnvironment('TEGNAL_LAB_SHOP');

  static Future<File?> _file() async {
    try {
      return File('${(await getApplicationSupportDirectory()).path}/AILab/shop.json');
    } on Object {
      return null;
    }
  }

  /// The list read last time, if any. Kept as the signed list's own bytes, already checked when they were downloaded.
  static Future<LabShop?> saved() async {
    try {
      final file = _local.isNotEmpty ? File(_local) : await _file();
      if (file == null || !file.existsSync()) return null;
      return LabShop.decode(await file.readAsBytes());
    } on Object {
      return null;
    }
  }

  /// Fetches the published list (`{"payload": base64, "signature": base64}`, signed with the add-on catalog's key).
  static Future<LabShop> fetch({AddonMarket? market}) async {
    if (_local.isNotEmpty) return (await saved()) ?? (throw LabShopError.invalid);
    if (_fixture.isNotEmpty && market == null) throw const AddonMarketError.offline();
    final source = market ?? AddonMarket.live;
    final data = await source.fetch(url, LabShop.maximumBytes * 2);
    final (shop, payload) = open(data, source.publicKey);
    // Only TEGNAL's own list is kept for next time; a list signed with a test key is not.
    final file = source.publicKey.Q == AddonMarket.live.publicKey.Q ? await _file() : null;
    if (file != null) {
      try {
        await file.parent.create(recursive: true);
        await file.writeAsBytes(payload, flush: true);
      } on Object {
        // Kept next time.
      }
    }
    return shop;
  }

  /// Checks the signature over the list's exact bytes, then reads it.
  static (LabShop, List<int>) open(List<int> file, ECPublicKey key) {
    final payload = LabSigned.payload(file, key, LabShop.maximumBytes);
    return (LabShop.decode(payload), payload);
  }
}

/// The envelope TEGNAL's signed files share: `{"payload": base64, "signature": base64}`, ECDSA P-256 with SHA-256 (DER).
class LabSigned {
  static List<int> payload(List<int> file, ECPublicKey key, int limit) {
    try {
      final envelope = jsonDecode(utf8.decode(file));
      if (envelope is Map) {
        final payload = base64.decode(envelope['payload'] as String);
        final signature = base64.decode(envelope['signature'] as String);
        if (payload.length <= limit && AddonMarket.isSigned(payload, signature, key)) return payload;
      }
    } on Object {
      // Falls through to the refusal.
    }
    throw LabShopError.unsigned;
  }
}
