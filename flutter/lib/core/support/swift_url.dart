/// The parts of an absolute URL as `URLComponents(string:)` sees them, without
/// the normalization Dart's `Uri` applies (default ports, case, encoding).
class SwiftURLComponents {
  SwiftURLComponents({required this.scheme, this.user, this.password, this.host, this.port, this.path = '', this.query, this.fragment});

  String scheme;
  String? user;
  String? password;
  String? host;
  int? port;
  String path;
  String? query;
  String? fragment;

  static final _url = RegExp(r'^([A-Za-z][A-Za-z0-9+.\-]*):(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?$');
  static final _allowed = RegExp(r"^[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]*$");

  /// Null where `URLComponents(string:)` returns nil: characters a URL may not
  /// contain, or an authority whose port is not a number.
  static SwiftURLComponents? parse(String value) {
    if (!_allowed.hasMatch(value)) return null;
    final match = _url.firstMatch(value);
    if (match == null) return null;
    String? user, password, host;
    int? port;
    final authority = match[2];
    if (authority != null) {
      var rest = authority;
      final at = rest.lastIndexOf('@');
      if (at >= 0) {
        final info = rest.substring(0, at);
        rest = rest.substring(at + 1);
        final colon = info.indexOf(':');
        user = colon >= 0 ? info.substring(0, colon) : info;
        if (colon >= 0) password = info.substring(colon + 1);
      }
      final bracket = rest.lastIndexOf(']');
      final colon = rest.lastIndexOf(':');
      if (colon > bracket) {
        final digits = rest.substring(colon + 1);
        if (digits.isNotEmpty) {
          if (!RegExp(r'^[0-9]+$').hasMatch(digits)) return null;
          port = int.parse(digits);
        }
        rest = rest.substring(0, colon);
      }
      host = rest;
    }
    return SwiftURLComponents(scheme: match[1]!, user: user, password: password, host: host, port: port, path: match[3]!, query: match[4], fragment: match[5]);
  }

  /// `URLComponents.string`.
  String get string {
    final buffer = StringBuffer('$scheme:');
    if (host != null) {
      buffer.write('//');
      if (user != null) {
        buffer.write(user);
        if (password != null) buffer.write(':$password');
        buffer.write('@');
      }
      buffer.write(host);
      if (port != null) buffer.write(':$port');
    }
    buffer.write(path);
    if (query != null) buffer.write('?$query');
    if (fragment != null) buffer.write('#$fragment');
    return buffer.toString();
  }
}

/// `url.scheme` and `url.host` checks used when validating stored media addresses.
bool isRemoteURL(String? value, {bool allowCredentials = true}) {
  if (value == null) return false;
  final parts = SwiftURLComponents.parse(value);
  if (parts == null || !['https', 'http'].contains(parts.scheme.toLowerCase())) return false;
  if ((parts.host ?? '').isEmpty) return false;
  return allowCredentials || (parts.user == null && parts.password == null);
}
