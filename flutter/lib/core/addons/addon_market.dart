import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../study/study_models.dart';
import '../support/l10n.dart';
import '../support/privacy_settings.dart';
import 'addon_models.dart';
import 'addon_store.dart';

// MARK: - The catalog

/// The list of official add-ons, published by TEGNAL beside their files as `catalog.json` (`AddonCatalog`).
///
/// That file holds the list's exact bytes and their signature together (`{"payload": base64, "signature": base64}`),
/// so the two always change at once. The list is signed with TEGNAL's key and names each file's size and
/// SHA-256, so the app installs only the copy that was published, even if the server that holds the files
/// were changed by someone else. A downloaded file is then read and checked exactly like a file the person opens.
class AddonCatalog {
  const AddonCatalog(this.addons);
  static const format = 'tegnal-addon-catalog';
  static const schemaVersion = 1;
  static const maximumBytes = 1024 * 1024;

  final List<AddonListing> addons;
}

/// One official add-on in the catalog. Its file lives at `files/<id>/<version>.tegnaladdon` (`AddonListing`).
class AddonListing {
  AddonListing({
    required this.id,
    required this.version,
    required this.mode,
    this.grade,
    required this.name,
    required this.author,
    this.summary,
    required this.kinds,
    required this.size,
    required this.sha256,
    this.schemaVersion,
  });

  String id;
  String version;
  final AddonMode mode;

  /// `recommended`, `suggested` or `optional`. Anything else is shown as optional.
  final String? grade;
  final StudyText name;
  final String author;
  final StudyText? summary;

  /// `translations`, `searchTags`, `challenges` and `track`.
  final List<String> kinds;
  final int size;
  String sha256;

  /// The add-on file format it is written in. One newer than the app's is shown but cannot be installed.
  final int? schemaVersion;

  String get title => name.addonResolved();
  AddonGrade get addonGrade => AddonGrade.values.where((value) => value.name == grade).firstOrNull ?? AddonGrade.optional;
  List<AddonKind> get addonKinds => [for (final kind in kinds) ?AddonKind.values.where((value) => value.name == kind).firstOrNull];
  String get path => 'files/$id/$version.${Addon.fileExtension}';
  bool get supported => (schemaVersion ?? 1) <= Addon.schemaVersion;

  bool get valid =>
      AddonCheck.identifier(id) &&
      AddonCheck.version(version) &&
      AddonCheck.text(name, max: 80) &&
      AddonCheck.line(author, max: 80) &&
      (summary == null || AddonCheck.text(summary!, max: 600, multiline: true)) &&
      size >= 1 &&
      size <= Addon.maximumBytes &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) &&
      kinds.length <= 8 &&
      (schemaVersion ?? 1) >= 1;

  /// Reads one entry, or null when it is not shaped like one.
  static AddonListing? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    StudyText? text(Object? value) {
      if (value is! Map<String, Object?> || !value.values.every((inner) => inner is String)) return null;
      return value.cast<String, String>();
    }

    final mode = AddonMode.values.where((value) => value.name == json['mode']).firstOrNull;
    final grade = json['grade'];
    if (mode == null || (grade != null && grade is! String)) return null;
    final id = json['id'], version = json['version'], name = text(json['name']), author = json['author'];
    final kinds = json['kinds'], size = json['size'], sha256 = json['sha256'], schema = json['schemaVersion'];
    if (id is! String || version is! String || name == null || author is! String || size is! int || sha256 is! String) return null;
    if (kinds is! List || !kinds.every((kind) => kind is String)) return null;
    if (json['summary'] != null && text(json['summary']) == null) return null;
    if (schema != null && schema is! int) return null;
    return AddonListing(
      id: id,
      version: version,
      mode: mode,
      grade: grade as String?,
      name: name,
      author: author,
      summary: text(json['summary']),
      kinds: kinds.cast<String>(),
      size: size,
      sha256: sha256,
      schemaVersion: schema as int?,
    );
  }
}

/// How strongly TEGNAL suggests an official add-on. The list is grouped by grade, in this order (`AddonGrade`).
enum AddonGrade {
  recommended,
  suggested,
  optional;

  String get title => switch (this) {
    recommended => L10n.text('addon.grade.recommended'),
    suggested => L10n.text('addon.grade.suggested'),
    optional => L10n.text('addon.grade.optional'),
  };

  String get detail => switch (this) {
    recommended => L10n.text('TEGNAL advises these for almost everyone.'),
    suggested => L10n.text('Useful for many people.'),
    optional => L10n.text('For particular tastes and uses.'),
  };
}

/// How an official add-on in the catalog stands against what is installed (`AddonListingState`).
enum AddonListingState {
  get,
  installed,
  update,
  fromFile,
  unsupported;

  static AddonListingState of(AddonListing listing, InstalledAddon? installed) {
    if (!listing.supported) return unsupported;
    if (installed == null) return get;
    if (!installed.official) return fromFile;
    if (installed.digest == listing.sha256) return AddonListingState.installed;
    return AddonCheck.compare(listing.version, installed.addon.version) > 0 ? update : AddonListingState.installed;
  }
}

class AddonMarketError implements Exception {
  const AddonMarketError.offline() : kind = 'offline', status = null;
  const AddonMarketError.server(int this.status) : kind = 'server';
  const AddonMarketError.unsigned() : kind = 'unsigned', status = null;
  const AddonMarketError.damaged() : kind = 'damaged', status = null;

  final String kind;
  final int? status;

  String get errorDescription => switch (kind) {
    'offline' => L10n.text('The add-on server could not be reached. Check your connection and try again.'),
    'server' => L10n.text('The add-on server answered with an error (%@). Try again later.', ['$status']),
    'unsigned' => L10n.text('The list of official add-ons could not be confirmed as TEGNAL’s, so it is not shown. Try again later.'),
    _ => L10n.text('The downloaded file did not match the official copy, so it was not installed.'),
  };

  @override
  bool operator ==(Object other) => other is AddonMarketError && other.kind == kind && other.status == status;
  @override
  int get hashCode => Object.hash(kind, status);
  @override
  String toString() => 'AddonMarketError.$kind${status == null ? '' : '($status)'}';
}

/// Fetches one file, no larger than the limit given.
typedef AddonFetch = Future<List<int>> Function(Uri url, int limit);

// MARK: - The market

/// Reads the official catalog and downloads its add-ons from TEGNAL's file server (`AddonMarket`).
class AddonMarket {
  AddonMarket({required this.base, required this.publicKey, AddonFetch? fetch}) : fetch = fetch ?? AddonMarket.get;

  /// TEGNAL's add-on bucket, served over HTTPS.
  static final liveBase = Uri.parse('https://addons.nextline.work/v1/');

  /// The public half of TEGNAL's add-on signing key: an uncompressed P-256 point, base64.
  static const livePublicKey = 'BPv9FYG+EK8HUde5G9dQdmXEWBKuKxfugSVz/Kz1QjeSsCX6gd+IJ0ijqdBjgo705slZl5eK981OZYgzicVCzsk=';
  static final live = AddonMarket(base: liveBase, publicKey: publicKeyFrom(base64.decode(livePublicKey)));

  final Uri base;
  final ECPublicKey publicKey;
  final AddonFetch fetch;

  static ECPublicKey publicKeyFrom(List<int> x963) {
    final curve = ECCurve_secp256r1();
    return ECPublicKey(curve.curve.decodePoint(x963), curve);
  }

  Future<AddonCatalog> catalog() async => open(await fetch(base.resolve('catalog.json'), AddonCatalog.maximumBytes * 2), publicKey);

  /// Downloads an official add-on and checks it against the signed catalog before reading it.
  Future<({Addon addon, String digest})> download(AddonListing listing) async => check(await fetch(base.resolve(listing.path), listing.size), listing);

  /// Reads the published `catalog.json`: the list's bytes and their signature.
  static AddonCatalog open(List<int> file, ECPublicKey key) {
    final List<int> payload, signature;
    try {
      final envelope = jsonDecode(utf8.decode(file));
      if (envelope is! Map<String, Object?>) throw const AddonMarketError.unsigned();
      payload = base64.decode(envelope['payload']! as String);
      signature = base64.decode(envelope['signature']! as String);
    } on AddonMarketError {
      rethrow;
    } on Object {
      throw const AddonMarketError.unsigned();
    }
    return verify(payload, signature, key);
  }

  /// Checks the signature (ECDSA P-256 with SHA-256, DER) over the exact bytes of the list, then reads it.
  /// Entries that do not pass are left out.
  static AddonCatalog verify(List<int> data, List<int> der, ECPublicKey key) {
    if (data.length > AddonCatalog.maximumBytes) throw const AddonMarketError.unsigned();
    final signature = _signature(der);
    if (signature == null) throw const AddonMarketError.unsigned();
    final signer = ECDSASigner(SHA256Digest())..init(false, PublicKeyParameter<ECPublicKey>(key));
    final bool valid;
    try {
      valid = signer.verifySignature(Uint8List.fromList(data), signature);
    } on Object {
      throw const AddonMarketError.unsigned();
    }
    if (!valid) throw const AddonMarketError.unsigned();
    final Object? top;
    try {
      top = jsonDecode(utf8.decode(data));
    } on Object {
      throw const AddonMarketError.unsigned();
    }
    if (top is! Map<String, Object?> || top['format'] != AddonCatalog.format || top['addons'] is! List) throw const AddonMarketError.unsigned();
    final schema = top['schemaVersion'];
    if (schema is! int) throw const AddonMarketError.unsigned();
    if (schema > AddonCatalog.schemaVersion) throw const AddonError.newerFormat();
    final seen = <String>{};
    return AddonCatalog([
      for (final entry in top['addons']! as List)
        if (AddonListing.fromJson(entry) case final listing? when listing.valid && seen.add(listing.id)) listing,
    ]);
  }

  static ({Addon addon, String digest}) check(List<int> data, AddonListing listing) {
    if (data.length != listing.size || Addon.digest(data) != listing.sha256) throw const AddonMarketError.damaged();
    final read = Addon.decode(data);
    if (read.addon.id != listing.id || read.addon.version != listing.version || read.addon.mode != listing.mode) throw const AddonMarketError.damaged();
    return read;
  }

  /// A DER `SEQUENCE { INTEGER r, INTEGER s }`, read strictly.
  static ECSignature? _signature(List<int> der) {
    var index = 0;
    int? length() {
      if (index >= der.length) return null;
      final first = der[index++];
      if (first < 0x80) return first;
      if (first != 0x81 || index >= der.length) return null;
      return der[index++];
    }

    BigInt? integer() {
      if (index >= der.length || der[index++] != 0x02) return null;
      final size = length();
      if (size == null || size < 1 || size > 33 || index + size > der.length) return null;
      final bytes = der.sublist(index, index + size);
      index += size;
      if (bytes.first & 0x80 != 0) return null;
      return bytes.fold<BigInt>(BigInt.zero, (value, byte) => (value << 8) | BigInt.from(byte));
    }

    if (der.isEmpty || der[index++] != 0x30) return null;
    final total = length();
    if (total == null || index + total != der.length) return null;
    final r = integer(), s = integer();
    if (r == null || s == null || index != der.length) return null;
    return ECSignature(r, s);
  }

  static Future<List<int>> get(Uri url, int limit) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    NetworkPrivacy.configure(client);
    try {
      final request = await client.getUrl(url).timeout(const Duration(seconds: 30));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw AddonMarketError.server(response.statusCode);
      }
      if (response.contentLength > limit) throw const AddonMarketError.damaged();
      final body = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        body.add(chunk);
        if (body.length > limit) throw const AddonMarketError.damaged();
      }
      return body.takeBytes();
    } on AddonMarketError {
      rethrow;
    } on Object {
      throw const AddonMarketError.offline();
    } finally {
      client.close(force: true);
    }
  }
}
