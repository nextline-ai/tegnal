import '../support/l10n.dart';

/// The `URLError` codes the content code distinguishes.
enum NetworkErrorCode {
  secureConnectionFailed,
  networkConnectionLost,
  timedOut,
  cannotConnectToHost,
  cannotFindHost,
  dnsLookupFailed,
  notConnectedToInternet,
  serverCertificateUntrusted,
  unsupportedURL,
  badURL,
  cancelled,
  fileDoesNotExist,
  cannotParseResponse,
  unknown,
}

/// A failed connection, as `URLError` reports it.
class NetworkError implements Exception {
  const NetworkError(this.code);
  final NetworkErrorCode code;

  @override
  bool operator ==(Object other) => other is NetworkError && other.code == code;
  @override
  int get hashCode => code.hashCode;
  @override
  String toString() => 'NetworkError.${code.name}';
}

/// Work that stopped because its site changed or its caller left.
class CancellationError implements Exception {
  const CancellationError();
  @override
  String toString() => 'CancellationError';
}

/// The hidden browser's page process ended; like `WKError.webContentProcessTerminated`, it may be retried.
class BrowserProcessTerminated implements Exception {
  const BrowserProcessTerminated();
}

enum ContentErrorKind {
  invalidResponse,
  unsupportedFormat,
  tooLarge,
  unavailable,
  invalidQuery,
  galleryNotFound,
  tooManySearchTerms,
  signInRequired,
  imageLimit,
}

class ContentError implements Exception {
  const ContentError(this.kind, [this.value]);
  const ContentError.unavailable(int status) : this(ContentErrorKind.unavailable, status);
  const ContentError.tooManySearchTerms(int limit) : this(ContentErrorKind.tooManySearchTerms, limit);

  static const invalidResponse = ContentError(ContentErrorKind.invalidResponse);
  static const unsupportedFormat = ContentError(ContentErrorKind.unsupportedFormat);
  static const tooLarge = ContentError(ContentErrorKind.tooLarge);
  static const invalidQuery = ContentError(ContentErrorKind.invalidQuery);
  static const galleryNotFound = ContentError(ContentErrorKind.galleryNotFound);
  static const signInRequired = ContentError(ContentErrorKind.signInRequired);
  static const imageLimit = ContentError(ContentErrorKind.imageLimit);

  final ContentErrorKind kind;

  /// The HTTP status of `unavailable`, or the limit of `tooManySearchTerms`.
  final int? value;

  bool isUnavailable([int? status]) => kind == ContentErrorKind.unavailable && (status == null || value == status);

  String get errorDescription => switch (kind) {
    ContentErrorKind.invalidResponse => L10n.text('Unable to read the response. Please try again shortly.'),
    ContentErrorKind.unsupportedFormat => L10n.text('The service format has changed or this image is unsupported.'),
    ContentErrorKind.tooLarge => L10n.text('The requested data is too large. Narrow your search.'),
    ContentErrorKind.galleryNotFound => L10n.text('This work was removed or could not be found.'),
    ContentErrorKind.unavailable when value == 404 => L10n.text('This work was removed or could not be found.'),
    ContentErrorKind.unavailable when value == 403 => L10n.text('The image server declined the request. Try again shortly.'),
    ContentErrorKind.unavailable => L10n.text('Unable to connect to the server. Try again shortly.'),
    ContentErrorKind.invalidQuery => L10n.text('Check your search. Separate terms with spaces and join words within a tag with underscores.'),
    ContentErrorKind.tooManySearchTerms => L10n.text('Use up to %@ search terms, including default and excluded tags.', ['$value']),
    ContentErrorKind.signInRequired => L10n.text('This website shows works only to signed-in accounts. Sign in, then try again.'),
    ContentErrorKind.imageLimit => L10n.text('This website’s image allowance for you has run out. Try again later.'),
  };

  static String get initialConnectionHelp => L10n.text(
    'Depending on the website and network, a VPN or HTTPS bypass may help or block connections. If it’s on, turn it off; if it’s off, turn it on, then try again.',
  );

  static String withConnectionHelp(String message, Object error) {
    if (error is! NetworkError) return message;
    return switch (error.code) {
      NetworkErrorCode.secureConnectionFailed ||
      NetworkErrorCode.networkConnectionLost ||
      NetworkErrorCode.timedOut ||
      NetworkErrorCode.cannotFindHost ||
      NetworkErrorCode.cannotConnectToHost ||
      NetworkErrorCode.dnsLookupFailed => '$message\n\n$initialConnectionHelp',
      _ => message,
    };
  }

  /// What a person reads for any failure while loading content.
  static String message(Object error) {
    if (error is ContentError) return error.errorDescription;
    if (error is NetworkError && error.code == NetworkErrorCode.notConnectedToInternet) return L10n.text('Check your internet connection.');
    return withConnectionHelp(L10n.text('Unable to load. Check your connection and try again.'), error);
  }

  @override
  bool operator ==(Object other) => other is ContentError && other.kind == kind && other.value == value;
  @override
  int get hashCode => Object.hash(kind, value);
  @override
  String toString() => 'ContentError.${kind.name}${value == null ? '' : '($value)'}';
}
