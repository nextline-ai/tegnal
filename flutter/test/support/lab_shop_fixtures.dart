import 'dart:convert';
import 'dart:io';

import 'package:tegnal/core/lab/lab_shop.dart';

import 'addon_market_fixtures.dart';

/// The shop list as it is published: its source, `docs/live/shop.json` (local only). Null in a checkout without it.
LabShop? liveShop() {
  final file = File('../docs/live/shop.json');
  if (!file.existsSync()) return null;
  return LabShop.decode(file.readAsBytesSync());
}

/// A small list shaped like the published one, for checkouts without it.
const fixtureShopJson = '''
{"format": "tegnal-lab-shop", "schemaVersion": 1, "currency": {"ko": "보석", "en": "Gems"}, "sections": [
  {"title": "코스", "items": [{"id": "course.tags", "kind": "course", "course": "2d-ai", "name": "2D AI 배우기", "price": 500}]},
  {"title": "도구", "items": [{"id": "feature.prompt-analyzer", "kind": "feature", "feature": "prompt-analyzer", "name": "프롬프트 분석기", "price": 200, "requires": "course.tags"}]},
  {"title": "생성권", "items": [{"id": "tickets.10", "kind": "ticket", "count": 10, "name": "생성권 10장", "price": 100, "repeat": true, "requires": "course.tags", "soon": true}]}
]}''';

/// The published list where it is checked out, else the small one.
LabShop testShop() => liveShop() ?? LabShop.decode(utf8.encode(fixtureShopJson));

/// A list in the envelope the server publishes, signed with [key].
List<int> signedShop(String json, TestSigningKey key) {
  final payload = utf8.encode(json);
  return utf8.encode(jsonEncode({'payload': base64.encode(payload), 'signature': base64.encode(key.sign(payload))}));
}
