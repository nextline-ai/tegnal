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
