import '../../domain/models.dart';
import '../booru/booru_models.dart';
import '../booru/booru_store.dart';
import '../support/l10n.dart';
import 'app_database.dart';
import 'folder_rules.dart';

/// What "Classify into Folders" groups saved works by. Rating and server apply to images only.
enum LibraryClassification {
  artist,
  language,
  type,
  series,
  rating,
  server;

  String get rawValue => name;

  /// The English key for `L10n.text`.
  String get title => switch (this) {
    artist => 'Artists',
    language => 'Language',
    type => 'Type',
    series => 'Series',
    rating => 'Rating',
    server => 'Server',
  };

  /// The criteria a library offers: comics have no rating or server.
  static List<LibraryClassification> available({required bool booru}) => values.where((value) => booru || (value != rating && value != server)).toList();
}

/// One folder-to-be or one set of possible duplicates.
class LibraryClassificationGroup {
  LibraryClassificationGroup({required this.name, List<Work>? works, List<BooruPost>? posts}) : works = works ?? [], posts = posts ?? [];

  final String name;
  final List<Work> works;
  final List<BooruPost> posts;

  String get id => name;
  int get count => works.length + posts.length;
}

/// `LibraryMaintenance`: classification and duplicate review over metadata already saved.
abstract final class LibraryMaintenance {
  static List<LibraryClassificationGroup> classification({
    required List<Work> works,
    required List<BooruPost> posts,
    required LibraryClassification criterion,
    Map<String, String> serverNames = const {},
  }) {
    final groups = <String, LibraryClassificationGroup>{};
    List<String> names(String? text) => (text ?? '').split(', ').map((value) => value.trim()).where((value) => value.isNotEmpty).toList();
    for (final work in works) {
      final values = switch (criterion) {
        LibraryClassification.artist => names(work.artists),
        LibraryClassification.language => names(work.language),
        LibraryClassification.type => names(work.type),
        LibraryClassification.series => names(work.series),
        _ => const <String>[],
      };
      for (final value in values.toSet()) {
        groups.putIfAbsent(value, () => LibraryClassificationGroup(name: value)).works.add(work);
      }
    }
    for (final post in posts) {
      final String? value = switch (criterion) {
        LibraryClassification.artist => post.artists.firstOrNull,
        LibraryClassification.rating => post.rating,
        LibraryClassification.server => serverNames[post.serverID] ?? post.serverID,
        LibraryClassification.type => post.fileExtension,
        LibraryClassification.series => post.tags.where((tag) => post.tagCategories?[tag] == 3).firstOrNull,
        LibraryClassification.language => post.tags.where((tag) => tag.startsWith('language:')).firstOrNull,
      };
      if (value != null && value.isNotEmpty) {
        groups.putIfAbsent(value, () => LibraryClassificationGroup(name: value)).posts.add(post);
      }
    }
    return groups.values.toList()..sort((a, b) => localizedStandardCompare(a.name, b.name));
  }

  /// Title, artists, language and type, each with its whitespace collapsed; null without a title or artist.
  static String? duplicateKey(Work work) {
    final title = work.title, artists = work.artists;
    if (title == null || title.trim().isEmpty || artists == null || artists.isEmpty) return null;
    String collapse(String value) => value.toLowerCase().split(RegExp(r'\s+')).where((part) => part.isNotEmpty).join(' ');
    return [title, artists, work.language ?? '', work.type ?? ''].map(collapse).join('\u0000');
  }

  /// The file's hash when its name is one, otherwise its whole address.
  static String? postDuplicateKey(BooruPost post) {
    final file = post.fileURL;
    if (file == null) return null;
    final uri = Uri.tryParse(file);
    final last = uri == null || uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    final dot = last.lastIndexOf('.');
    final stem = (dot > 0 ? last.substring(0, dot) : last).toLowerCase();
    if (const [32, 40, 64].contains(stem.length) && RegExp(r'^[0-9a-f]+$').hasMatch(stem)) return 'hash:$stem';
    return 'url:$file';
  }

  static List<LibraryClassificationGroup> duplicates({required List<Work> works, required List<BooruPost> posts}) {
    final groups = <String, LibraryClassificationGroup>{};
    for (final work in works) {
      final key = duplicateKey(work);
      if (key != null) groups.putIfAbsent(key, () => LibraryClassificationGroup(name: key)).works.add(work);
    }
    for (final post in posts) {
      final key = postDuplicateKey(post);
      if (key != null) groups.putIfAbsent(key, () => LibraryClassificationGroup(name: key)).posts.add(post);
    }
    return groups.values.where((group) => group.count > 1).toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  /// Keeps one comic: the others' folders and notes move onto it, then they are deleted.
  /// A copy whose metadata changed since the review is left alone.
  static void mergeComics(LibraryClassificationGroup group, {required int keeping, required AppDatabase database}) {
    if (!group.works.any((work) => work.galleryId == keeping)) return;
    database.dbWriter.write((db) {
      Work? fetch(int galleryId) {
        final row = db.rows('SELECT * FROM works WHERE gallery_id = ?', [galleryId]).firstOrNull;
        return row == null ? null : Work.fromRow(row);
      }

      final keeper = fetch(keeping);
      final keeperID = keeper?.id;
      if (keeper == null || keeperID == null) return;
      final notes = [keeper.note].whereType<String>().where((note) => note.isNotEmpty).toList();
      for (final candidate in group.works) {
        if (candidate.galleryId == keeping) continue;
        final work = fetch(candidate.galleryId);
        final oldID = work?.id;
        if (work == null || oldID == null || duplicateKey(work) != group.name || duplicateKey(keeper) != group.name) continue;
        db.execute('INSERT INTO folder_works (folder_id, work_id, added_at) SELECT folder_id, ?, added_at FROM folder_works WHERE work_id = ? ON CONFLICT(folder_id, work_id) DO UPDATE SET added_at = MAX(added_at, excluded.added_at)', [
          keeperID,
          oldID,
        ]);
        final note = work.note;
        if (note != null && note.isNotEmpty && !notes.contains(note)) notes.add(note);
        db.execute('DELETE FROM works WHERE id = ?', [oldID]);
      }
      AppDatabaseFolderRules.leaveUnfiled(keeperID, db);
      db.execute('UPDATE works SET note = ? WHERE id = ?', [notes.join('\n\n'), keeperID]);
    });
  }

  /// Images keep only the chosen copy, in its own folder.
  static void mergeImages(LibraryClassificationGroup group, {required String keeping, required BooruStore images}) =>
      images.removeFavorites(group.posts.where((post) => post.id != keeping).toList());

  /// The works or images a screen reviews. "Only Unsorted" keeps works outside any real folder
  /// and images still unsorted or in a site folder; duplicate review always reads everything.
  static ({List<Work> works, List<BooruPost> posts}) load({
    required AppDatabase database,
    BooruStore? images,
    required bool booru,
    required bool onlyUnsorted,
    required bool duplicates,
  }) {
    final filter = onlyUnsorted && !duplicates;
    if (booru) {
      final store = images;
      if (store == null) return (works: const [], posts: const []);
      final posts = store.favorites(store.servers.map((server) => server.id).toList()).where((post) {
        if (!filter) return true;
        final folder = store.folderIDFor(post);
        return folder == 'unsorted' || (folder?.startsWith('site:') ?? false);
      }).toList();
      return (works: const [], posts: posts);
    }
    final works = database.listWorks().where((work) {
      if (!filter) return true;
      return work.folders.isEmpty || work.folders.every((folder) => folder.displayName == L10n.text('Unsorted') || folder.name == '미분류');
    }).toList();
    return (works: works, posts: const []);
  }

  /// `classify()`: each group becomes "criterion · value", reusing a folder of that name.
  /// Comics join the folder and keep their other folders; images move into it.
  static void classify(List<LibraryClassificationGroup> groups, {required String title, required AppDatabase database, BooruStore? images}) {
    for (final group in groups) {
      final name = '$title · ${group.name.replaceAll('_', ' ')}';
      if (group.works.isNotEmpty) {
        final folder = database.listFolders().where((folder) => folder.name == name).firstOrNull ?? database.createFolder(name: name);
        final folderID = folder.id;
        if (folderID == null) continue;
        for (final work in group.works) {
          final id = work.id;
          if (id != null) database.addWorkToFolder(id, folderID);
        }
      } else if (images != null && group.posts.isNotEmpty) {
        final folderID = images.folders().where((folder) => folder.name == name).firstOrNull?.id ?? images.saveFolder(name: name);
        images.moveFavorites(group.posts, folderID);
      }
    }
  }
}

/// Foundation's `localizedStandardCompare`: case-insensitive, with digit runs compared by value.
int localizedStandardCompare(String a, String b) {
  final pattern = RegExp(r'\d+|\D+');
  final left = pattern.allMatches(a.toLowerCase()).map((match) => match.group(0)!).toList();
  final right = pattern.allMatches(b.toLowerCase()).map((match) => match.group(0)!).toList();
  for (var index = 0; index < left.length && index < right.length; index++) {
    final x = left[index], y = right[index];
    final xNumber = int.tryParse(x), yNumber = int.tryParse(y);
    final result = xNumber != null && yNumber != null && xNumber != yNumber ? xNumber.compareTo(yNumber) : x.compareTo(y);
    if (result != 0) return result;
  }
  final length = left.length.compareTo(right.length);
  return length != 0 ? length : a.compareTo(b);
}
