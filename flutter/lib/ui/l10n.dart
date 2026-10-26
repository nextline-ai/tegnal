import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Reuses the native app's English keys and Korean/Japanese translations.
class L10n {
  static final Map<String, Map<String, String>> _strings = {};
  static Future<void> load() async {
    for (final language in ['en', 'ko', 'ja']) {
      _strings[language] = Map<String, String>.from(
        jsonDecode(await rootBundle.loadString('assets/l10n/$language.json'))
            as Map,
      );
    }
  }

  static String tr(BuildContext context, String key) {
    final language = Localizations.localeOf(context).languageCode;
    return _strings[language]?[key] ?? key;
  }
}
