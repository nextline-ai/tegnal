import '../support/swift_json.dart';

class _Term {
  const _Term({required this.excluded, required this.field, required this.value});
  final bool excluded;
  final String? field;
  final String value;
}

/// A search over saved works. Spaces and commas separate terms, and every term must match.
/// `field:value` reads one field exactly, `-` excludes a term and `_` stands for a space.
class WorkQuery {
  WorkQuery(String text, {String excluding = ''})
    : _terms = [
        ..._tokens(text).map((token) => _term(token, excluded: false)).nonNulls,
        ..._tokens(excluding).map((token) => _term(token, excluded: true)).nonNulls,
      ];

  static const _fields = {'artist', 'group', 'series', 'parody', 'character', 'type', 'female', 'male', 'language', 'tag', 'meta'};
  final List<_Term> _terms;

  /// Exclusions alone never count, so they cannot select an entire library.
  bool get isEmpty => _terms.every((term) => term.excluded);

  /// Conditions over the `works` table aliased as `w`.
  (String sql, List<Object?> arguments) get conditions {
    final clauses = <String>[], arguments = <Object?>[];
    for (final term in _terms) {
      final (clause, values) = _condition(term);
      clauses.add(term.excluded ? 'NOT ($clause)' : '($clause)');
      arguments.addAll(values);
    }
    return (clauses.join(' AND '), arguments);
  }

  static List<String> _tokens(String text) => swiftSplit(text, (character) => isWhitespace(character) || character == ',');

  static _Term? _term(String token, {required bool excluded}) {
    final negated = excluded || token.startsWith('-');
    final raw = token.startsWith('-') ? token.substring(1) : token;
    final parts = swiftSplit(raw, (character) => character == ':', maxSplits: 1);
    final isField = parts.length == 2 && _fields.contains(parts[0].toLowerCase());
    final value = (isField ? parts[1] : raw).replaceAll('_', ' ');
    return value.isEmpty ? null : _Term(excluded: negated, field: isField ? parts[0].toLowerCase() : null, value: value);
  }

  /// The same match the SQL conditions make, over a work's fields in memory: every term must
  /// hit, and an excluded term must miss.
  bool matches(WorkFields fields) => _terms.every((term) => _hits(term, fields) != term.excluded);

  static bool _hits(_Term term, WorkFields fields) {
    String normalized(String text) => text.replaceAll('_', ' ').toLowerCase();
    final value = term.value.toLowerCase();
    bool contains(String column) => normalized(column).contains(value);
    bool anyEntry(String column, String entry) => ', ${normalized(column)}, '.contains(', ${entry.toLowerCase()}, ');
    return switch (term.field) {
      null =>
        [fields.title, fields.artists, fields.groups, fields.series, fields.language, fields.type, fields.tags, fields.note].any(contains) ||
            parseInt64(term.value) == fields.galleryID,
      'language' => anyEntry(fields.language, term.value) || anyEntry(fields.tags, 'language:${term.value}'),
      'artist' => anyEntry(fields.artists, term.value) || anyEntry(fields.tags, 'artist:${term.value}'),
      'group' => anyEntry(fields.groups, term.value) || anyEntry(fields.tags, 'group:${term.value}'),
      'series' || 'parody' => anyEntry(fields.series, term.value) || anyEntry(fields.tags, '${term.field}:${term.value}'),
      'type' => anyEntry(fields.type, term.value) || anyEntry(fields.tags, 'type:${term.value}'),
      'tag' => anyEntry(fields.tags, term.value) || anyEntry(fields.tags, 'tag:${term.value}'),
      final field => anyEntry(fields.tags, '$field:${term.value}'),
    };
  }

  static (String, List<Object?>) _condition(_Term term) {
    final clauses = <String>[], arguments = <Object?>[];
    void anyEntry(String column, String value) {
      clauses.add("', ' || REPLACE(COALESCE($column, ''), '_', ' ') || ', ' LIKE ? ESCAPE '\\'");
      arguments.add('%, ${_escaped(value)}, %');
    }

    void contains(String column) {
      clauses.add("REPLACE(COALESCE($column, ''), '_', ' ') LIKE ? ESCAPE '\\'");
      arguments.add('%${_escaped(term.value)}%');
    }

    switch (term.field) {
      case null:
        for (final column in ['w.title', 'w.artists', 'w.groups', 'w.series', 'w.language', 'w.type', 'w.tags', 'w.note']) {
          contains(column);
        }
        final id = parseInt64(term.value);
        if (id != null) {
          clauses.add('w.gallery_id = ?');
          arguments.add(id);
        }
      case 'language':
        anyEntry('w.language', term.value);
        anyEntry('w.tags', 'language:${term.value}');
      case 'artist':
        anyEntry('w.artists', term.value);
        anyEntry('w.tags', 'artist:${term.value}');
      case 'group':
        anyEntry('w.groups', term.value);
        anyEntry('w.tags', 'group:${term.value}');
      case 'series' || 'parody':
        anyEntry('w.series', term.value);
        anyEntry('w.tags', '${term.field}:${term.value}');
      case 'type':
        anyEntry('w.type', term.value);
        anyEntry('w.tags', 'type:${term.value}');
      case 'tag':
        anyEntry('w.tags', term.value);
        anyEntry('w.tags', 'tag:${term.value}');
      case final field:
        anyEntry('w.tags', '$field:${term.value}');
    }
    return (clauses.join(' OR '), arguments);
  }

  static String _escaped(String value) => value.replaceAll(r'\', r'\\').replaceAll('%', r'\%');
}

/// What a work held outside the library shows, for the same search in memory.
class WorkFields {
  const WorkFields({
    required this.galleryID,
    this.title = '',
    this.artists = '',
    this.groups = '',
    this.series = '',
    this.language = '',
    this.type = '',
    this.tags = '',
    this.note = '',
  });
  final int galleryID;
  final String title, artists, groups, series, language, type, tags, note;
}
