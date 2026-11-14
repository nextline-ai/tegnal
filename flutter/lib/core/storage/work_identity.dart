import '../../domain/models.dart';
import '../content/manga_urls.dart';
import '../support/sql_database.dart';

/// `WorkIdentity`: a saved number names one work on each website. Two websites that number
/// their works differently can hold two different works under one number, and both can be
/// saved. A work whose website is unknown (older saves, other apps' backups) waits for one:
/// the first save of that number from a website claims it.
abstract final class WorkIdentity {
  /// Websites that number their works the same way as the given one. Tests replace it.
  static List<String> Function(String site) siblings = ComicSites.siblings;

  static List<Work> rows(SqlDatabase db, int galleryId) =>
      db.rows('SELECT * FROM works WHERE gallery_id = ? ORDER BY id', [galleryId]).map(Work.fromRow).toList();

  /// The saved work a number opened on [site] refers to: the one saved from that website,
  /// then from one that numbers its works the same way, then one whose website is unknown.
  /// Without a website, the one whose website is unknown, else the first saved.
  static Work? pick(List<Work> rows, String? site) {
    if (site == null || site.isEmpty) return rows.where((work) => work.site == null).firstOrNull ?? rows.firstOrNull;
    final exact = rows.where((work) => work.site == site).firstOrNull;
    if (exact != null) return exact;
    final family = siblings(site).toSet();
    if (family.isNotEmpty) {
      final sibling = rows.where((work) => work.site != null && family.contains(work.site)).firstOrNull;
      if (sibling != null) return sibling;
    }
    return rows.where((work) => work.site == null).firstOrNull;
  }

  /// Where a work from a file that does not say its website lands: the saved one whose
  /// website is unknown, else a saved one that is the same work. When the file says nothing
  /// about the work either, there is no telling, so it stays with the first saved one.
  static Work? importMatch(List<Work> rows, {String? title, String? artists}) {
    final unknown = rows.where((work) => work.site == null).firstOrNull;
    if (unknown != null) return unknown;
    if (rows.isEmpty) return null;
    final described = (title ?? '').trim().isNotEmpty || (artists ?? '').trim().isNotEmpty;
    if (!described) return rows.first;
    return rows.where((work) => sameWork(work, title: title, artists: artists)).firstOrNull;
  }

  /// Shared artists decide; without artists on both sides, the cleaned titles do. With
  /// neither, the two cannot be told apart and count as the same.
  static bool sameWork(Work work, {String? title, String? artists}) {
    final saved = names(work.artists), incoming = names(artists);
    if (saved.isNotEmpty && incoming.isNotEmpty) return saved.intersection(incoming).isNotEmpty;
    final first = WorkMatcher.normalizedTitle(work.title ?? ''), second = WorkMatcher.normalizedTitle(title ?? '');
    if (first.isNotEmpty && second.isNotEmpty) return first == second;
    return true;
  }

  static Set<String> names(String? list) => WorkMatcher.names((list ?? '').split(','));

  /// One row per number travels as that number, as older versions expect: the first website
  /// by name, so every device picks the same one, and only without any the one whose website
  /// is unknown. A number row without a website then means its sender knows no website for it.
  static const primaryCondition = 'w.id = (SELECT p.id FROM works p WHERE p.gallery_id = w.gallery_id ORDER BY p.site IS NULL, p.site LIMIT 1)';

  /// The row a number alone names, as older versions send it.
  static Work? primary(List<Work> rows) {
    final known = rows.where((work) => work.site != null).toList()..sort((a, b) => a.site!.compareTo(b.site!));
    return known.firstOrNull ?? rows.where((work) => work.site == null).firstOrNull;
  }

  /// Covers of works saved from a website carry it in their file name, so two works under
  /// one number never share a cover file.
  static String thumbnailName(int galleryId, String? site) {
    if (site == null || site.isEmpty) return 'native_$galleryId.jpg';
    final slug = site.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '-');
    return 'native_${galleryId}_$slug.jpg';
  }
}

/// `SavedWorkKeys`: which numbers count as saved on each website: the works saved from it or
/// from one that numbers its works the same way, and those whose website is unknown.
class SavedWorkKeys {
  SavedWorkKeys({Set<int>? unknown, Map<String, Set<int>>? bySite}) : unknown = unknown ?? {}, bySite = bySite ?? {};
  final Set<int> unknown;
  final Map<String, Set<int>> bySite;

  static SavedWorkKeys fetch(SqlDatabase db) {
    final keys = SavedWorkKeys();
    for (final row in db.rows('SELECT gallery_id, site FROM works')) {
      final id = row['gallery_id'] as int, site = row['site'] as String?;
      if (site != null && site.isNotEmpty) {
        keys.bySite.putIfAbsent(site, () => {}).add(id);
      } else {
        keys.unknown.add(id);
      }
    }
    return keys;
  }

  Set<int> idsOn(String site) => {...unknown, ...?bySite[site], for (final sibling in WorkIdentity.siblings(site)) ...?bySite[sibling]};
}

/// `WorkMatcher`: recognizes one work listed by two websites. Their listings copy each
/// other's text, so a cleaned title, the artists and the page count are enough to tell.
abstract final class WorkMatcher {
  static const _opening = '[({【（〔', _closing = '])}】）〕';
  static final _letters = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// Lowercased, width-folded, without bracketed parts such as circles, events, languages
  /// and translators, and without spaces or punctuation.
  static String normalizedTitle(String title) {
    final folded = _widthFolded(title).toLowerCase();
    var depth = 0;
    final kept = StringBuffer();
    for (final character in folded.runes.map(String.fromCharCode)) {
      if (_opening.contains(character)) {
        depth += 1;
        continue;
      }
      if (_closing.contains(character)) {
        depth = depth > 0 ? depth - 1 : 0;
        continue;
      }
      if (depth == 0) kept.write(character);
    }
    String clean(String text) => _letters.allMatches(text).map((match) => match.group(0)).join();
    final result = clean(kept.toString());
    return result.isEmpty ? clean(folded) : result;
  }

  /// Full-width letters, digits and punctuation as their plain forms, as Unicode's
  /// compatibility mapping folds them.
  static String _widthFolded(String text) => String.fromCharCodes(
    text.runes.map((rune) => rune >= 0xFF01 && rune <= 0xFF5E ? rune - 0xFEE0 : (rune == 0x3000 ? 0x20 : rune)),
  );

  static Set<String> names(Iterable<String> values) =>
      values.map((value) => value.toLowerCase().replaceAll('_', ' ').trim()).where((value) => value.isNotEmpty).toSet();

  static WorkFingerprint fingerprint({required Iterable<String> titles, required Iterable<String> artists, required int pages}) =>
      WorkFingerprint(titles.map(normalizedTitle).where((title) => title.runes.length >= 2).toSet(), names(artists), pages);

  /// Same cleaned title, page counts at most two apart (credit pages), and shared artists
  /// when both name some.
  static bool isSameWork(WorkFingerprint first, WorkFingerprint second) {
    if (first.titles.intersection(second.titles).isEmpty) return false;
    if (first.pages > 0 && second.pages > 0 && (first.pages - second.pages).abs() > 2) return false;
    if (first.artists.isNotEmpty && second.artists.isNotEmpty && first.artists.intersection(second.artists).isEmpty) return false;
    return true;
  }
}

class WorkFingerprint {
  const WorkFingerprint(this.titles, this.artists, this.pages);
  final Set<String> titles;
  final Set<String> artists;
  final int pages;
}
