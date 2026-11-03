/// Localized wording keyed by the English source, as in `Shared/*.lproj/Localizable.strings`.
/// The table is installed once the app has loaded the strings for the current language.
abstract final class L10n {
  static Map<String, String> table = const {};

  static String text(String key, [List<String> arguments = const []]) {
    var value = table[key] ?? key;
    for (final argument in arguments) {
      value = value.replaceFirst('%@', argument);
    }
    return value;
  }

  static String folderName(String storedName) => storedName == '미분류' ? text('Unfiled') : storedName;
}
