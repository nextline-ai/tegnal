import 'content.dart';

/// Native blacklist semantics: OR between lines, AND within each line,
/// exclusions with '-', wildcard tags, and explicit rating/artist/id terms.
class ContentFilter {
  ContentFilter(String text)
    : rules = text
          .split(RegExp(r'[\r\n]+'))
          .map((line) => line.toLowerCase().trim())
          .where((line) => line.isNotEmpty && !line.startsWith('#'))
          .map((line) => line.split(RegExp(r'\s+')))
          .toList();
  final List<List<String>> rules;
  bool contains(ContentItem item) {
    final tags = item.tags.map((t) => t.toLowerCase()).toSet();
    return rules.any(
      (rule) => rule.every((term) {
        final negative = term.startsWith('-');
        final value = negative ? term.substring(1) : term;
        final bool matches;
        if (value.startsWith('rating:')) {
          matches =
              _rating(value.substring(7)) ==
              _rating(item.metadata['rating'] as String? ?? '');
        } else if (value.startsWith('artist:')) {
          matches = item.artists.any(
            (a) => a.toLowerCase() == value.substring(7),
          );
        } else if (value.startsWith('id:')) {
          matches = item.id.toString() == value.substring(3);
        } else if (value.contains('*')) {
          final pattern = RegExp(
            '^${value.split('*').map(RegExp.escape).join('.*')}\$',
          );
          matches = tags.any(pattern.hasMatch);
        } else {
          matches = tags.contains(value);
        }
        return negative ? !matches : matches;
      }),
    );
  }

  static String _rating(String value) => switch (value.toLowerCase()) {
    'g' || 'general' || 'safe' => 'g',
    's' || 'sensitive' => 's',
    'q' || 'questionable' => 'q',
    'e' || 'explicit' => 'e',
    _ => value.toLowerCase(),
  };
}
