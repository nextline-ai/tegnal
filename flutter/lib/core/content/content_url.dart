import 'dart:convert';

/// Address building that matches `URLComponents` and `addingPercentEncoding`,
/// whose output differs from Dart's `Uri` encoders (`:` stays in a query, `+` is
/// never read as a space).
abstract final class ContentURL {
  static final _asciiAlphanumeric = RegExp(r'^[A-Za-z0-9]$');
  static final _unicodeAlphanumeric = RegExp(r'^[\p{L}\p{N}\p{M}]$', unicode: true);

  /// `CharacterSet.alphanumerics`, which includes letters and digits of every script.
  static bool isAlphanumeric(String character) =>
      _asciiAlphanumeric.hasMatch(character) || (character.codeUnitAt(0) > 127 && _unicodeAlphanumeric.hasMatch(character));

  static String _encode(String value, bool Function(String character) allowed) {
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      final character = String.fromCharCode(rune);
      if (allowed(character)) {
        buffer.write(character);
      } else {
        for (final byte in utf8.encode(character)) {
          buffer.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
        }
      }
    }
    return buffer.toString();
  }

  /// `addingPercentEncoding(withAllowedCharacters: .alphanumerics)`, optionally with extra allowed characters.
  static String alphanumerics(String value, {String extra = ''}) => _encode(value, (character) => isAlphanumeric(character) || extra.contains(character));

  static const _pathAllowed = r"!$&'()*+,-./:=@_~";
  static const _queryItemAllowed = r"!$'()*+,-./:;=?@_~";

  /// `addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)`.
  static String path(String value) => _encode(value, (character) => _asciiAlphanumeric.hasMatch(character) || _pathAllowed.contains(character));

  /// One query item name or value as `URLComponents.queryItems` writes it.
  static String queryComponent(String value) => _encode(value, (character) => _asciiAlphanumeric.hasMatch(character) || _queryItemAllowed.contains(character));

  /// `components.queryItems = items` on `base`, replacing any query it had. No items leaves no query.
  static Uri withQueryItems(String base, List<(String, String?)>? items) {
    final hash = base.indexOf('#');
    var head = hash >= 0 ? base.substring(0, hash) : base;
    final fragment = hash >= 0 ? base.substring(hash) : '';
    final question = head.indexOf('?');
    if (question >= 0) head = head.substring(0, question);
    if (items == null) return Uri.parse(head + fragment);
    final query = items.map((item) => item.$2 == null ? queryComponent(item.$1) : '${queryComponent(item.$1)}=${queryComponent(item.$2!)}').join('&');
    return Uri.parse('$head?$query$fragment');
  }

  /// `URLComponents.percentEncodedQueryItems`: names and values as written.
  static List<(String, String?)> percentEncodedQueryItems(Uri url) {
    if (!url.hasQuery) return [];
    return [
      for (final part in url.query.split('&'))
        if (part.contains('=')) (part.substring(0, part.indexOf('=')), part.substring(part.indexOf('=') + 1)) else (part, null),
    ];
  }

  /// `URLComponents.queryItems`: percent decoding only, so `+` stays a plus sign.
  static List<(String, String?)> queryItems(Uri url) => [
    for (final (name, value) in percentEncodedQueryItems(url)) (_decode(name) ?? name, value == null ? null : _decode(value) ?? value),
  ];

  static String? queryValue(Uri url, String name) => queryItems(url).where((item) => item.$1 == name).firstOrNull?.$2;

  /// `removingPercentEncoding`, which fails on malformed escapes.
  static String? removingPercentEncoding(String value) => _decode(value);

  static String? _decode(String value) {
    try {
      return Uri.decodeComponent(value);
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// `URL(string:)` for an absolute https or http address with a host, or null.
  static Uri? parse(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) return null;
    return uri;
  }

  /// `url.user` and `url.password` are both absent.
  static bool hasNoCredentials(Uri url) => url.userInfo.isEmpty;

  /// `url.port == nil || url.port == 443` for an https address.
  static bool usesDefaultPort(Uri url) => !url.hasPort || url.port == 443;
}
