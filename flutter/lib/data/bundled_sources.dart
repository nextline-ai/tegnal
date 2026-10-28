import '../core/content.dart';
import 'library_store.dart';

/// A release bootstrap, explicitly invoked only for the real application DB.
/// Once stored, these are ordinary user connections independent of this code.
class BundledSources {
  static const migrationKey = 'bootstrap.sources.1_0_0';

  static void seedOnce(LibraryStore store) {
    store.transaction(() {
      if (store.setting(migrationKey, false) == true) return;
      final existing = store.sources(); // Includes archived connections.
      final usedIds = existing.map((source) => source.id).toSet();
      final addresses = {
        for (final source in existing) (source.mode, source.canonicalAddress),
      };
      for (final (baseId, address, kind) in const [
        ('bundled-hitomi', 'https://hitomi.la', SourceKind.manga),
        ('bundled-danbooru', 'https://danbooru.donmai.us', SourceKind.danbooru),
      ]) {
        final url = SourceConfig.validateUrl(address);
        final candidate = SourceConfig(
          id: baseId,
          name: url.host,
          baseUrl: url,
          kind: kind,
        );
        if (!addresses.add((candidate.mode, candidate.canonicalAddress))) {
          continue;
        }
        var id = baseId;
        var suffix = 1;
        while (!usedIds.add(id)) {
          id = '$baseId-${suffix++}';
        }
        store.saveSource(
          SourceConfig(id: id, name: url.host, baseUrl: url, kind: kind),
        );
      }
      // Commit even when both connections already exist or are archived. A
      // later removal must never cause this bootstrap to restore them.
      store.setSetting(migrationKey, true);
    });
  }
}
