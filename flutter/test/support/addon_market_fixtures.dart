import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:tegnal/core/addons/addon_market.dart';
import 'package:tegnal/core/addons/addon_models.dart';

/// A P-256 key pair for signing test catalogs, as CryptoKit's `P256.Signing.PrivateKey()`.
class TestSigningKey {
  TestSigningKey() {
    final random = FortunaRandom()..seed(KeyParameter(Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256)))));
    _random = random;
    final generator = ECKeyGenerator()..init(ParametersWithRandom(ECKeyGeneratorParameters(ECCurve_secp256r1()), random));
    final pair = generator.generateKeyPair();
    private = pair.privateKey;
    public = pair.publicKey;
  }
  late final SecureRandom _random;
  late final ECPrivateKey private;
  late final ECPublicKey public;

  /// A DER signature, as `derRepresentation`.
  List<int> sign(List<int> data) {
    final signer = ECDSASigner(SHA256Digest())..init(true, ParametersWithRandom(PrivateKeyParameter<ECPrivateKey>(private), _random));
    final signature = signer.generateSignature(Uint8List.fromList(data)) as ECSignature;
    List<int> integer(BigInt value) {
      var bytes = <int>[];
      for (var rest = value; rest > BigInt.zero; rest >>= 8) {
        bytes.insert(0, (rest & BigInt.from(0xff)).toInt());
      }
      if (bytes.isEmpty || bytes.first & 0x80 != 0) bytes = [0, ...bytes];
      return [0x02, bytes.length, ...bytes];
    }

    final body = [...integer(signature.r), ...integer(signature.s)];
    return [0x30, body.length, ...body];
  }
}

/// A market served from memory, its catalog signed with [key].
AddonMarket memoryMarket(TestSigningKey key, {required List<Map<String, Object?>> listings, required Map<String, List<int>> files}) {
  final base = Uri.parse('https://addons.invalid/v1/');
  final data = utf8.encode(jsonEncode({'format': 'tegnal-addon-catalog', 'schemaVersion': 1, 'addons': listings}));
  final served = {
    'catalog.json': utf8.encode(jsonEncode({'payload': base64.encode(data), 'signature': base64.encode(key.sign(data))})),
    ...files,
  };
  return AddonMarket(
    base: base,
    publicKey: key.public,
    fetch: (url, limit) async {
      final file = served[url.toString().substring(base.toString().length)];
      if (file == null) throw const AddonMarketError.server(404);
      if (file.length > limit) throw const AddonMarketError.damaged();
      return file;
    },
  );
}

/// A catalog entry for [file], as the catalog lists it, for a mode and grade.
Map<String, Object?> addonListing(List<int> file, {required String id, required String name, String mode = 'images', String? grade, String version = '1.0'}) =>
    {
      'id': id,
      'version': version,
      'mode': mode,
      'grade': ?grade,
      'name': {'en': name},
      'author': 'TEGNAL',
      'kinds': ['translations'],
      'size': file.length,
      'sha256': Addon.digest(file),
    };
