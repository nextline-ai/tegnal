/// A run of wording inside a block: plain, bold or italic, and optionally a link to another tag.
class StudySpan {
  const StudySpan(this.text, {this.bold = false, this.italic = false, this.tag});
  final String text;
  final bool bold;
  final bool italic;

  /// The tag name a link opens, or null for wording that is not a link.
  final String? tag;

  bool sameStyle(StudySpan other) => other.bold == bold && other.italic == italic && other.tag == tag;

  @override
  bool operator ==(Object other) => other is StudySpan && other.text == text && sameStyle(other);
  @override
  int get hashCode => Object.hash(text, bold, italic, tag);
  @override
  String toString() => 'StudySpan($text${bold ? ', bold' : ''}${italic ? ', italic' : ''}${tag == null ? '' : ', tag $tag'})';
}

String _joined(List<StudySpan> spans) => spans.map((span) => span.text).join();

/// One piece of a tag page: a heading, a paragraph or a bullet.
sealed class StudyBlock {
  const StudyBlock();
}

class StudyHeading extends StudyBlock {
  const StudyHeading(this.text);
  final String text;
  @override
  bool operator ==(Object other) => other is StudyHeading && other.text == text;
  @override
  int get hashCode => text.hashCode;
  @override
  String toString() => 'StudyHeading($text)';
}

class StudyParagraph extends StudyBlock {
  const StudyParagraph(this.spans);
  final List<StudySpan> spans;
  String get text => _joined(spans);
  @override
  bool operator ==(Object other) => other is StudyParagraph && _sameSpans(other.spans, spans);
  @override
  int get hashCode => Object.hashAll(spans);
  @override
  String toString() => 'StudyParagraph($text)';
}

class StudyBullet extends StudyBlock {
  const StudyBullet(this.level, this.spans);

  /// How many asterisks the line began with, from 1.
  final int level;
  final List<StudySpan> spans;
  String get text => _joined(spans);
  @override
  bool operator ==(Object other) => other is StudyBullet && other.level == level && _sameSpans(other.spans, spans);
  @override
  int get hashCode => Object.hash(level, Object.hashAll(spans));
  @override
  String toString() => 'StudyBullet($level, $text)';
}

bool _sameSpans(List<StudySpan> a, List<StudySpan> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

/// Reads a server's tag page into plain blocks of text. Only wording and tag links are kept:
/// embedded posts, tables and markup the app cannot show are dropped, and nothing is fetched or run.
abstract final class StudyDText {
  /// A page title as a tag name: lowercase, with underscores for spaces.
  static String tagName(String title) => _trim(title).toLowerCase().replaceAll(' ', '_');

  /// `trimmingCharacters(in: .whitespaces)`: spaces and tabs, but not line breaks.
  static String _trim(String text) => text.replaceAll(RegExp(r'^[ \t   -   　]+|[ \t   -   　]+$'), '');

  static final _heading = RegExp(r'^h[1-6](#[^.\s]*)?\.\s*(.+)$', caseSensitive: false);
  static final _bullet = RegExp(r'^(\*+)\s+(.+)$', caseSensitive: false);
  static final _marks = RegExp(r'\[/?(expand|spoilers?|quote|tn|section|hr|br)(=[^\]]*)?\]', caseSensitive: false);

  static List<StudyBlock> blocks(String text, {int limit = 120}) {
    final blocks = <StudyBlock>[];
    var paragraph = <String>[];
    void flush() {
      final joined = _trim(paragraph.join(' '));
      paragraph = [];
      if (joined.isNotEmpty) blocks.add(StudyParagraph(inline(joined)));
    }

    var skipping = 0;
    for (final raw in text.replaceAll('\r\n', '\n').split('\n')) {
      if (blocks.length >= limit) break;
      var line = _trim(raw);
      final lower = line.toLowerCase();
      // Tables and code hold layout, not wording.
      if (lower.startsWith('[table') || lower.startsWith('[code') || lower.startsWith('[nodtext')) skipping += 1;
      if (skipping > 0) {
        if (lower.contains('[/table]') || lower.contains('[/code]') || lower.contains('[/nodtext]')) skipping -= 1;
        continue;
      }
      if (lower.startsWith('!post #') || lower.startsWith('!asset #') || lower.startsWith('* !post #') || lower.startsWith('* !asset #')) continue;
      line = _trim(line.replaceAll(_marks, ''));
      if (line.isEmpty) {
        flush();
        continue;
      }
      if (_heading.firstMatch(line) case final match?) {
        flush();
        blocks.add(StudyHeading(_joined(inline(match.group(2)!))));
        continue;
      }
      if (_bullet.firstMatch(line) case final match?) {
        flush();
        blocks.add(StudyBullet(match.group(1)!.length, inline(match.group(2)!)));
        continue;
      }
      paragraph.add(line);
    }
    flush();
    return blocks;
  }

  /// The wording alone, for search, copying and translation.
  static String plain(String text) => blocks(text)
      .map(
        (block) => switch (block) {
          StudyHeading(:final text) => text,
          StudyParagraph(:final spans) => _joined(spans),
          StudyBullet(:final spans) => '• ${_joined(spans)}',
        },
      )
      .join('\n');

  static final _token = RegExp(
    [
      r'\[\[([^\]|]+)(\|([^\]]*))?\]\]', // [[tag]] or [[tag|label]]
      r'\{\{([^}]+)\}\}', // {{search}}
      r'\[(/?)(b|i|u|s|strong|em)\]', // style marks
      r'"([^"\n]+)":\[?(https?://[^\s\]]+|[/#][^\s\]]*)\]?', // "label":link
      r'<(https?://[^>\s]+)>', // <link>
      r'\[/?[a-z]+(=[^\]]*)?\]', // any other mark
    ].join('|'),
    caseSensitive: false,
  );

  /// Inline wording with its bold, italic and tag-link runs; neighbouring runs alike in style are one.
  static List<StudySpan> inline(String text) {
    final output = <StudySpan>[];
    var bold = 0, italic = 0;
    void piece(String string, {String? link}) {
      if (string.isEmpty) return;
      final span = StudySpan(string, bold: bold > 0, italic: italic > 0, tag: link);
      if (output.isNotEmpty && output.last.sameStyle(span)) {
        output[output.length - 1] = StudySpan(output.last.text + string, bold: span.bold, italic: span.italic, tag: link);
      } else {
        output.add(span);
      }
    }

    var cursor = 0;
    for (final match in _token.allMatches(text)) {
      if (cursor < match.start) piece(text.substring(cursor, match.start));
      cursor = match.end;
      if (match.group(1) case final title?) {
        // An empty label means the title without its bracketed qualifier.
        final hasBar = match.group(2) != null;
        var label = match.group(3) ?? '';
        if (label.isEmpty) label = hasBar ? title.replaceAll(RegExp(r'\s*\([^)]*\)$'), '') : title;
        final target = title.split('#').where((part) => part.isNotEmpty).firstOrNull ?? title;
        piece(label, link: target.isEmpty ? null : tagName(target));
      } else if (match.group(4) case final search?) {
        piece(search);
      } else if (match.group(6) case final mark?) {
        final closing = match.group(5) == '/';
        switch (mark.toLowerCase()) {
          case 'b' || 'strong':
            bold = (bold + (closing ? -1 : 1)).clamp(0, 1 << 30);
          case 'i' || 'em':
            italic = (italic + (closing ? -1 : 1)).clamp(0, 1 << 30);
        }
      } else if (match.group(7) case final label?) {
        piece(label);
      } else if (match.group(9) case final address?) {
        piece(address);
      }
    }
    if (cursor < text.length) piece(text.substring(cursor));
    return output;
  }
}
