import 'dart:typed_data';

import '../support/sql_database.dart';
import 'taste_models.dart';

/// Derives and compares image feature prints. The native app uses Apple Vision
/// (revision 2); Android supplies its own engine with its own revision, so prints
/// from different engines are never compared.
abstract interface class VisualFeatureEngine {
  int get revision;

  /// A feature print of encoded image bytes. Neither images nor prints leave the device.
  Future<Uint8List> make(Uint8List image);

  /// Candidates by ascending distance from [seed], nearest first.
  Future<List<(int id, double distance)>> rank(Uint8List seed, Map<int, Uint8List> candidates);
}

/// Feature prints of saved works, kept beside each library (`VisualFingerprintStore`).
class VisualFingerprints {
  VisualFingerprints(this.database, this.engine);
  final SqlDatabase database;
  final VisualFeatureEngine engine;

  /// Prints of works the library still holds, for one scope: `comics` or an image server's ID.
  Map<int, Uint8List> all(String scope) => database.read((db) {
    final join = scope == 'comics' ? 'JOIN works w ON w.gallery_id = f.item_id' : 'JOIN favorites w ON w.post_id = f.item_id AND w.server_id = f.scope';
    return {
      for (final row in db.rows('SELECT f.item_id, f.payload FROM visual_fingerprints f $join WHERE f.scope = ? AND f.revision = ?', [scope, engine.revision]))
        row['item_id'] as int: row['payload'] as Uint8List,
    };
  });

  /// The print of an image, cached by the image's digest; a removed work is not stored.
  Future<Uint8List> save(Uint8List data, {required String scope, required int id}) async {
    final digest = tasteDigest(data);
    final cached = database.read(
      (db) => db.value<Uint8List>('SELECT payload FROM visual_fingerprints WHERE scope = ? AND item_id = ? AND revision = ? AND digest = ?', [
        scope,
        id,
        engine.revision,
        digest,
      ]),
    );
    if (cached != null) return cached;
    final fingerprint = await engine.make(data);
    database.write((db) {
      final exists = scope == 'comics'
          ? db.exists('SELECT EXISTS(SELECT 1 FROM works WHERE gallery_id = ?)', [id])
          : db.exists('SELECT EXISTS(SELECT 1 FROM favorites WHERE server_id = ? AND post_id = ?)', [scope, id]);
      if (!exists) return;
      db.execute('INSERT OR REPLACE INTO visual_fingerprints VALUES (?, ?, ?, ?, ?)', [scope, id, engine.revision, digest, fingerprint]);
    });
    return fingerprint;
  }
}
