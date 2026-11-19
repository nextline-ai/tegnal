import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../booru/booru_client.dart';
import '../booru/booru_models.dart';
import '../booru/booru_store.dart';
import '../support/swift_json.dart';
import 'study_engine.dart';
import 'study_models.dart';
import 'study_store.dart';

/// Reads what the connected servers know about tags, and example pictures, within the app's own limits:
/// only the servers chosen for browsing are asked, and hidden or blacklisted pictures stay out.
abstract final class StudyLookup {
  /// The server asked about tags: one that answers tag pages if any is chosen, since only that kind has them.
  static BooruServer? infoServer(BooruStore store) {
    final selected = store.selectedServers;
    return selected.where((server) => server.engine == BooruEngine.danbooru).firstOrNull ?? selected.firstOrNull;
  }

  static List<BooruPost> shown(List<BooruPost> posts, {required BooruStore store}) {
    final blacklists = <String, BooruBlacklist>{};
    return [
      for (final post in posts)
        if (StudyEngine.usable(post) &&
            store.isVisible(post) &&
            store.isShownInSafeMode(post) &&
            !(blacklists[post.serverID] ??= BooruBlacklist(store.blacklist(post.serverID))).contains(post))
          post,
    ];
  }

  /// Stops waiting after a few seconds, so a slow server never holds up a question. A one-element
  /// record holds the answer, so that an answer which is itself null differs from no answer.
  static Future<(T,)?> hurried<T>(Future<T> Function() work, {double seconds = 8}) {
    final completer = Completer<(T,)?>();
    final timer = Timer(Duration(microseconds: (seconds * 1e6).round()), () {
      if (!completer.isCompleted) completer.complete(null);
    });
    Future<T> started;
    try {
      started = work();
    } on Object {
      started = Future<T>.error(StateError('failed'));
    }
    started.then(
      (value) {
        if (!completer.isCompleted) completer.complete((value,));
      },
      onError: (Object _) {
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    return completer.future.whenComplete(timer.cancel);
  }

  /// Pictures carrying a tag from one of the chosen servers. With a [server] the choice of browsing servers
  /// and Safe Mode's own choice do not apply: that server was chosen for learning, so only hidden and
  /// blacklisted pictures stay out.
  static Future<List<BooruPost>> examples(String tag, {required BooruStore store, required BooruProviding source, int page = 0, Random? random, BooruServer? server}) async {
    if (server != null) {
      final batch = await hurried(() => source.posts(server, tag, page));
      final blacklist = BooruBlacklist(store.blacklist(server.id));
      return [
        for (final post in batch?.$1.posts ?? const <BooruPost>[])
          if (StudyEngine.usable(post) && store.isVisible(post) && !blacklist.contains(post)) post,
      ];
    }
    final servers = store.selectedServers;
    if (servers.isEmpty) return [];
    final chosen = servers[(random ?? Random()).nextInt(servers.length)];
    final batch = await hurried(() => source.posts(chosen, tag, page));
    return shown(batch?.$1.posts ?? [], store: store);
  }

  /// What the server says about one tag. A recent answer kept on the device is used as it is.
  static Future<StudyTagInfo?> info(String tag, {required BooruStore store, required BooruProviding source}) async {
    final server = infoServer(store);
    if (server == null) return null;
    final study = store.studyStore, address = server.canonicalAddress;
    StudyTagInfo? kept;
    try {
      kept = study.info(tag, address: address);
    } on Object {
      kept = null;
    }
    if (kept != null && kept.complete && !kept.isStale()) return kept;
    final counted = hurried(() => source.tags(server, [tag]));
    final page = hurried(() => source.wiki(server, tag));
    final near = hurried(() => source.relatedTags(server, tag));
    final tags = await counted, wiki = await page, related = await near;
    // Nothing answered: keep what was known and ask again next time.
    if (tags == null && wiki == null && related == null) return kept;
    final found = tags?.$1.where((value) => value.name == tag).firstOrNull;
    // Complete only when everything this kind of server offers was answered, so that a page
    // that timed out once is asked for again instead of staying missing until the cache goes stale.
    final hasPages = server.engine == BooruEngine.danbooru;
    final info = StudyTagInfo(
      name: tag,
      count: found?.count ?? kept?.count,
      category: found?.category ?? kept?.category,
      wiki: wiki?.$1 ?? kept?.wiki,
      related: related?.$1 ?? kept?.related ?? [],
      fetched: DateTime.now(),
      complete: tags != null && (!hasPages || (wiki != null && related != null)),
    );
    try {
      study.save(info, address: address);
    } on Object {
      // The answer is still good for this screen.
    }
    return info;
  }

  /// Post counts for many tags in as few requests as the server allows. Returns every count known afterwards.
  static Future<Map<String, int>> counts(List<String> tags, {required BooruStore store, required BooruProviding source}) async {
    final server = infoServer(store);
    if (server == null) return {};
    final study = store.studyStore, address = server.canonicalAddress;
    Map<String, int> known;
    try {
      known = study.counts(address: address);
    } on Object {
      known = {};
    }
    final missing = tags.where((tag) => known[tag] == null).toList();
    if (missing.isEmpty) return known;
    final found = await hurried(() => source.tags(server, missing), seconds: 12);
    if (found == null) return known;
    // A name the server left out of its answer has no posts there; keeping that saves asking again.
    final answered = {for (final tag in found.$1) tag.name};
    final rows = [
      ...found.$1,
      for (final name in missing)
        if (!answered.contains(name)) BooruTag(name: name, count: 0, category: 0),
    ];
    for (final tag in rows) {
      known[tag.name] = tag.count;
      try {
        final kept = study.info(tag.name, address: address);
        study.save(
          StudyTagInfo(
            name: tag.name,
            count: tag.count,
            category: tag.category,
            wiki: kept?.wiki,
            related: kept?.related ?? [],
            fetched: kept?.fetched ?? DateTime.now(),
            complete: kept?.complete ?? false,
          ),
          address: address,
        );
      } on Object {
        // Counts still reach the screen when the cache cannot be written.
      }
    }
    return known;
  }
}

/// Where a session stands: waiting for pictures, showing a question, showing an answer, or done.
class StudyPhase {
  const StudyPhase._(this.kind, [this.choice]);
  static const loading = StudyPhase._(StudyPhaseKind.loading);
  static const asking = StudyPhase._(StudyPhaseKind.asking);
  static const finished = StudyPhase._(StudyPhaseKind.finished);
  const StudyPhase.answered(int choice) : this._(StudyPhaseKind.answered, choice);
  final StudyPhaseKind kind;

  /// The index chosen, while [kind] is `answered`.
  final int? choice;

  @override
  bool operator ==(Object other) => other is StudyPhase && other.kind == kind && other.choice == choice;
  @override
  int get hashCode => Object.hash(kind, choice);
  @override
  String toString() => choice == null ? 'StudyPhase.${kind.name}' : 'StudyPhase.${kind.name}($choice)';
}

enum StudyPhaseKind { loading, asking, answered, finished }

class StudyResult {
  const StudyResult({required this.tag, required this.right});
  final StudyTag tag;
  final bool right;
  String get id => tag.name;

  @override
  bool operator ==(Object other) => other is StudyResult && other.tag == tag && other.right == right;
  @override
  int get hashCode => Object.hash(tag, right);
}

/// One round of questions: it gathers pictures, asks, records each answer and moves on.
class StudySession extends ChangeNotifier {
  StudySession({
    required this.scope,
    required this.store,
    required this.source,
    StudyEngine? engine,
    this.records = true,
    Random? random,
    DateTime Function()? now,
  }) : engine = engine ?? StudyEngine(),
       _random = random ?? Random(),
       _now = now ?? DateTime.now,
       id = uuidString();

  final String id;
  final StudyScope scope;
  final BooruStore store;
  final BooruProviding source;
  final StudyEngine engine;

  /// Whether answers are written to the progress the store keeps.
  final bool records;

  final Random _random;
  final DateTime Function() _now;
  var _tags = <StudyTag>[];
  var _index = 0;
  StudyQuestion? _question;
  var _phase = StudyPhase.loading;
  final _results = <StudyResult>[];
  var _withoutPictures = false;
  var _pool = <BooruPost>[];
  final _asked = <String>{};
  final _gathering = <String, Future<void>>{};
  final _used = <String>{};
  var _disposed = false;

  List<StudyTag> get tags => List.unmodifiable(_tags);
  int get index => _index;
  StudyQuestion? get question => _question;
  StudyPhase get phase => _phase;
  List<StudyResult> get results => List.unmodifiable(_results);

  /// True when no picture could be read for a question, so it was asked by meaning.
  bool get withoutPictures => _withoutPictures;
  int get rightCount => _results.where((result) => result.right).length;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    if (_tags.isNotEmpty) return;
    var progress = <String, StudyProgress>{};
    try {
      progress = store.studyStore.progress();
    } on Object {
      progress = {};
    }
    _tags = engine.round(scope, progress: progress, now: _now(), random: _random);
    if (_tags.isEmpty) {
      _phase = StudyPhase.finished;
      _changed();
      return;
    }
    await _ask();
  }

  void choose(int choice) {
    final question = _question;
    if (_phase != StudyPhase.asking || question == null) return;
    final right = choice == question.answer;
    _results.add(StudyResult(tag: question.tag, right: right));
    if (records) {
      try {
        store.studyStore.answer(question.tag.name, right: right, now: _now());
      } on Object {
        // An answer that cannot be saved still counts for this round.
      }
    }
    _phase = StudyPhase.answered(choice);
    _changed();
  }

  Future<void> advance() async {
    if (_phase.kind != StudyPhaseKind.answered) return;
    _index += 1;
    if (_index >= _tags.length) {
      _question = null;
      _phase = StudyPhase.finished;
      _changed();
      return;
    }
    await _ask();
  }

  Future<void> _ask() async {
    final tag = _tags[_index];
    _phase = StudyPhase.loading;
    _changed();
    if (_needsPictures(tag)) await _gather(tag);
    // Pictures already shown this round are not shown again while others remain.
    final unused = _pool.where((post) => !_used.contains(post.id)).toList();
    var next = engine.question(tag, pool: unused, random: _random);
    if (next?.kind == StudyQuestionKind.meaningToTag && unused.length != _pool.length) {
      next = engine.question(tag, pool: _pool, random: _random) ?? next;
    }
    if (next != null && next.kind == StudyQuestionKind.meaningToTag && _needsPictures(tag)) _withoutPictures = true;
    if (next != null) _used.addAll(next.posts.map((post) => post.id));
    _question = next;
    _phase = next == null ? StudyPhase.finished : StudyPhase.asking;
    _changed();
    if (_index + 1 < _tags.length) {
      final following = _tags[_index + 1];
      if (_needsPictures(following)) _prepare(following);
    }
  }

  bool _needsPictures(StudyTag tag) {
    if (!(engine.curriculum.groupOf(tag.name)?.visual ?? true) || store.selectedServers.isEmpty) return false;
    return !_pool.any((post) => !_used.contains(post.id) && engine.teaches(post, tag));
  }

  void _prepare(StudyTag tag) {
    if (_gathering.containsKey(tag.name) || _asked.contains(tag.name)) return;
    _gathering[tag.name] = _read(tag);
  }

  Future<void> _gather(StudyTag tag) async {
    final running = _gathering[tag.name];
    if (running != null) {
      await running;
      return;
    }
    if (_asked.contains(tag.name)) return;
    await _read(tag);
  }

  Future<void> _read(StudyTag tag) async {
    _asked.add(tag.name);
    try {
      // A page a little way in keeps the round from always opening on the same newest pictures.
      final page = _random.nextInt(4);
      var found = await StudyLookup.examples(tag.name, store: store, source: source, page: page, random: _random);
      if (!found.any((post) => engine.teaches(post, tag))) {
        found = [...found, ...await StudyLookup.examples(tag.name, store: store, source: source, page: 0, random: _random)];
      }
      final known = {for (final post in _pool) post.id};
      _pool = [..._pool, ...found.where((post) => !known.contains(post.id))];
      if (_pool.length > 600) _pool = _pool.sublist(_pool.length - 600);
    } on Object {
      // A tag that cannot be read for is asked by meaning.
    } finally {
      _gathering.remove(tag.name);
    }
  }
}
