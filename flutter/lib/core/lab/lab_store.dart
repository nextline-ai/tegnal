import 'package:flutter/foundation.dart';

import '../study/study_path.dart';
import '../study/study_store.dart';
import '../support/sql_database.dart';
import 'lab_course.dart';
import 'lab_records.dart';
import 'lab_sheet.dart';

// The lab's progress and its money: one shared store, saved after every change. Ported from `LabStore.swift`.

/// What a card's engraving added, for the reward screen.
/// What settling 2D AI 배우기 paid, by kind, for the treasure chest a lesson opens.
class LabTagPayout {
  const LabTagPayout({this.lesson = 0, this.stars = 0, this.section = 0});
  final int lesson;
  final int stars;
  final int section;
  int get total => lesson + stars + section;

  @override
  bool operator ==(Object other) => other is LabTagPayout && other.lesson == lesson && other.stars == stars && other.section == section;
  @override
  int get hashCode => Object.hash(lesson, stars, section);
  @override
  String toString() => 'LabTagPayout(lesson $lesson, stars $stars, section $section)';
}

class LabEngraving {
  const LabEngraving({
    required this.before,
    required this.after,
    required this.cardReward,
    required this.failReward,
    required this.failsHung,
    required this.failsLeft,
    required this.first,
    this.season,
    this.seasonReward = 0,
  });
  final int before;
  final int after;
  final int cardReward;
  final int failReward;
  final int failsHung;
  final int failsLeft;
  final bool first;

  /// The number of the season this card finished, the first time it was finished.
  final int? season;

  /// What finishing that season paid.
  final int seasonReward;
  int get total => cardReward + failReward + seasonReward;
}

enum LabCardStatus { earned, open, locked }

/// The outcome of buying, or of asking whether something can be bought. [short] is how much is missing.
class LabBuyResult {
  static const bought = LabBuyResult._('bought');
  static const owned = LabBuyResult._('owned');
  static const unavailable = LabBuyResult._('unavailable');
  const LabBuyResult.shortBy(int amount) : this._('short', amount);

  /// Another item, by id, must be owned first.
  const LabBuyResult.needs(String item) : kind = 'needs', short = 0, needed = item;
  const LabBuyResult._(this.kind, [this.short = 0]) : needed = null;
  final String kind;
  final int short;
  final String? needed;
  bool get isBought => kind == 'bought';

  @override
  bool operator ==(Object other) => other is LabBuyResult && other.kind == kind && other.short == short && other.needed == needed;
  @override
  int get hashCode => Object.hash(kind, short, needed);
}

class LabStore extends ChangeNotifier {
  LabStore({LabCourse? course, LabShop? shop, LabDiagnosis? diagnosis, LabRecordStore? records, LabEdition? edition, bool useBundledDiagnosis = true})
    // The bundled course, shop and sheet are read when the app starts; a store made before then still sees them.
    // ignore: prefer_initializing_formals
    : _course = course,
      // ignore: prefer_initializing_formals
      _shop = shop,
      _diagnosis = diagnosis,
      _useBundledDiagnosis = useBundledDiagnosis && diagnosis == null,
      _records = records ?? LabMemoryRecords(),
      // ignore: prefer_initializing_formals
      _edition = edition {
    progress = _read();
  }

  /// The app-wide store.
  static final LabStore shared = LabStore();
  static const tagCourse = 'course.tags';

  /// Seconds since 1970, to the whole second, so times read back from the database exactly as written.
  static double get now => (DateTime.now().millisecondsSinceEpoch / 1000).roundToDouble();

  /// `TEGNAL_LAB`: test arguments, comma separated (`reset`, `seed=<episode>`, `fails=<n>`, `greeted`, `income=<n>`, `owned`),
  /// the iOS `--lab-…` launch arguments.
  static const _arguments = String.fromEnvironment('TEGNAL_LAB');

  final LabCourse? _course;
  final LabShop? _shop;
  final LabDiagnosis? _diagnosis;
  final bool _useBundledDiagnosis;

  /// The bundled AI lab: what pays, and what the cheat sheet and diagnosis belong to.
  LabCourse get main => _course ?? LabCourse.bundled;

  /// The deck course on screen: the AI lab, or one the learner imported. Null for the AI lab.
  LabCourse? _shown;
  LabCourse get course => _shown ?? main;

  /// Shows another deck course. Its cards, 망작 and rate are read from now on; the money stays the AI lab's.
  void showCourse(LabCourse course) {
    final next = course.imported ? course : null;
    if (identical(next, _shown)) return;
    _shown = next;
    notifyListeners();
  }

  /// Where a card or 망작 of the course on screen is recorded. The AI lab keeps its plain ids, as it always has; an imported
  /// course's are put under its id, so two courses never meet.
  String key(String id) => keyIn(id, course);
  static String keyIn(String id, LabCourse course) => course.imported ? '${course.id}/$id' : id;
  LabShop get shop => _shop ?? LabShop.bundled;
  LabDiagnosis? get diagnosis => _diagnosis ?? (_useBundledDiagnosis ? LabDiagnosis.bundled : null);

  LabRecordStore _records;
  late LabProgress progress;

  /// The cheat-sheet edition shown: the newest of the bundled, saved and downloaded copies.
  LabEdition? _edition;
  LabEdition? get edition => _edition ?? LabEdition.bundled;

  LabProgress _read() {
    try {
      return LabProgress.fromRecords(_records.all());
    } on Object {
      return LabProgress();
    }
  }

  /// Reads the records from the image database. Called when the app starts, before anything asks what is owned.
  void attach(SqlDatabase database) {
    _records = LabDatabaseRecords(database);
    reload();
    if (_arguments.isNotEmpty) _applyTestArguments(_arguments.split(',').map((name) => name.trim()).toList());
  }

  /// Reads the records again, as after a sync or a restored backup.
  void reload() {
    final next = _read();
    if (next != progress) {
      progress = next;
      notifyListeners();
    }
  }

  void _save() {
    try {
      _records.replace(progress.records);
    } on Object catch (error) {
      debugPrint('LabStore: records could not be saved: $error');
    }
    notifyListeners();
  }

  // MARK: Cards

  bool earned(LabEpisode episode) => progress.cards.containsKey(key(episode.id));

  /// A season opens once the season it waits for is finished.
  bool seasonOpened(LabSeason season) {
    final after = season.opensAfter;
    if (after == null) return true;
    final previous = course.seasons.where((value) => value.number == after).firstOrNull;
    return previous == null || complete(previous);
  }

  bool complete(LabSeason season) => season.episodes.every((id) => progress.cards.containsKey(key(id)));

  LabCardStatus state(LabEpisode episode) {
    if (earned(episode)) return LabCardStatus.earned;
    final season = course.seasonOf(episode);
    if (season == null || !seasonOpened(season)) return LabCardStatus.locked;
    if (season.free) return LabCardStatus.open;
    // In a fixed season only the first card not yet engraved is open.
    final first = season.episodes.where((id) => !progress.cards.containsKey(key(id))).firstOrNull;
    return first == episode.id ? LabCardStatus.open : LabCardStatus.locked;
  }

  /// The card the deck offers next: the first open one in deck order.
  LabEpisode? get next => course.episodes.where((episode) => state(episode) == LabCardStatus.open).firstOrNull;
  List<LabEpisode> get earnedCards => course.episodes.where(earned).toList();

  /// The ids of the course's engraved episodes, as the deck tracks them.
  Set<String> get earnedIDs => {for (final episode in earnedCards) episode.id};

  /// When a card of the course on screen was engraved.
  double? engraved(LabEpisode episode) => progress.cards[key(episode.id)];

  /// Card No. 000 and the welcome check belong to the AI lab.
  bool get offersDiagnosis => !course.imported && diagnosis != null;
  List<LabEpisode> get openCards => course.episodes.where((episode) => state(episode) == LabCardStatus.open).toList();

  /// The course's rate (the AI lab's AI 성능 인출률): the base plus every engraved card's share. It never goes down.
  int get rate => course.base + earnedCards.fold(0, (total, episode) => total + episode.impact);

  /// Engraves an episode's card. Playing an engraved card again changes nothing but its fails.
  LabEngraving engrave(LabEpisode episode, {required int failsHung}) {
    final before = rate;
    final first = !progress.cards.containsKey(key(episode.id));
    final pays = !course.imported;
    if (first) {
      progress.cards[key(episode.id)] = now;
      if (pays) progress.cardGems[key(episode.id)] = episode.reward;
      _save();
    }
    final left = episode.fails.where((fail) => !progress.fails.containsKey(key(fail.id))).length;
    final season = course.seasonOf(episode);
    final finished = first && season != null && complete(season) ? season.number : null;
    var seasonReward = 0;
    if (finished != null && pays && course.info.rewards.season > 0 && !progress.seasonGems.containsKey('$finished')) {
      seasonReward = course.info.rewards.season;
      progress.seasonGems['$finished'] = seasonReward;
      _save();
    }
    return LabEngraving(
      season: finished,
      seasonReward: seasonReward,
      before: before,
      after: rate,
      cardReward: first && pays ? episode.reward : 0,
      failReward: pays ? failsHung * course.info.rewards.fail : 0,
      failsHung: failsHung,
      failsLeft: left,
      first: first,
    );
  }

  // MARK: 망작

  bool hung(LabFail fail) => progress.fails.containsKey(key(fail.id));

  /// What hanging one 망작 pays in the course on screen: nothing in an imported course.
  int get failReward => course.imported ? 0 : course.info.rewards.fail;

  /// Hangs a 망작 in the gallery. True the first time, when it also pays.
  bool hang(LabFail fail) {
    if (progress.fails.containsKey(key(fail.id))) return false;
    progress.fails[key(fail.id)] = now;
    if (failReward > 0) progress.failGems[key(fail.id)] = failReward;
    _save();
    return true;
  }

  /// The gallery number of a 망작: its place among every trap of the course, from 1.
  int number(LabFail fail) {
    final index = course.fails.indexWhere((value) => value.id == fail.id);
    return (index < 0 ? 0 : index) + 1;
  }

  // MARK: Cheat sheet

  /// Whether a section of the sheet is open: the AI lab card it waits for has been engraved.
  bool sectionOpened(LabSheetSection section) => section.opens == null || progress.cards.containsKey(section.opens);

  /// True when an edition newer than the last one looked at is waiting, and the learner can read part of it.
  bool get editionWaiting {
    final edition = this.edition;
    if (edition == null || !edition.sections.any(sectionOpened)) return false;
    return progress.seenEdition != edition.id;
  }

  /// Marks the shown edition as looked at. Reading an edition for the first time pays once, when a section is open.
  int read() {
    final edition = this.edition;
    if (edition == null || !edition.sections.any(sectionOpened)) return 0;
    if (progress.seenEdition == edition.id && progress.editions.containsKey(edition.id)) return 0;
    progress.seenEdition = edition.id;
    var paid = 0;
    if (!progress.editions.containsKey(edition.id)) {
      paid = edition.reward ?? main.info.rewards.edition;
      progress.editions[edition.id] = paid;
    }
    _save();
    return paid;
  }

  void show(LabEdition edition) {
    final current = this.edition;
    if (current != null && current.date.compareTo(edition.date) > 0) return;
    _edition = edition;
    notifyListeners();
  }

  // MARK: 보석

  /// What has been earned, each at the amount it paid when earned: the AI lab's cards, 망작 and seasons, cheat-sheet editions,
  /// and 2D AI 배우기's lessons, three-star lessons and sections. Imported courses pay nothing.
  int get income {
    final cards = main.episodes
        .where((episode) => progress.cards.containsKey(episode.id))
        .fold(0, (total, episode) => total + (progress.cardGems[episode.id] ?? episode.reward));
    final fails = main.fails
        .where((fail) => progress.fails.containsKey(fail.id))
        .fold(0, (total, fail) => total + (progress.failGems[fail.id] ?? main.info.rewards.fail));
    final seasons = main.seasons
        .where((season) => season.episodes.every(progress.cards.containsKey))
        .fold(0, (total, season) => total + (progress.seasonGems['${season.number}'] ?? main.info.rewards.season));
    final editions = progress.editions.values.fold(0, (total, value) => total + value);
    final courses = progress.coursePaid.values.fold(0, (total, value) => total + value);
    return cards + fails + seasons + editions + courses;
  }

  int get spent => progress.purchases.values.fold(0, (total, purchase) => total + purchase.price * purchase.count);
  int get balance => income - spent;

  bool owns(String id) => (progress.purchases[id]?.count ?? 0) > 0;
  bool get ownsTagCourse => owns(tagCourse);

  LabBuyResult canBuy(LabShopItem item) {
    final price = item.price;
    if (item.isSoon || price == null) return LabBuyResult.unavailable;
    if (owns(item.id) && !item.isRepeat) return LabBuyResult.owned;
    final needed = item.requires;
    if (needed != null && !owns(needed)) return LabBuyResult.needs(needed);
    return balance >= price ? LabBuyResult.bought : LabBuyResult.shortBy(price - balance);
  }

  LabBuyResult buy(LabShopItem item) {
    final result = canBuy(item);
    final price = item.price;
    if (!result.isBought || price == null) return result;
    final entry = progress.purchases[item.id] ?? LabPurchase(price: price, count: 0, date: now);
    progress.purchases[item.id] = entry.copyWith(count: entry.count + 1, date: now);
    _save();
    return LabBuyResult.bought;
  }

  // MARK: 2D AI 배우기

  /// Pays what 2D AI 배우기's finished lessons, three-star lessons and finished sections have not paid yet, and returns the
  /// 보석 paid now. Progress from before the course was sold pays the same way, once; the course must still be bought to go on.
  /// Lessons of imported courses (`course:<id>:…`) are not on the bundled path, so they pay nothing.
  LabTagPayout settleTagCourse(StudyStore study, {StudyPath? path}) {
    Map<String, StudyLessonRecord> records;
    try {
      records = study.lessons();
    } on Object {
      return const LabTagPayout();
    }
    final rates = main.info.rewards;
    var lesson = 0, stars = 0, section = 0;
    void pay(String kind, String id, int amount) {
      final key = '$kind:$tagCourse/$id';
      if (amount <= 0 || progress.coursePaid.containsKey(key)) return;
      progress.coursePaid[key] = amount;
      switch (kind) {
        case 'lesson':
          lesson += amount;
        case 'stars':
          stars += amount;
        default:
          section += amount;
      }
    }

    for (final section in (path ?? StudyPath.bundled).sections) {
      for (final lesson in section.lessons) {
        final record = records[lesson.id];
        if (record == null) continue;
        pay('lesson', lesson.id, rates.courseLesson);
        if (record.stars >= 3) pay('stars', lesson.id, rates.courseStars);
      }
      if (section.lessons.isNotEmpty && section.lessons.every((lesson) => records.containsKey(lesson.id))) {
        pay('section', section.id, rates.courseSection);
      }
    }
    final paid = LabTagPayout(lesson: lesson, stars: stars, section: section);
    if (paid.total > 0) _save();
    return paid;
  }

  /// What 2D AI 배우기 has paid so far, and for how many lessons.
  ({int gems, int lessons}) get tagCoursePaid {
    final prefix = ':$tagCourse/';
    final entries = progress.coursePaid.entries.where((entry) => entry.key.contains(prefix));
    return (gems: entries.fold(0, (total, entry) => total + entry.value), lessons: entries.where((entry) => entry.key.startsWith('lesson:')).length);
  }

  /// True when a learner who studied 2D AI 배우기 before it was sold should be told it now opens from the shop.
  bool get owesLegacyNotice => !progress.legacyNoticed && !ownsTagCourse && tagCoursePaid.gems > 0;

  void noticeLegacy() {
    if (progress.legacyNoticed) return;
    progress.legacyNoticed = true;
    _save();
  }

  // MARK: Diagnosis

  LabType? get type => diagnosis?.type(progress.type);

  void diagnose(LabType type) {
    progress
      ..type = type.id
      ..diagnosed = now
      ..greeted = true;
    _save();
  }

  void greeted() {
    if (progress.greeted) return;
    progress.greeted = true;
    _save();
  }

  /// Starts learning mode's records over: every course's cards, the gallery, money and purchases.
  void reset() {
    progress = LabProgress();
    _save();
  }

  void _applyTestArguments(List<String> arguments) {
    String? value(String name) =>
        arguments.where((argument) => argument.startsWith('$name=')).map((argument) => argument.substring(name.length + 1)).firstOrNull;
    if (arguments.contains('reset')) progress = LabProgress();
    final seed = value('seed');
    if (seed != null) {
      for (final episode in main.episodes.takeWhile((episode) => episode.id != seed)) {
        progress.cards.putIfAbsent(episode.id, () => now);
      }
    }
    final fails = int.tryParse(value('fails') ?? '');
    if (fails != null) {
      for (final fail in main.fails.take(fails)) {
        progress.fails.putIfAbsent(fail.id, () => now);
      }
    }
    if (arguments.contains('greeted') || seed != null) {
      progress
        ..greeted = true
        ..legacyNoticed = true;
    }
    final income = int.tryParse(value('income') ?? '');
    if (income != null) progress.editions['test-income'] = income;
    if (arguments.contains('owned')) {
      progress.purchases.putIfAbsent(tagCourse, () => LabPurchase(price: 0, count: 1, date: now));
      progress.legacyNoticed = true;
    }
    _save();
  }
}
