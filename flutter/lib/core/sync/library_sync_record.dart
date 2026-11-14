import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:collection/collection.dart';

import '../support/swift_json.dart';

enum SyncValueKind { text, integer, real, blob, null_ }

/// Portable values: local row IDs, cache paths and credentials never leave the device.
/// Encoded like Swift's synthesized enum coding: `{"text":{"_0":"…"}}`, `{"null":{}}`.
class SyncValue {
  const SyncValue._(this.kind, this.value);
  const SyncValue.text(String value) : this._(SyncValueKind.text, value);
  const SyncValue.integer(int value) : this._(SyncValueKind.integer, value);
  const SyncValue.real(double value) : this._(SyncValueKind.real, value);
  SyncValue.blob(List<int> value) : this._(SyncValueKind.blob, Uint8List.fromList(value));
  static const null_ = SyncValue._(SyncValueKind.null_, null);

  final SyncValueKind kind;
  final Object? value;

  /// `SyncValue(DatabaseValue)`: the storage class SQLite returned.
  factory SyncValue.fromDatabase(Object? value) => switch (value) {
    null => null_,
    final int value => SyncValue.integer(value),
    final double value => SyncValue.real(value),
    final String value => SyncValue.text(value),
    final List<int> value => SyncValue.blob(value),
    final bool value => SyncValue.integer(value ? 1 : 0),
    _ => throw ArgumentError('Unsupported database value $value'),
  };

  Object? get databaseValue => value;
  String? get string => kind == SyncValueKind.text ? value as String : null;
  Uint8List? get data => kind == SyncValueKind.blob ? value as Uint8List : null;
  int? get integer => kind == SyncValueKind.integer ? value as int : null;

  static const _names = {
    SyncValueKind.text: 'text',
    SyncValueKind.integer: 'integer',
    SyncValueKind.real: 'real',
    SyncValueKind.blob: 'blob',
    SyncValueKind.null_: 'null',
  };

  Object toJson() => switch (kind) {
    SyncValueKind.null_ => {'null': <String, Object?>{}},
    SyncValueKind.blob => {
      'blob': {'_0': base64Encode(value as Uint8List)},
    },
    _ => {
      _names[kind]!: {'_0': value},
    },
  };

  factory SyncValue.fromJson(Object? json) {
    final object = jsonObject(json);
    if (object.length != 1) throw SwiftJsonError('Expected one case of SyncValue');
    final name = object.keys.single;
    final payload = jsonObject(object[name]);
    return switch (name) {
      'null' => null_,
      'text' => SyncValue.text(payload.string('_0')),
      'integer' => SyncValue.integer(payload.integer('_0')),
      'real' => SyncValue.real(payload.number('_0')),
      'blob' => SyncValue.blob(base64Decode(payload.string('_0'))),
      _ => throw SwiftJsonError('Unknown SyncValue case $name'),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is SyncValue &&
      other.kind == kind &&
      (kind == SyncValueKind.blob ? const ListEquality<int>().equals(value as Uint8List, other.value as Uint8List) : value == other.value);

  @override
  int get hashCode => Object.hash(kind, kind == SyncValueKind.blob ? const ListEquality<int>().hash(value as Uint8List) : value);

  @override
  String toString() => 'SyncValue.${_names[kind]}($value)';
}

const _valuesEquality = MapEquality<String, SyncValue>();

class LibrarySyncRow {
  LibrarySyncRow({required this.table, required Map<String, SyncValue> values}) : values = Map.of(values);

  final String table;
  Map<String, SyncValue> values;

  /// The table and its key columns, as Swift writes `[SyncValue]` with sorted keys, in base64.
  String get key {
    final columns = keys[table] ?? const <String>[];
    final encoded = encodeJson([for (final column in columns) (values[column] ?? SyncValue.null_).toJson()]);
    return '$table:${base64Encode(encoded)}';
  }

  bool get isFactoryDefault {
    return switch (table) {
      'booru.folders' => values['id']?.string == 'unsorted' && values['color']?.integer == 4284922736 && values['position']?.integer == 0,
      'manga.folders' => values['sync_id']?.string == 'unsorted' && values['color']?.integer == 4280391411 && values['sort_order']?.integer == 1,
      _ => false,
    };
  }

  static const keys = <String, List<String>>{
    'manga.library_order': ['key'],
    'manga.folders': ['sync_id'],
    'manga.works': ['gallery_id'],
    'manga.work_variants': ['gallery_id', 'site'],
    'manga.folder_works': ['folder_id', 'work_id'],
    'manga.artists': ['name', 'kind'],
    'manga.search_history': ['query'],
    'manga.saved_searches': ['query'],
    'booru.challenges': ['id'],
    'booru.servers': ['id'],
    'booru.folders': ['id'],
    'booru.favorites': ['server_id', 'post_id'],
    'booru.saved_tags': ['server_id', 'name', 'kind'],
    'booru.history': ['server_id', 'query'],
    'booru.settings': ['key'],
    'preferences.manga': ['key'],
    'preferences.booru': ['key'],
    'recent.works': ['id'],
    'recent.images': ['server_id', 'post_id'],
  };

  LibrarySyncRow copy() => LibrarySyncRow(table: table, values: values);

  JsonObject toJson() => {
    'table': table,
    'values': {for (final entry in values.entries) entry.key: entry.value.toJson()},
  };

  factory LibrarySyncRow.fromJson(Object? json) {
    final object = jsonObject(json);
    return LibrarySyncRow(table: object.string('table'), values: object.dictionary('values', SyncValue.fromJson));
  }

  @override
  bool operator ==(Object other) => other is LibrarySyncRow && other.table == table && _valuesEquality.equals(other.values, values);

  @override
  int get hashCode => Object.hash(table, _valuesEquality.hash(values));
}

class LibrarySyncChange {
  const LibrarySyncChange({required this.row, required this.timestamp, required this.device, required this.deleted});

  final LibrarySyncRow row;
  final double timestamp;
  final String device;
  final bool deleted;

  bool isNewer(LibrarySyncChange other) => timestamp == other.timestamp ? device.compareTo(other.device) > 0 : timestamp > other.timestamp;

  JsonObject toJson() => {'row': row.toJson(), 'timestamp': timestamp, 'device': device, 'deleted': deleted};

  factory LibrarySyncChange.fromJson(Object? json) {
    final object = jsonObject(json);
    return LibrarySyncChange(
      row: LibrarySyncRow.fromJson(object['row']),
      timestamp: object.number('timestamp'),
      device: object.string('device'),
      deleted: object.boolean('deleted'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LibrarySyncChange && other.row == row && other.timestamp == timestamp && other.device == device && other.deleted == deleted;

  @override
  int get hashCode => Object.hash(row, timestamp, device, deleted);
}

const changesEquality = MapEquality<String, LibrarySyncChange>();
const rowsEquality = MapEquality<String, LibrarySyncRow>();

/// Each device's clock of row changes, plus the snapshot it last captured.
class LibrarySyncLedger {
  LibrarySyncLedger({this.version = 1, Map<String, LibrarySyncChange>? changes, Map<String, LibrarySyncRow>? baseline})
    : changes = changes ?? {},
      baseline = baseline ?? {};

  int version;
  Map<String, LibrarySyncChange> changes;
  Map<String, LibrarySyncRow> baseline;

  LibrarySyncLedger copy() => LibrarySyncLedger(version: version, changes: Map.of(changes), baseline: Map.of(baseline));

  void capture(Map<String, LibrarySyncRow> snapshot, {required String device, double? now}) {
    final latest = changes.values.map((change) => change.timestamp).fold<double>(0, math.max);
    final timestamp = math.max(now ?? unixSeconds(), latest + 0.000001);
    for (final MapEntry(:key, value: row) in snapshot.entries) {
      if (baseline[key] == row) continue;
      final factory = baseline[key] == null && changes[key] == null && row.isFactoryDefault;
      changes[key] = LibrarySyncChange(row: row, timestamp: factory ? 0 : timestamp, device: device, deleted: false);
    }
    for (final MapEntry(:key, value: row) in baseline.entries) {
      if (snapshot.containsKey(key)) continue;
      final keyColumns = LibrarySyncRow.keys[row.table] ?? const <String>[];
      final tombstone = LibrarySyncRow(
        table: row.table,
        values: {
          for (final entry in row.values.entries)
            if (keyColumns.contains(entry.key)) entry.key: entry.value,
        },
      );
      changes[key] = LibrarySyncChange(row: tombstone, timestamp: timestamp, device: device, deleted: true);
    }
    baseline = Map.of(snapshot);
  }

  void merge(Map<String, LibrarySyncChange> remote) {
    for (final MapEntry(:key, value: change) in remote.entries) {
      if (key != change.row.key || LibrarySyncRow.keys[change.row.table] == null) continue;
      final existing = changes[key];
      if (existing == null || change.isNewer(existing)) changes[key] = change;
    }
  }

  JsonObject toJson() => {
    'version': version,
    'changes': {for (final entry in changes.entries) entry.key: entry.value.toJson()},
    'baseline': {for (final entry in baseline.entries) entry.key: entry.value.toJson()},
  };

  factory LibrarySyncLedger.fromJson(Object? json) {
    final object = jsonObject(json);
    return LibrarySyncLedger(
      version: object.integer('version'),
      changes: object.dictionary('changes', LibrarySyncChange.fromJson),
      baseline: object.dictionary('baseline', LibrarySyncRow.fromJson),
    );
  }
}

/// What each device uploads: its full change clock.
class LibrarySyncDocument {
  LibrarySyncDocument({this.version = 1, required this.changes});
  int version;
  final Map<String, LibrarySyncChange> changes;

  JsonObject toJson() => {
    'version': version,
    'changes': {for (final entry in changes.entries) entry.key: entry.value.toJson()},
  };

  factory LibrarySyncDocument.fromJson(Object? json) {
    final object = jsonObject(json);
    return LibrarySyncDocument(version: object.integer('version'), changes: object.dictionary('changes', LibrarySyncChange.fromJson));
  }

  /// `JSONEncoder` with `.sortedKeys` and `.withoutEscapingSlashes`, as the native app uploads it.
  Uint8List encode() => encodeJson(toJson(), escapingSlashes: false);

  static const maximumBytes = 128 * 1024 * 1024;

  static LibrarySyncDocument decode(List<int> data) {
    if (data.length > maximumBytes) throw SwiftJsonError('Document too large');
    final document = LibrarySyncDocument.fromJson(decodeJsonValue(data));
    if (document.version != 1) throw SwiftJsonError('Unsupported document version');
    return document;
  }
}

/// The `PropertyListSerialization` binary format (`bplist00`) the native app stores
/// preference values in: `{"value": <value>}` for booleans, numbers, strings, data
/// and arrays of them.
abstract final class BinaryPropertyList {
  static Uint8List encode(Object value) {
    final objects = <Object>[];
    final children = <List<int>>[];
    int flatten(Object value) {
      final index = objects.length;
      objects.add(value);
      children.add(const []);
      if (value is Map) {
        final keys = value.keys.cast<String>().toList()..sort();
        children[index] = [for (final key in keys) flatten(key), for (final key in keys) flatten(value[key] as Object)];
      } else if (value is List && value is! Uint8List) {
        children[index] = [for (final element in value) flatten(element as Object)];
      }
      return index;
    }

    flatten(value);
    final refSize = objects.length < 256 ? 1 : 2;
    final body = BytesBuilder();
    body.add(ascii.encode('bplist00'));
    final offsets = <int>[];
    void marker(int high, int count) {
      if (count < 15) {
        body.addByte(high << 4 | count);
      } else {
        body.addByte(high << 4 | 0xF);
        _integer(body, count);
      }
    }

    for (var index = 0; index < objects.length; index++) {
      offsets.add(body.length);
      final object = objects[index];
      switch (object) {
        case final bool value:
          body.addByte(value ? 0x09 : 0x08);
        case final int value:
          _integer(body, value);
        case final double value:
          body.addByte(0x23);
          body.add((ByteData(8)..setFloat64(0, value)).buffer.asUint8List());
        case final String value:
          if (value.codeUnits.every((unit) => unit < 0x80)) {
            marker(0x5, value.length);
            body.add(ascii.encode(value));
          } else {
            marker(0x6, value.length);
            final bytes = ByteData(value.length * 2);
            for (var unit = 0; unit < value.length; unit++) {
              bytes.setUint16(unit * 2, value.codeUnitAt(unit));
            }
            body.add(bytes.buffer.asUint8List());
          }
        case final Uint8List value:
          marker(0x4, value.length);
          body.add(value);
        case List _:
          marker(0xA, children[index].length);
          for (final child in children[index]) {
            body.add(_unsigned(child, refSize));
          }
        case Map _:
          marker(0xD, children[index].length ~/ 2);
          for (final child in children[index]) {
            body.add(_unsigned(child, refSize));
          }
        default:
          throw ArgumentError('Unsupported property list value $object');
      }
    }
    final tableOffset = body.length;
    final offsetSize = tableOffset < 0x100
        ? 1
        : tableOffset < 0x10000
        ? 2
        : 4;
    for (final offset in offsets) {
      body.add(_unsigned(offset, offsetSize));
    }
    body.add(List.filled(6, 0));
    body.addByte(offsetSize);
    body.addByte(refSize);
    body.add(_unsigned(objects.length, 8));
    body.add(_unsigned(0, 8));
    body.add(_unsigned(tableOffset, 8));
    return body.toBytes();
  }

  static Object decode(List<int> raw) {
    final data = Uint8List.fromList(raw);
    if (data.length < 40 || ascii.decode(data.sublist(0, 6), allowInvalid: true) != 'bplist') throw const FormatException('Not a binary property list');
    final trailer = data.length - 32;
    final offsetSize = data[trailer + 6], refSize = data[trailer + 7];
    final count = _read(data, trailer + 8, 8), top = _read(data, trailer + 16, 8), table = _read(data, trailer + 24, 8);
    int offset(int index) => _read(data, table + index * offsetSize, offsetSize);

    Object object(int index, int depth) {
      if (index >= count || depth > 32) throw const FormatException('Invalid property list');
      var position = offset(index);
      final byte = data[position];
      final high = byte >> 4, low = byte & 0xF;
      int length() {
        if (low != 0xF) return low;
        final size = 1 << (data[position + 1] & 0xF);
        final value = _read(data, position + 2, size);
        position += 1 + size;
        return value;
      }

      switch (high) {
        case 0x0:
          if (low == 0x8) return false;
          if (low == 0x9) return true;
          throw const FormatException('Unsupported property list value');
        case 0x1:
          final size = 1 << low;
          final value = _read(data, position + 1, size);
          return size == 8 ? value.toSigned(64) : value;
        case 0x2:
          final size = 1 << low;
          final bytes = ByteData.sublistView(data, position + 1, position + 1 + size);
          return size == 4 ? bytes.getFloat32(0) : bytes.getFloat64(0);
        case 0x4:
          final count = length();
          return Uint8List.fromList(data.sublist(position + 1, position + 1 + count));
        case 0x5:
          final count = length();
          return ascii.decode(data.sublist(position + 1, position + 1 + count));
        case 0x6:
          final count = length();
          final bytes = ByteData.sublistView(data, position + 1, position + 1 + count * 2);
          return String.fromCharCodes([for (var unit = 0; unit < count; unit++) bytes.getUint16(unit * 2)]);
        case 0xA:
          final count = length();
          return [for (var item = 0; item < count; item++) object(_read(data, position + 1 + item * refSize, refSize), depth + 1)];
        case 0xD:
          final count = length();
          final result = <String, Object>{};
          for (var item = 0; item < count; item++) {
            final key = object(_read(data, position + 1 + item * refSize, refSize), depth + 1);
            final value = object(_read(data, position + 1 + (count + item) * refSize, refSize), depth + 1);
            if (key is! String) throw const FormatException('Invalid property list key');
            result[key] = value;
          }
          return result;
        default:
          throw const FormatException('Unsupported property list value');
      }
    }

    return object(top, 0);
  }

  static void _integer(BytesBuilder body, int value) {
    if (value >= 0 && value <= 0xFF) {
      body.addByte(0x10);
      body.add(_unsigned(value, 1));
    } else if (value >= 0 && value <= 0xFFFF) {
      body.addByte(0x11);
      body.add(_unsigned(value, 2));
    } else if (value >= 0 && value <= 0xFFFFFFFF) {
      body.addByte(0x12);
      body.add(_unsigned(value, 4));
    } else {
      body.addByte(0x13);
      body.add(_unsigned(value, 8));
    }
  }

  static List<int> _unsigned(int value, int size) => [for (var byte = size - 1; byte >= 0; byte--) (value >> (byte * 8)) & 0xFF];

  static int _read(Uint8List data, int position, int size) {
    var value = 0;
    for (var byte = 0; byte < size; byte++) {
      value = (value << 8) | data[position + byte];
    }
    return value;
  }
}
