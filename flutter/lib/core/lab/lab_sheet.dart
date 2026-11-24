import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';

import '../addons/addon_market.dart';
import 'lab_course.dart';

// The cheat sheet (Layer 2). Ported from `LabSheet.swift`; the shop is in `lab_shop.dart`.

/// One edition of the cheat sheet: what to use for which job right now. Editions come irregularly.
/// The app carries one in `assets/lab/cheatsheet.json`; newer ones are downloaded, signed with TEGNAL's add-on key, and kept.
class LabEdition {
  const LabEdition({required this.format, required this.id, required this.date, this.reward, this.change, required this.sections, this.footer});

  static const formatName = 'tegnal-lab-cheatsheet';
  final String format;
  final String id;

  /// The day it was curated, `yyyy-MM-dd`.
  final String date;

  /// 보석 for reading it the first time. Missing means the course's usual amount; 0 pays nothing.
  final int? reward;

  /// What changed since the last edition, one line.
  final LabText? change;
  final List<LabSheetSection> sections;
  final LabText? footer;

  /// `2026.11.23`.
  String get stamp => date.replaceAll('-', '.');
  bool get valid => format == formatName && id.isNotEmpty && date.length == 10 && sections.isNotEmpty && sections.every((section) => section.rows.isNotEmpty);

  static LabEdition? parse(Object? json) {
    try {
      if (json is! Map) return null;
      final edition = LabEdition(
        format: json['format'] as String,
        id: json['id'] as String,
        date: json['date'] as String,
        reward: (json['reward'] as num?)?.toInt(),
        change: LabText.parseOrNull(json['change']),
        sections: [for (final value in json['sections'] as List) LabSheetSection.parse(value as Map)],
        footer: LabText.parseOrNull(json['footer']),
      );
      return edition.valid ? edition : null;
    } on Object {
      return null;
    }
  }

  static LabEdition? _bundled;
  static LabEdition? get bundled => _bundled;
  static void useBundled(LabEdition? edition) => _bundled = edition;

  static Future<LabEdition?> loadBundled([AssetBundle? bundle]) async {
    if (_bundled != null) return _bundled;
    try {
      return _bundled = parse(jsonDecode(await (bundle ?? rootBundle).loadString('assets/lab/cheatsheet.json')));
    } on Object {
      return null;
    }
  }

  /// The newer of two editions.
  static LabEdition? newer(LabEdition? a, LabEdition? b) {
    if (a == null) return b;
    if (b == null) return a;
    return b.date.compareTo(a.date) > 0 ? b : a;
  }
}

class LabSheetSection {
  const LabSheetSection({required this.id, required this.title, this.opens, required this.rows});
  final String id;
  final LabText title;

  /// The episode whose card opens this section. None: always open.
  final String? opens;
  final List<LabSheetRow> rows;

  static LabSheetSection parse(Map json) => LabSheetSection(
    id: json['id'] as String,
    title: LabText.parse(json['title']),
    opens: json['opens'] as String?,
    rows: [
      for (final value in json['rows'] as List)
        LabSheetRow(
          task: LabText.parse((value as Map)['task']),
          example: LabText.parseOrNull(value['example']),
          pick: value['pick'] as String,
          why: LabText.parseOrNull(value['why']),
          draft: value['draft'] as bool?,
          symbol: value['symbol'] as String?,
          color: value['color'] as String?,
          label: LabText.parseOrNull(value['label']),
          labelColor: value['labelColor'] as String?,
          detail: LabText.parseOrNull(value['detail']),
        ),
    ],
  );
}

class LabSheetRow {
  const LabSheetRow({
    required this.task,
    this.example,
    required this.pick,
    this.why,
    this.draft,
    this.symbol,
    this.color,
    this.label,
    this.labelColor,
    this.detail,
  });
  final LabText task;
  final LabText? example;

  /// The product or tool to use now. Real names live only here, never in the course.
  final String pick;
  final LabText? why;

  /// A pick not settled yet: the sheet marks it as a draft.
  final bool? draft;

  // What a tap on the row opens (all optional; an app that predates them simply does not show them).
  /// A system symbol for the job, drawn beside it. The lab editor offers the set both apps draw (`labSheetSymbol`).
  final String? symbol;

  /// The symbol's colour, six hexadecimal digits. Null: the lab's gauge colour.
  final String? color;

  /// The tag at the tile's top right, such as "추천" or "무료". Null: "초안" for a draft pick, else nothing.
  final LabText? label;

  /// The tag's colour, six hexadecimal digits. Null: a quiet dashed outline.
  final String? labelColor;

  /// What a tap on the row shows under the pick, written as Markdown (`LabMarkdown`).
  final LabText? detail;
}

/// Downloads newer editions from TEGNAL's add-on server and keeps the last one.
class LabSheetSource {
  static final url = AddonMarket.liveBase.resolve('lab/cheatsheet.json');
  static const maximumBytes = 256 * 1024;

  /// Fixture runs never reach the network.
  static const _fixture = String.fromEnvironment('TEGNAL_FIXTURE');

  static Future<File?> _file() async {
    try {
      return File('${(await getApplicationSupportDirectory()).path}/AILab/cheatsheet.json');
    } on Object {
      return null;
    }
  }

  /// The last edition downloaded, if any.
  static Future<LabEdition?> saved() async {
    try {
      final file = await _file();
      if (file == null || !file.existsSync()) return null;
      return LabEdition.parse(jsonDecode(await file.readAsString()));
    } on Object {
      return null;
    }
  }

  /// Fetches the published edition (`{"payload": base64, "signature": base64}`, signed with the add-on catalog's key).
  /// An edition that is not signed, or not valid, is ignored.
  static Future<LabEdition?> fetch({ECPublicKey? key}) async {
    if (_fixture.isNotEmpty) return null;
    try {
      final data = await AddonMarket.get(url, maximumBytes * 2);
      final payload = payloadOf(data, key ?? AddonMarket.live.publicKey);
      final edition = payload == null ? null : LabEdition.parse(jsonDecode(utf8.decode(payload)));
      if (edition == null || payload == null) return null;
      final file = await _file();
      if (file != null) {
        await file.parent.create(recursive: true);
        await file.writeAsBytes(payload, flush: true);
      }
      return edition;
    } on Object {
      return null;
    }
  }

  /// The signed bytes of an edition file, or null when the signature does not hold.
  static List<int>? payloadOf(List<int> file, ECPublicKey key) {
    try {
      final envelope = jsonDecode(utf8.decode(file));
      if (envelope is! Map) return null;
      final payload = base64.decode(envelope['payload'] as String);
      final signature = base64.decode(envelope['signature'] as String);
      if (payload.length > maximumBytes || !AddonMarket.isSigned(payload, signature, key)) return null;
      return payload;
    } on Object {
      return null;
    }
  }

  /// Reads a signed edition file; null when it is not signed by [key] or not a valid edition.
  static LabEdition? open(List<int> file, ECPublicKey key) {
    final payload = payloadOf(file, key);
    if (payload == null) return null;
    try {
      return LabEdition.parse(jsonDecode(utf8.decode(payload)));
    } on Object {
      return null;
    }
  }
}
