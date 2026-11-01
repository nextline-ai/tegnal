import 'dart:math' as math;

import 'content.dart';
import 'insights.dart';
import 'library.dart';

/// Foreground time on one work. A page left on screen stops counting after
/// [idleLimit], so a reader abandoned on a table cannot report hours of reading.
class ViewingSession {
  static const idleLimit = Duration(seconds: 120);
  static const minimum = Duration(seconds: 3);
  Duration _elapsed = Duration.zero;
  final Set<int> _pages = {};
  bool _finished = false;
  DateTime? _mark;

  Duration _counted(DateTime at) {
    final mark = _mark;
    if (mark == null) return Duration.zero;
    final span = at.difference(mark);
    if (span.isNegative) return Duration.zero;
    return span > idleLimit ? idleLimit : span;
  }

  void resume(DateTime at) => _mark ??= at;
  void pause(DateTime at) {
    _elapsed += _counted(at);
    _mark = null;
  }

  /// Each page restarts the idle window, so steady reading is never truncated.
  void show(int page, {bool isLast = false, required DateTime at}) {
    if (_mark != null) {
      _elapsed += _counted(at);
      _mark = at;
    }
    _pages.add(page);
    if (isLast) _finished = true;
  }

  /// Ends the session. Opening a work and leaving at once is not viewing time.
  RecapDwell? finish(DateTime at) {
    pause(at);
    final result = _elapsed < minimum
        ? null
        : RecapDwell(
            seconds: _elapsed.inSeconds,
            pages: math.max(1, _pages.length),
            finished: _finished,
          );
    _elapsed = Duration.zero;
    _pages.clear();
    _finished = false;
    return result;
  }
}

class RecapDwell {
  const RecapDwell({
    required this.seconds,
    this.pages = 1,
    this.finished = false,
  });
  final int seconds;
  final int pages;
  final bool finished;
  Map<String, dynamic> toJson() => {
    'seconds': seconds,
    'pages': pages,
    'finished': finished,
  };
  factory RecapDwell.fromJson(Map<String, dynamic> json) => RecapDwell(
    seconds: (json['seconds'] as num?)?.toInt() ?? 0,
    pages: (json['pages'] as num?)?.toInt() ?? 1,
    finished: json['finished'] == true,
  );
}

class RecapEvent {
  const RecapEvent({
    required this.kind,
    required this.item,
    required this.at,
    this.dwell,
  });
  final String kind;
  final ContentItem item;
  final DateTime at;
  final RecapDwell? dwell;
}

enum RecapPeriod { week, month, year }

class RecapWork {
  const RecapWork({
    required this.item,
    this.opens = 0,
    this.seconds = 0,
    this.score = 0,
    this.savedAt,
  });
  final ContentItem item;
  final int opens;
  final int seconds;
  final double score;
  final DateTime? savedAt;
  String get key => item.key;
}

class RecapTag {
  RecapTag({required this.name, required this.source});
  final String name;
  String source;
  int count = 0;
  int previousCount = 0;
  int rank = 0;
  int? previousRank;
  bool isNew = false;
  final List<String> works = [];

  /// Positive when the tag climbed; null without a previous rank to compare.
  int? get movement => previousRank == null ? null : previousRank! - rank;
}

class RecapPerson {
  RecapPerson(this.name);
  final String name;
  int count = 0;
  int previousCount = 0;
  final List<String> works = [];
}

enum RecapHighlightKind { comeback, newcomer, rising }

class RecapHighlight {
  const RecapHighlight(this.kind, this.tag);
  final RecapHighlightKind kind;
  final RecapTag tag;
}

/// A localized sentence kept as data so tests assert facts, not one language.
class RecapLine {
  const RecapLine(this.key, [this.arguments = const []]);
  final String key;
  final List<String> arguments;
}

enum RecapRhythm { midnight, dawn, weekend, steady, daylight }

enum RecapStyle { curator, devotee, explorer, collector }

class RecapPersona {
  const RecapPersona(this.rhythm, this.style, this.traits);
  final RecapRhythm rhythm;
  final RecapStyle style;
  final List<RecapLine> traits;
}

class RecapDay {
  RecapDay(this.date);
  final DateTime date;
  int touched = 0;
  int saved = 0;
}

class RecapMonth {
  const RecapMonth(this.start, this.saves);
  final DateTime start;
  final int saves;
}

/// One issue. Only works still visible in the library appear in [saved],
/// so a recap can never resurface something hidden or removed.
class Recap {
  Recap({
    required this.mode,
    required this.period,
    required this.offset,
    required this.start,
    required this.end,
    required this.isComplete,
  });
  final AppMode mode;
  final RecapPeriod period;
  final int offset;
  final DateTime start;
  final DateTime end;
  final bool isComplete;
  bool isSample = false;
  int issue = 1;
  int saves = 0;
  int previousSaves = 0;
  int opens = 0;
  int seconds = 0;
  int pages = 0;
  int finished = 0;
  int activeDays = 0;
  int longestStreak = 0;
  List<RecapTag> tags = const [];
  List<RecapPerson> people = const [];
  List<RecapHighlight> highlights = const [];
  RecapTag? opening;
  RecapTag? closing;
  RecapTag? signature;
  List<RecapDay> days = const [];
  List<int> hours = List.filled(24, 0);
  List<RecapWork> saved = const [];
  RecapWork? revisited;
  List<RecapWork> rediscover = const [];
  List<RecapTag> next = const [];
  List<RecapMonth> months = const [];
  RecapPersona? persona;

  String get id => '${mode.name}:${period.name}:${start.toIso8601String()}';
  bool get hasActivity => saves > 0 || opens > 0;
  RecapWork? get cover => saved.isEmpty ? null : saved.first;
  RecapDay? get busiestDay {
    RecapDay? best;
    for (final day in days) {
      if (day.touched > 0 && (best == null || day.touched > best.touched)) {
        best = day;
      }
    }
    return best;
  }

  int? get peakHour {
    final peak = hours.reduce(math.max);
    return peak == 0 ? null : hours.indexOf(peak);
  }

  RecapWork? work(String key) {
    for (final entry in saved) {
      if (entry.key == key) return entry;
    }
    return null;
  }

  /// The story's opening sentence, drawn only from counted facts.
  RecapLine? get editorNote {
    final first = opening, last = closing;
    if (first != null &&
        last != null &&
        first.name != last.name &&
        saves >= 6) {
      return RecapLine('You began with %@ and ended on %@.', [
        recapTagText(first.name),
        recapTagText(last.name),
      ]);
    }
    final top = signature ?? (tags.isEmpty ? null : tags.first);
    if (top == null) return null;
    if (highlights.isNotEmpty && highlights.first.tag.name != top.name) {
      return RecapLine('%@ held the center, while %@ quietly arrived.', [
        recapTagText(top.name),
        recapTagText(highlights.first.tag.name),
      ]);
    }
    return RecapLine('%@ ran through this issue from start to finish.', [
      recapTagText(top.name),
    ]);
  }
}

/// Namespaces and underscores are search syntax, not something to read.
String recapTagText(String name) =>
    name.substring(name.indexOf(':') + 1).replaceAll('_', ' ');

const _anonymous = {
  'anonymous',
  'unknown',
  'unknown_artist',
  'artist_request',
  'original',
};

class _Entry {
  _Entry(this.event, this.tags);
  final RecapEvent event;
  List<String> tags;
  String get key => event.item.key;
  DateTime get at => event.at;
}

/// Decoded history with every tag decision already made, so many issues can
/// be built from one pass. Pure and deterministic.
class RecapIndex {
  RecapIndex(
    Iterable<RecapEvent> input, {
    required this.mode,
    required InsightPreferences preferences,
    required this.library,
  }) {
    final events = input.where((event) => event.item.mode == mode).toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    final metadata = <String, Set<String>>{};
    for (final event in events) {
      (metadata[event.item.sourceId] ??= {}).addAll(
        TasteTagPolicy.metadata(event.item),
      );
    }
    for (final event in events) {
      final item = event.item;
      final tags = TasteTagPolicy.eligible(
        item,
        preferences,
        knownMetadata: metadata[item.sourceId] ?? const {},
      ).toList()..sort();
      _entries.add(_Entry(event, tags));
      if (event.kind == 'save' ||
          event.kind == 'seed' ||
          event.kind == 'imported') {
        for (final tag in tags) {
          (_tagHistory[tag] ??= []).add(event.at);
        }
        _latest[item.key] = _Entry(event, tags);
      } else if (event.kind == 'remove') {
        _latest.remove(item.key);
      } else if (event.kind == 'open' || event.kind == 'view') {
        _lastOpened[item.key] = event.at;
      }
    }
  }

  final AppMode mode;
  final Map<String, SavedItem> library;
  final List<_Entry> _entries = [];
  final Map<String, List<DateTime>> _tagHistory = {};
  final Map<String, _Entry> _latest = {};
  final Map<String, DateTime> _lastOpened = {};

  static (DateTime, DateTime) interval(
    RecapPeriod period,
    int offset,
    DateTime now,
  ) => switch (period) {
    RecapPeriod.month => (
      DateTime(now.year, now.month + offset),
      DateTime(now.year, now.month + offset + 1),
    ),
    RecapPeriod.year => (
      DateTime(now.year + offset),
      DateTime(now.year + offset + 1),
    ),
    RecapPeriod.week => (
      DateTime(now.year, now.month, now.day - now.weekday + 1 + offset * 7),
      DateTime(now.year, now.month, now.day - now.weekday + 8 + offset * 7),
    ),
  };

  int _firstAtOrAfter(DateTime time) {
    var low = 0, high = _entries.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_entries[middle].at.isBefore(time)) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  int _savedBefore(String tag, DateTime time) =>
      _tagHistory[tag]?.where((at) => at.isBefore(time)).length ?? 0;

  double _signatureScore(RecapTag tag, int total) =>
      tag.count *
      math.log(1 + total / math.max(1, _tagHistory[tag.name]?.length ?? 1));

  Recap recap(
    RecapPeriod period,
    int offset, {
    DateTime? now,
    bool rediscovers = true,
  }) {
    final clock = now ?? DateTime.now();
    final (start, end) = interval(period, offset, clock);
    final (previousStart, _) = interval(period, offset - 1, clock);
    final result = Recap(
      mode: mode,
      period: period,
      offset: offset,
      start: start,
      end: end,
      isComplete: !clock.isBefore(end),
    );
    final chosen = <String, _Entry>{}, earlier = <String, _Entry>{};
    final opened = <String>{};
    final visits = <String, int>{}, viewings = <String, int>{};
    final secondsByWork = <String, int>{};
    final days = <DateTime, RecapDay>{};
    final touched = <DateTime, Set<String>>{};
    final hours = List<int>.filled(24, 0);
    for (
      var index = _firstAtOrAfter(previousStart);
      index < _entries.length;
      index++
    ) {
      final entry = _entries[index], event = entry.event;
      if (!entry.at.isBefore(end)) break;
      if (entry.at.isBefore(start)) {
        if (event.kind == 'save') earlier.putIfAbsent(entry.key, () => entry);
        continue;
      }
      final day = DateTime(entry.at.year, entry.at.month, entry.at.day);
      if (event.kind == 'save') {
        if (!chosen.containsKey(entry.key)) {
          chosen[entry.key] = entry;
          (days[day] ??= RecapDay(day)).saved++;
          (touched[day] ??= {}).add(entry.key);
          hours[entry.at.hour]++;
        }
      } else if (event.kind == 'open') {
        opened.add(entry.key);
        visits.update(entry.key, (value) => value + 1, ifAbsent: () => 1);
        days[day] ??= RecapDay(day);
        (touched[day] ??= {}).add(entry.key);
        hours[entry.at.hour]++;
      } else if (event.kind == 'view' && event.dwell != null) {
        opened.add(entry.key);
        final dwell = event.dwell!;
        result.seconds += dwell.seconds;
        result.pages += dwell.pages;
        if (dwell.finished) result.finished++;
        secondsByWork.update(
          entry.key,
          (value) => value + dwell.seconds,
          ifAbsent: () => dwell.seconds,
        );
        viewings.update(entry.key, (value) => value + 1, ifAbsent: () => 1);
      }
    }
    result.saves = chosen.length;
    result.previousSaves = earlier.length;
    result.opens = opened.length;
    result.hours = hours;
    touched.forEach((day, keys) => days[day]!.touched = keys.length);
    final filled = <RecapDay>[];
    for (
      var day = start;
      day.isBefore(end);
      day = DateTime(day.year, day.month, day.day + 1)
    ) {
      filled.add(days[day] ?? RecapDay(day));
    }
    result.days = filled;
    result.activeDays = days.length;
    var run = 0;
    for (final day in filled) {
      run = day.touched > 0 ? run + 1 : 0;
      result.longestStreak = math.max(result.longestStreak, run);
    }

    final middle = start.add(end.difference(start) ~/ 2);
    final tags = <String, RecapTag>{};
    final sources = <String, Map<String, int>>{};
    final people = <String, RecapPerson>{};
    final firstHalf = <String, int>{}, secondHalf = <String, int>{};
    Iterable<String> artists(ContentItem item) => item.artists
        .map(InsightPreferences.normalize)
        .where((name) => name.isNotEmpty);
    for (final entry in chosen.values) {
      final credited = artists(entry.event.item).toSet();
      for (final name in credited.where((name) => !_anonymous.contains(name))) {
        final person = people[name] ??= RecapPerson(name);
        person.count++;
        person.works.add(entry.key);
      }
      for (final name in entry.tags.where((tag) => !credited.contains(tag))) {
        final source = entry.event.item.sourceId;
        final tag = tags[name] ??= RecapTag(name: name, source: source);
        tag.count++;
        tag.works.add(entry.key);
        final bySource = sources[name] ??= {};
        bySource[source] = (bySource[source] ?? 0) + 1;
        final half = entry.at.isBefore(middle) ? firstHalf : secondHalf;
        half[name] = (half[name] ?? 0) + 1;
      }
    }
    final previousCounts = <String, int>{};
    for (final entry in earlier.values) {
      for (final name in entry.tags) {
        previousCounts[name] = (previousCounts[name] ?? 0) + 1;
      }
      for (final name in artists(entry.event.item)) {
        people[name]?.previousCount++;
      }
    }
    int byCount(MapEntry<String, int> a, MapEntry<String, int> b) {
      final score = b.value.compareTo(a.value);
      return score == 0 ? a.key.compareTo(b.key) : score;
    }

    final previousOrder = previousCounts.entries.toList()..sort(byCount);
    final previousRanks = {
      for (final (index, entry) in previousOrder.indexed) entry.key: index + 1,
    };
    final ranked = tags.values.toList()
      ..sort((a, b) {
        final score = b.count.compareTo(a.count);
        return score == 0 ? a.name.compareTo(b.name) : score;
      });
    for (final (index, tag) in ranked.indexed) {
      tag.rank = index + 1;
      tag.previousRank = previousRanks[tag.name];
      tag.previousCount = previousCounts[tag.name] ?? 0;
      tag.isNew = _savedBefore(tag.name, start) == 0;
      final bySource = sources[tag.name]!.entries.toList()..sort(byCount);
      tag.source = bySource.first.key;
    }
    result.tags = ranked;
    result.people = people.values.toList()
      ..sort((a, b) {
        final score = b.count.compareTo(a.count);
        return score == 0 ? a.name.compareTo(b.name) : score;
      });
    RecapTag? best(Map<String, int> counts) {
      if (counts.isEmpty) return null;
      final order = counts.entries.toList()..sort(byCount);
      return tags[order.first.key];
    }

    result.opening = best(firstHalf);
    result.closing = best(secondHalf);
    final total = math.max(1, _latest.length);
    final candidates = ranked.where(
      (tag) => tag.count >= 2 || ranked.length < 4,
    );
    for (final tag in candidates) {
      if (result.signature == null ||
          _signatureScore(tag, total) >
              _signatureScore(result.signature!, total)) {
        result.signature = tag;
      }
    }
    result.highlights = _highlights(ranked, period, previousStart);

    final counts = {for (final tag in ranked) tag.name: tag.count};
    double score(Iterable<String> names) {
      final list = names.toList();
      return list.fold<int>(0, (sum, name) => sum + (counts[name] ?? 0)) /
          math.max(1, math.sqrt(list.length));
    }

    int order(RecapWork a, RecapWork b) {
      final value = b.score.compareTo(a.score);
      return value == 0 ? a.key.compareTo(b.key) : value;
    }

    RecapWork? work(String key, Iterable<String> names) {
      final saved = library[key];
      if (saved == null) return null;
      return RecapWork(
        item: saved.item,
        opens: math.max(viewings[key] ?? 0, visits[key] ?? 0),
        seconds: secondsByWork[key] ?? 0,
        score: score(names),
        savedAt: saved.savedAt,
      );
    }

    result.saved =
        chosen.values
            .map((entry) => work(entry.key, entry.tags))
            .whereType<RecapWork>()
            .toList()
          ..sort(order);
    RecapWork? revisited;
    for (final key in {
      ...visits.keys,
      ...viewings.keys,
      ...secondsByWork.keys,
    }) {
      final entry = work(key, _latest[key]?.tags ?? const []);
      if (entry == null || entry.opens < 2) continue;
      if (revisited == null ||
          entry.seconds > revisited.seconds ||
          (entry.seconds == revisited.seconds &&
              entry.opens > revisited.opens)) {
        revisited = entry;
      }
    }
    result.revisited = revisited;

    final top = ranked.take(10).map((tag) => tag.name).toSet();
    if (rediscovers && period != RecapPeriod.week && top.isNotEmpty) {
      final settled = start.subtract(const Duration(days: 30));
      final quiet = end.subtract(const Duration(days: 60));
      final found = <RecapWork>[];
      _latest.forEach((key, entry) {
        final saved = library[key];
        final lastOpened = _lastOpened[key];
        if (chosen.containsKey(key) ||
            saved == null ||
            !saved.savedAt.isBefore(settled) ||
            (lastOpened != null && !lastOpened.isBefore(quiet))) {
          return;
        }
        final overlap = entry.tags.where(top.contains);
        if (overlap.isEmpty) return;
        found.add(
          RecapWork(
            item: saved.item,
            score: score(overlap),
            savedAt: saved.savedAt,
          ),
        );
      });
      found.sort(order);
      result.rediscover = found.take(6).toList();
    }
    final seen = <String>{};
    result.next = [
      ...result.highlights.map((highlight) => highlight.tag),
      ...ranked
          .skip(3)
          .where((tag) => tag.isNew || tag.count > tag.previousCount),
      ...ranked.skip(3),
    ].where((tag) => seen.add(tag.name)).take(3).toList();
    result.persona = _persona(result, clock);
    return result;
  }

  /// The chart's leader already has its own page, so it qualifies only when
  /// nothing else does. Ordered by how surprising each pattern is.
  List<RecapHighlight> _highlights(
    List<RecapTag> tags,
    RecapPeriod period,
    DateTime previousStart,
  ) {
    final required = period == RecapPeriod.week ? 2 : 3;
    final found = <RecapHighlight>[];
    for (final tag in tags) {
      if (tag.previousCount == 0 &&
          !tag.isNew &&
          tag.count >= 2 &&
          _savedBefore(tag.name, previousStart) >= 3) {
        found.add(RecapHighlight(RecapHighlightKind.comeback, tag));
      } else if (tag.isNew && tag.count >= required) {
        found.add(RecapHighlight(RecapHighlightKind.newcomer, tag));
      } else if (tag.previousCount > 0 &&
          tag.count >= required &&
          tag.count >= tag.previousCount * 2) {
        found.add(RecapHighlight(RecapHighlightKind.rising, tag));
      }
    }
    found.sort((a, b) {
      final kind = a.kind.index.compareTo(b.kind.index);
      return kind == 0 ? a.tag.rank.compareTo(b.tag.rank) : kind;
    });
    return [
      ...found.where((highlight) => highlight.tag.rank > 1),
      ...found.where((highlight) => highlight.tag.rank == 1),
    ].take(3).toList();
  }

  static RecapPersona? _persona(Recap recap, DateTime now) {
    if (recap.saves + recap.opens < 5) return null;
    int percent(int part, int whole) =>
        whole == 0 ? 0 : (part / whole * 100).round();
    final activity = recap.hours.reduce((a, b) => a + b);
    int sum(int from, int to) =>
        recap.hours.sublist(from, to).fold(0, (a, b) => a + b);
    final night = sum(22, 24) + sum(0, 5), dawn = sum(5, 10);
    final weekend = recap.days
        .where((day) => day.date.weekday >= DateTime.saturday)
        .fold<int>(0, (total, day) => total + day.touched);
    final total = recap.days.fold<int>(0, (sum, day) => sum + day.touched);
    final elapsed = math.max(
      1,
      recap.days.where((day) => !day.date.isAfter(now)).length,
    );
    final traits = <RecapLine>[];
    RecapRhythm rhythm;
    if (percent(night, activity) >= 40) {
      rhythm = RecapRhythm.midnight;
      traits.add(
        RecapLine('%@%% of your activity came after 10 PM', [
          '${percent(night, activity)}',
        ]),
      );
    } else if (percent(dawn, activity) >= 30) {
      rhythm = RecapRhythm.dawn;
      traits.add(
        RecapLine('%@%% of your activity came before 10 AM', [
          '${percent(dawn, activity)}',
        ]),
      );
    } else if (recap.period != RecapPeriod.week &&
        percent(weekend, total) >= 55) {
      rhythm = RecapRhythm.weekend;
      traits.add(
        RecapLine('%@%% of your activity fell on weekends', [
          '${percent(weekend, total)}',
        ]),
      );
    } else if (percent(recap.activeDays, elapsed) >= 50) {
      rhythm = RecapRhythm.steady;
      traits.add(
        RecapLine('Active on %@ of %@ days', [
          '${recap.activeDays}',
          '$elapsed',
        ]),
      );
    } else {
      rhythm = RecapRhythm.daylight;
      traits.add(
        RecapLine('Most active around %@', [recapHour(recap.peakHour ?? 12)]),
      );
    }
    final saveRate = percent(recap.saves, math.max(recap.opens, recap.saves));
    // A tag nearly every work carries says nothing about focus.
    final leaders = recap.tags
        .where((tag) => tag.count * 5 < recap.saves * 4)
        .take(3)
        .expand((tag) => tag.works)
        .toSet();
    final focus = percent(leaders.length, recap.saves);
    final newcomers = recap.tags.where((tag) => tag.isNew).length;
    RecapStyle style;
    if (recap.opens >= 15 && saveRate <= 15) {
      style = RecapStyle.curator;
      traits.add(
        RecapLine('You kept %@ of %@ works you opened', [
          '${recap.saves}',
          '${recap.opens}',
        ]),
      );
    } else if (recap.saves >= 5 && focus >= 70) {
      style = RecapStyle.devotee;
      traits.add(
        RecapLine('Your top 3 tags cover %@%% of your saves', ['$focus']),
      );
    } else if (recap.tags.length >= 8 &&
        percent(newcomers, recap.tags.length) >= 35) {
      style = RecapStyle.explorer;
      traits.add(
        RecapLine('%@ tags were new to your collection', ['$newcomers']),
      );
    } else {
      style = RecapStyle.collector;
      traits.add(
        RecapLine('%@ works joined your collection', ['${recap.saves}']),
      );
    }
    if (recap.longestStreak >= 3) {
      traits.add(
        RecapLine('Longest streak: %@ days', ['${recap.longestStreak}']),
      );
    }
    return RecapPersona(rhythm, style, traits);
  }

  /// Every period with activity, newest first, numbered like a magazine's run.
  List<Recap> issues({DateTime? now, int limit = 36}) {
    final clock = now ?? DateTime.now();
    final first = _entries
        .where(
          (entry) => entry.event.kind == 'save' || entry.event.kind == 'open',
        )
        .firstOrNull;
    if (first == null) return const [];
    final span =
        (clock.year - first.at.year) * 12 + clock.month - first.at.month;
    final result = <Recap>[];
    for (var offset = 0; offset >= -math.max(0, span); offset--) {
      if (result.length >= limit) break;
      // Shelves show many issues. Library matching waits until one is opened.
      final issue = recap(
        RecapPeriod.month,
        offset,
        now: clock,
        rediscovers: false,
      );
      if (issue.hasActivity) result.add(issue);
    }
    for (final (index, issue) in result.indexed) {
      issue.issue = result.length - index;
    }
    return result;
  }

  Recap yearly(int offset, {DateTime? now}) {
    final clock = now ?? DateTime.now();
    final result = recap(RecapPeriod.year, offset, now: clock);
    result.months = List.generate(12, (month) {
      final start = DateTime(result.start.year, month + 1);
      final end = DateTime(result.start.year, month + 2);
      final keys = <String>{};
      for (
        var index = _firstAtOrAfter(start);
        index < _entries.length;
        index++
      ) {
        final entry = _entries[index];
        if (!entry.at.isBefore(end)) break;
        if (entry.event.kind == 'save') keys.add(entry.key);
      }
      return RecapMonth(start, keys.length);
    });
    return result;
  }
}

String recapHour(int hour) {
  final value = hour % 12 == 0 ? 12 : hour % 12;
  return '$value ${hour < 12 ? 'AM' : 'PM'}';
}

/// The story's pages, chosen from what the period actually contains. A page
/// with nothing true to say is left out rather than padded.
enum RecapPage {
  cover,
  numbers,
  chart,
  person,
  palette,
  discovery,
  year,
  rhythm,
  time,
  favorite,
  rediscover,
  persona,
  next;

  static List<RecapPage> pagesFor(Recap recap) {
    if (!recap.hasActivity) return const [RecapPage.cover];
    final weekly = recap.period == RecapPeriod.week;
    return [
      RecapPage.cover,
      RecapPage.numbers,
      if (recap.tags.isNotEmpty) RecapPage.chart,
      if (!weekly && recap.people.isNotEmpty && recap.people.first.count >= 2)
        RecapPage.person,
      if (!weekly && recap.saved.isNotEmpty) RecapPage.palette,
      if (recap.highlights.isNotEmpty) RecapPage.discovery,
      if (recap.months.isNotEmpty) RecapPage.year,
      if (recap.activeDays >= 2) RecapPage.rhythm,
      if (recap.seconds >= 300) RecapPage.time,
      if (recap.revisited != null) RecapPage.favorite,
      if (recap.rediscover.isNotEmpty) RecapPage.rediscover,
      if (recap.persona != null) RecapPage.persona,
      RecapPage.next,
    ];
  }
}

/// A complete issue of invented works, run through the real builder, so the
/// sample shows exactly what a person's own issue will contain.
Recap recapSample(AppMode mode, {DateTime? now}) {
  final clock = now ?? DateTime.now();
  final (start, _) = RecapIndex.interval(RecapPeriod.month, -1, clock);
  final (earlier, _) = RecapIndex.interval(RecapPeriod.month, -2, clock);
  final tags = mode == AppMode.booru
      ? [
          'sky',
          'cloud',
          'scenery',
          'sunset',
          'ocean',
          'rain',
          'forest',
          'night',
          'lantern',
          'umbrella',
          'train',
          'snow',
        ]
      : [
          'tag:slice_of_life',
          'tag:adventure',
          'tag:fantasy',
          'tag:school_life',
          'tag:romance',
          'tag:mystery',
          'tag:travel',
          'tag:cooking',
          'tag:music',
          'tag:sports',
          'tag:seasons',
          'tag:friendship',
        ];
  const artists = ['Mira Sato', 'Noa Lindqvist', 'Hana Okabe', 'Theo Marsh'];
  ContentItem item(int id, List<String> names, String artist) => ContentItem(
    sourceId: 'sample',
    id: id,
    mode: mode,
    title: 'Sample work $id',
    tags: names,
    artists: [artist],
  );
  final events = <RecapEvent>[];
  final library = <String, SavedItem>{};
  for (var index = 0; index < 46; index++) {
    final work = item(index + 1, [
      tags[index % 3],
      tags[3 + index % 4],
      tags[index % 9 == 0 ? 11 : 6 + index % 3],
    ], artists[index % 5 == 0 ? 1 : (index % 3 == 0 ? 2 : 0)]);
    final at = start.add(
      Duration(
        days: index % 26,
        hours: index % 4 == 0 ? 3 : 21,
        seconds: index * 90,
      ),
    );
    events
      ..add(
        RecapEvent(
          kind: 'open',
          item: work,
          at: at.subtract(const Duration(minutes: 2)),
        ),
      )
      ..add(RecapEvent(kind: 'save', item: work, at: at))
      ..add(
        RecapEvent(
          kind: 'view',
          item: work,
          at: at.add(const Duration(seconds: 30)),
          dwell: RecapDwell(
            seconds: 180 + index % 5 * 200,
            pages: 8 + index % 18,
            finished: index % 3 == 0,
          ),
        ),
      );
    if (index == 4) {
      for (var visit = 1; visit <= 4; visit++) {
        events.add(
          RecapEvent(
            kind: 'view',
            item: work,
            at: at.add(Duration(hours: visit * 5)),
            dwell: const RecapDwell(seconds: 300, pages: 20),
          ),
        );
      }
    }
    library[work.key] = SavedItem(item: work, savedAt: at);
  }
  for (var index = 0; index < 18; index++) {
    final work = item(index + 100, [
      tags[index % 5],
      tags[5 + index % 3],
    ], artists[3]);
    events.add(
      RecapEvent(
        kind: 'save',
        item: work,
        at: earlier.add(Duration(days: index)),
      ),
    );
  }
  for (var index = 0; index < 6; index++) {
    final work = item(index + 200, [tags[index % 3]], artists[3]);
    final at = DateTime(2000);
    events.add(RecapEvent(kind: 'seed', item: work, at: at));
    library[work.key] = SavedItem(item: work, savedAt: at);
  }
  final index = RecapIndex(
    events,
    mode: mode,
    preferences: InsightPreferences(mode: mode),
    library: library,
  );
  return index.recap(RecapPeriod.month, -1, now: clock)
    ..isSample = true
    ..issue = 12;
}
