import 'dart:math' as math;

import '../booru/booru_client.dart';
import '../booru/booru_models.dart';
import '../booru/booru_store.dart';
import '../support/swift_json.dart';

/// `ChallengeMediaFilter`: shared filtering for live results and saved folders.
/// Random searches are not taste evidence, so nothing here records any.
abstract final class ChallengeMediaFilter {
  static bool matches(BooruPost post, {required List<String> tags, required String blacklist}) {
    if (BooruBlacklist(blacklist).contains(post)) return false;
    final available = {for (final tag in post.tags) tag.toLowerCase()};
    return tags.every((tag) => available.contains(tag.toLowerCase()));
  }
}

/// `ChallengeFolderSource`: a saved folder served through the same search, grid and
/// paging as a server, without making list requests online.
class ChallengeFolderSource implements BooruProviding {
  ChallengeFolderSource({required this.store, required this.folderID, required this.source});
  final BooruStore store;
  final String folderID;

  /// Details and notes still come from the server.
  final BooruProviding source;

  @override
  Future<BooruBatch> posts(BooruServer server, String query, int page) async {
    final terms = splitWhitespace(query);
    final tags = terms.where((term) => !term.startsWith('order:') && !term.startsWith('sort:')).toList();
    final popular = terms.contains('order:score') || terms.contains('sort:score:desc');
    final blacklist = store.blacklist(server.id);
    final all = store.visibleFavorites(folderID: folderID).where((post) {
      final available = {for (final tag in post.tags) tag.toLowerCase()};
      final matches = tags.every((term) {
        final negative = term.startsWith('-');
        final value = negative ? term.substring(1) : term;
        final match = value.startsWith('rating:') ? value.substring(7).toLowerCase() == post.rating.toLowerCase() : available.contains(value.toLowerCase());
        return negative ? !match : match;
      });
      return matches && post.serverID == server.id && ChallengeMediaFilter.matches(post, tags: const [], blacklist: blacklist);
    }).toList();
    if (popular) all.sort((a, b) => a.score == b.score ? b.postID.compareTo(a.postID) : b.score.compareTo(a.score));
    final start = math.max(0, page) * BooruClient.pageSize;
    return BooruBatch(posts: all.skip(start).take(BooruClient.pageSize).toList(), hasMore: start + BooruClient.pageSize < all.length);
  }

  @override
  Future<List<BooruTag>> suggestions(BooruServer server, String token) async {
    final counts = <String, int>{};
    for (final post in store.visibleFavorites(folderID: folderID)) {
      if (post.serverID != server.id) continue;
      for (final tag in post.tags) {
        if (tag.startsWith(token)) counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    final ranked = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return [for (final entry in ranked.take(12)) BooruTag(name: entry.key, count: entry.value, category: 0)];
  }

  @override
  Future<BooruPost> details(BooruServer server, BooruPost post) => source.details(server, post);
  @override
  Future<List<BooruNote>> notes(BooruServer server, int postID) => source.notes(server, postID);
  @override
  Future<List<BooruPool>> pools(BooruServer server, String query, int page) async => [];
  @override
  Future<BooruBatch> poolPosts(BooruServer server, int poolID, int page) async => const BooruBatch(posts: [], hasMore: false);
}
