import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../core/support/l10n.dart';
import '../core/support/preferences.dart';

/// Installs the wording for the app language: the `app.language` setting, or
/// the device language when it is one of the supported three, else English.
Future<void> loadLocalization(Preferences preferences) async {
  const supported = ['en', 'ko', 'ja'];
  final setting = preferences.string('app.language') ?? 'system';
  final device = ui.PlatformDispatcher.instance.locales.map((locale) => locale.languageCode).where(supported.contains).firstOrNull;
  final language = supported.contains(setting) ? setting : device ?? 'en';
  final table = jsonDecode(await rootBundle.loadString('assets/l10n/$language.json')) as Map<String, Object?>;
  L10n.language = language;
  L10n.table = {..._systemStrings[language]!, ...table.map((key, value) => MapEntry(key, value as String))};
}

/// Wording iOS supplies itself (`ContentUnavailableView.search`), which the native strings files do not carry.
const _systemStrings = {
  'en': {
    'No Results': 'No Results',
    'No Results for “%@”': 'No Results for “%@”',
    'Check the spelling or try a new search.': 'Check the spelling or try a new search.',
  },
  'ko': {'No Results': '결과 없음', 'No Results for “%@”': '‘%@’에 대한 결과 없음', 'Check the spelling or try a new search.': '철자를 확인하거나 새로운 검색을 시도하십시오.'},
  'ja': {'No Results': '結果なし', 'No Results for “%@”': '“%@”の結果はありません', 'Check the spelling or try a new search.': 'スペルを確認するか、新しい検索を試してください。'},
};
