import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// JSON read the way Swift's synthesized `Decodable` reads it, so both apps
/// accept and reject the same documents. A non-optional property is a required
/// key even when Swift gives it a default value; an optional one may be absent
/// or null. Values of the wrong type are errors in both cases.
class SwiftJsonError implements Exception {
  SwiftJsonError(this.message);
  final String message;
  @override
  String toString() => 'SwiftJsonError: $message';
}

typedef JsonObject = Map<String, Object?>;

extension SwiftJsonObject on JsonObject {
  Object? _required(String key) {
    if (!containsKey(key) || this[key] == null) throw SwiftJsonError('Missing value for "$key"');
    return this[key];
  }

  String string(String key) => _string(_required(key), key);
  String? stringOrNull(String key) => this[key] == null ? null : _string(this[key], key);

  int integer(String key) => _integer(_required(key), key);
  int? integerOrNull(String key) => this[key] == null ? null : _integer(this[key], key);

  double number(String key) => _number(_required(key), key);
  double? numberOrNull(String key) => this[key] == null ? null : _number(this[key], key);

  bool boolean(String key) => _boolean(_required(key), key);
  bool? booleanOrNull(String key) => this[key] == null ? null : _boolean(this[key], key);

  JsonObject object(String key) => _object(_required(key), key);
  JsonObject? objectOrNull(String key) => this[key] == null ? null : _object(this[key], key);

  List<T> list<T>(String key, T Function(Object? value) element) => _list(_required(key), key, element);
  List<T>? listOrNull<T>(String key, T Function(Object? value) element) => this[key] == null ? null : _list(this[key], key, element);

  List<String> strings(String key) => list(key, (value) => _string(value, key));
  List<String>? stringsOrNull(String key) => listOrNull(key, (value) => _string(value, key));

  Map<String, T> dictionary<T>(String key, T Function(Object? value) element) =>
      _object(_required(key), key).map((name, value) => MapEntry(name, element(value)));
  Map<String, T>? dictionaryOrNull<T>(String key, T Function(Object? value) element) => this[key] == null ? null : dictionary(key, element);
}

String _string(Object? value, String key) => value is String ? value : throw SwiftJsonError('Expected a string for "$key"');

/// Swift reads `1.0` as an Int but rejects `1.5`.
int _integer(Object? value, String key) {
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.truncateToDouble()) return value.toInt();
  throw SwiftJsonError('Expected an integer for "$key"');
}

double _number(Object? value, String key) => value is num ? value.toDouble() : throw SwiftJsonError('Expected a number for "$key"');

bool _boolean(Object? value, String key) => value is bool ? value : throw SwiftJsonError('Expected a boolean for "$key"');

JsonObject _object(Object? value, String key) => value is Map<String, Object?> ? value : throw SwiftJsonError('Expected an object for "$key"');

List<T> _list<T>(Object? value, String key, T Function(Object? value) element) =>
    value is List ? [for (final item in value) element(item)] : throw SwiftJsonError('Expected an array for "$key"');

/// Element readers for `list`, `map` and top-level values.
String jsonString(Object? value) => _string(value, 'element');
int jsonInteger(Object? value) => _integer(value, 'element');
double jsonNumber(Object? value) => _number(value, 'element');
JsonObject jsonObject(Object? value) => _object(value, 'element');

/// Writes `value` only when present, like `encodeIfPresent`.
extension SwiftJsonWriter on JsonObject {
  void putIfPresent(String key, Object? value) {
    if (value != null) this[key] = value;
  }
}

Object? decodeJsonValue(List<int> data) {
  try {
    return jsonDecode(utf8.decode(data));
  } on FormatException catch (error) {
    throw SwiftJsonError(error.message);
  }
}

JsonObject decodeJsonObject(List<int> data) => jsonObject(decodeJsonValue(data));

/// `JSONEncoder` with `.sortedKeys` (and `.prettyPrinted` when asked). Like Swift,
/// it writes `/` as `\/` unless asked for `.withoutEscapingSlashes`.
Uint8List encodeJson(Object? value, {bool pretty = false, bool escapingSlashes = true}) {
  final sorted = _sorted(value);
  final text = pretty ? const JsonEncoder.withIndent('  ').convert(sorted) : jsonEncode(sorted);
  return Uint8List.fromList(utf8.encode(escapingSlashes ? _escapeSlashes(text) : text));
}

String encodeJsonString(Object? value) => utf8.decode(encodeJson(value));

/// A plain `JSONEncoder()`, as used for payload columns and settings values.
Uint8List encodeSwiftJson(Object? value) => Uint8List.fromList(utf8.encode(encodeSwiftJsonString(value)));
String encodeSwiftJsonString(Object? value) => _escapeSlashes(jsonEncode(value));

/// A slash can only occur inside a JSON string, so every one is escaped.
String _escapeSlashes(String json) => json.replaceAll('/', r'\/');

Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is List) return [for (final item in value) _sorted(item)];
  return value;
}

/// `Date` as Swift's default `JSONEncoder` writes it: seconds since 2001-01-01.
const double _referenceDateOffset = 978307200;
double swiftReferenceSeconds(DateTime date) => date.microsecondsSinceEpoch / 1e6 - _referenceDateOffset;
DateTime dateFromSwiftReferenceSeconds(double seconds) => DateTime.fromMicrosecondsSinceEpoch(((seconds + _referenceDateOffset) * 1e6).round(), isUtc: true);

/// `Date().timeIntervalSince1970`.
double unixSeconds([DateTime? date]) => (date ?? DateTime.now()).microsecondsSinceEpoch / 1e6;

/// `ISO8601DateFormatter().string(from:)`: whole seconds in UTC, such as `2026-01-02T03:04:05Z`.
String iso8601([DateTime? date]) {
  final utc = (date ?? DateTime.now()).toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)}'
      'T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
}

final _random = Random.secure();

/// `UUID().uuidString`: a random version 4 UUID in upper case.
String uuidString() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

final _whitespace = RegExp(r'\s');
bool isWhitespace(String character) => _whitespace.hasMatch(character);

/// `split(whereSeparator:)` with Swift's defaults: empty pieces are dropped and
/// do not count toward `maxSplits`.
List<String> swiftSplit(String value, bool Function(String character) isSeparator, {int? maxSplits}) {
  final result = <String>[];
  var start = 0;
  for (var index = 0; index < value.length; index++) {
    if (!isSeparator(value[index])) continue;
    final appended = index > start;
    if (appended) result.add(value.substring(start, index));
    start = index + 1;
    if (appended && result.length == maxSplits) break;
  }
  if (start < value.length) result.add(value.substring(start));
  return result;
}

List<String> splitWhitespace(String value) => swiftSplit(value, isWhitespace);

/// `Int64(_:)`: ASCII digits with an optional sign, nothing else.
int? parseInt64(String value) => RegExp(r'^[+-]?[0-9]+$').hasMatch(value) ? int.tryParse(value) : null;
