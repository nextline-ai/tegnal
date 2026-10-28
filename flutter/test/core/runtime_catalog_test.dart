import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all runtime catalogs omit retired UI copy and branded imports', () {
    final retired = (jsonDecode(
      File('tool/l10n_exclusions.json').readAsStringSync(),
    ) as Map).keys.toSet();
    final brands = RegExp(r'violet|anime[\s_-]*boxes', caseSensitive: false);
    Set<String>? keys;
    for (final language in ['en', 'ko', 'ja']) {
      final catalog = Map<String, String>.from(
        jsonDecode(File('assets/l10n/$language.json').readAsStringSync())
            as Map,
      );
      expect(catalog.keys.toSet().intersection(retired), isEmpty);
      expect(
        catalog.entries.where(
          (entry) => brands.hasMatch('${entry.key} ${entry.value}'),
        ),
        isEmpty,
      );
      expect(
        catalog.entries.where(
          (entry) => '${entry.key} ${entry.value}'.toLowerCase().contains(
            'rating:explicit',
          ),
        ),
        isEmpty,
      );
      if (keys != null) expect(catalog.keys.toSet(), keys);
      keys = catalog.keys.toSet();
    }
  });
}
