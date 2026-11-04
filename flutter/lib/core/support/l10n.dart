/// Localized wording keyed by the English source, as in `Shared/*.lproj/Localizable.strings`.
/// The table is installed once the app has loaded the strings for the current language.
abstract final class L10n {
  static Map<String, String> table = const {};

  /// `en`, `ko` or `ja`: the app language setting, or the device language it follows.
  static String language = 'en';

  static String get contentLanguage => switch (language) {
    'ko' => 'korean',
    'ja' => 'japanese',
    _ => 'english',
  };

  /// `String(format:)` with `%@`, positional `%1$@` arguments and `%%` for a percent sign.
  static String text(String key, [List<String> arguments = const []]) {
    var value = table[key] ?? key;
    if (language == 'ko') value = keepingWords(value);
    if (arguments.isEmpty) return value;
    var next = 0;
    return value.replaceAllMapped(RegExp(r'%%|%(\d+)\$@|%@'), (match) {
      if (match[0] == '%%') return '%';
      if (match[1] case final position?) {
        final index = int.parse(position) - 1;
        return index < arguments.length ? arguments[index] : match[0]!;
      }
      return next < arguments.length ? arguments[next++] : match[0]!;
    });
  }

  /// iOS wraps Korean between words. Joining the letters of each word with
  /// U+2060 WORD JOINER makes text layout wrap the same way instead of mid-word.
  static String keepingWords(String value) {
    if (!_hangul.hasMatch(value)) return value;
    final buffer = StringBuffer();
    final characters = value.runes.toList();
    // `{name}` placeholders stay untouched so templates still match their variables.
    var inPlaceholder = false;
    for (var index = 0; index < characters.length; index++) {
      final current = characters[index];
      buffer.writeCharCode(current);
      if (current == 0x7B) inPlaceholder = true;
      if (current == 0x7D) inPlaceholder = false;
      if (!inPlaceholder && index + 1 < characters.length && _joins(current) && _joins(characters[index + 1])) buffer.write('\u2060');
    }
    return buffer.toString();
  }

  static final _hangul = RegExp('[\uAC00-\uD7A3]');
  static bool _joins(int rune) =>
      rune >= 0xAC00 && rune <= 0xD7A3 || rune >= 0x30 && rune <= 0x39 || rune >= 0x41 && rune <= 0x5A || rune >= 0x61 && rune <= 0x7A;

  /// Keep the historical database sentinel intact; never rename user data on locale changes.
  static String folderName(String storedName) => storedName == '미분류' ? text('Unfiled') : storedName;
}
