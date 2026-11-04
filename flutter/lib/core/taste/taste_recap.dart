import 'dart:math' as math;

import '../content/manga_urls.dart';
import '../support/l10n.dart';
import '../support/swift_json.dart';
import 'taste_models.dart';

/// Library facts that analysis events do not carry. Only works the library still
/// shows are present, so a recap can never resurface something hidden or blacklisted.
class RecapWorkInfo {
  const RecapWorkInfo({this.title, this.artists = const [], this.series = const [], this.characters = const [], this.savedAt, this.thumbPath});
  final String? title;
  final List<String> artists;
  final List<String> series;
  final List<String> characters;
  final DateTime? savedAt;
  final String? thumbPath;
}

class RecapWork {
  RecapWork({required this.item, required this.info, this.opens = 0, this.seconds = 0, this.score = 0});
  TasteItem item;
  RecapWorkInfo info;
  int opens;
  double seconds;
  double score;
  String get id => item.key;
}

class RecapTag {
  RecapTag({
    required this.name,
    required this.source,
    required this.count,
    this.previousCount = 0,
    this.rank = 0,
    this.previousRank,
    this.isNew = false,
    this.confirmed = 0,
    this.hidden = 0,
    Set<String>? sessions,
    List<String>? works,
  }) : sessions = sessions ?? {},
       works = works ?? [];

  String name;
  String source;
  int count;
  int previousCount;
  int rank;
  int? previousRank;
  bool isNew;
  int confirmed;
  int hidden;
  Set<String> sessions;
  List<String> works;
  String get id => name;

  /// Positive when the tag climbed. Null when it has no previous rank to compare.
  int? get movement => previousRank == null ? null : previousRank! - rank;
}

enum RecapRole { artist, series, character }

class RecapPerson {
  RecapPerson({required this.name, required this.role, required this.count, this.previousCount = 0, List<String>? works}) : works = works ?? [];
  String name;
  RecapRole role;
  int count;
  int previousCount;
  List<String> works;
  String get id => '${role.name}:$name';
}

enum RecapHighlightKind { hidden, comeback, newcomer, rising }

class RecapHighlight {
  const RecapHighlight({required this.kind, required this.tag});
  final RecapHighlightKind kind;
  final RecapTag tag;
}

/// A localized sentence kept as data so tests assert facts, not one language.
class RecapLine {
  RecapLine(this.key, [this.arguments = const []]);
  final String key;
  final List<String> arguments;
  String get text => L10n.text(key, arguments);

  @override
  bool operator ==(Object other) => other is RecapLine && other.key == key && other.arguments.join('\u0000') == arguments.join('\u0000');
  @override
  int get hashCode => Object.hash(key, arguments.join('\u0000'));
  @override
  String toString() => 'RecapLine($key, $arguments)';
}

enum RecapRhythm { midnight, dawn, weekend, steady, daylight }

enum RecapStyle { curator, hunter, devotee, explorer, wanderer, collector }

class RecapPersona {
  const RecapPersona({required this.rhythm, required this.style, required this.traits});
  final RecapRhythm rhythm;
  final RecapStyle style;
  final List<RecapLine> traits;
  String get title => L10n.text('%@ %@', [L10n.text('persona.rhythm.${rhythm.name}'), L10n.text('persona.style.${style.name}')]);
  String get summary => L10n.text('persona.summary.${style.name}');
}

class RecapDay {
  RecapDay(this.date, {this.touched = 0, this.saved = 0});
  final DateTime date;
  int touched;
  int saved;
}

class RecapOrigins {
  int search = 0, feed = 0, recommendation = 0, other = 0;
  int get total => search + feed + recommendation + other;
}

class TasteRecapMonth {
  const TasteRecapMonth({required this.start, required this.saves, this.topTag});
  final DateTime start;
  final int saves;
  final String? topTag;
}

class TasteRecap {
  TasteRecap({
    required this.mode,
    required this.period,
    required this.offset,
    required this.interval,
    required this.isComplete,
    this.isSample = false,
    this.issue = 1,
  });

  TasteMode mode;
  TastePeriod period;
  int offset;
  TasteInterval interval;
  bool isComplete;
  bool isSample;
  int issue;

  int saves = 0;
  int previousSaves = 0;
  int opens = 0;
  int previousOpens = 0;
  int searches = 0;
  double seconds = 0;
  int pages = 0;
  int finished = 0;
  int activeDays = 0;
  int longestStreak = 0;

  List<RecapTag> tags = [];
  List<RecapPerson> people = [];
  List<RecapHighlight> highlights = [];
  RecapTag? opening;
  RecapTag? closing;

  /// What set this period apart. A tag on nearly every work can lead the chart for
  /// months without saying anything, so this weighs presence against rarity.
  RecapTag? signature;
  List<RecapDay> days = [];
  List<int> hours = List.filled(24, 0);
  RecapOrigins origins = RecapOrigins();
  List<RecapWork> saved = [];
  RecapWork? revisited;
  List<RecapWork> rediscover = [];
  List<RecapTag> next = [];
  List<TasteRecapMonth> months = [];
  RecapPersona? persona;

  String get id => '${mode.name}:${period.name}:${interval.startSeconds.floor()}';
  bool get hasActivity => saves > 0 || opens > 0;
  RecapWork? get cover => saved.firstOrNull;
  RecapDay? get busiestDay {
    RecapDay? best;
    for (final day in days.where((day) => day.touched > 0)) {
      if (best == null || day.touched > best.touched || (day.touched == best.touched && day.date.isBefore(best.date))) best = day;
    }
    return best;
  }

  int? get peakHour {
    final peak = hours.reduce(math.max);
    return peak > 0 ? hours.indexOf(peak) : null;
  }

  RecapPerson? person(RecapRole role) => people.where((person) => person.role == role).firstOrNull;
  RecapWork? work(String key) => saved.where((work) => work.id == key).firstOrNull;

  /// The story's opening sentence, drawn only from counted facts.
  RecapLine? get editorNote {
    if (opening != null && closing != null && opening!.name != closing!.name && saves >= 6) {
      return RecapLine('You began with %@ and ended on %@.', [RecapText.tag(opening!.name), RecapText.tag(closing!.name)]);
    }
    final top = signature ?? tags.firstOrNull;
    if (top == null) return null;
    final highlight = highlights.firstOrNull;
    if (highlight != null && highlight.tag.name != top.name) {
      return RecapLine('%@ held the center, while %@ quietly arrived.', [RecapText.tag(top.name), RecapText.tag(highlight.tag.name)]);
    }
    return RecapLine('%@ ran through this issue from start to finish.', [RecapText.tag(top.name)]);
  }
}

abstract final class RecapText {
  /// Namespaces and underscores are search syntax, not something to read.
  static String tag(String name) {
    final colon = name.indexOf(':');
    return (colon >= 0 ? name.substring(colon + 1) : name).replaceAll('_', ' ');
  }

  /// `String.capitalized`: the first letter of each word upper-cased.
  static String capitalized(String text) =>
      text.split(' ').map((word) => word.isEmpty ? word : word[0].toUpperCase() + word.substring(1).toLowerCase()).join(' ');

  static String duration(double seconds) {
    final minutes = (seconds / 60).round();
    if (minutes >= 60) {
      return minutes % 60 == 0 ? L10n.text('%@ hr', ['${minutes ~/ 60}']) : L10n.text('%@ hr %@ min', ['${minutes ~/ 60}', '${minutes % 60}']);
    }
    return L10n.text('%@ min', ['${math.max(1, minutes)}']);
  }
}

abstract final class RecapPersonaClock {
  static String hour(int hour) => L10n.text(hour < 12 ? '%@ AM' : '%@ PM', ['${hour % 12 == 0 ? 12 : hour % 12}']);
}

/// `RecapFormat`: titles and labels in the app language. Dart has no localized date
/// templates without a package, so the three app languages are spelled out.
abstract final class RecapFormat {
  static const _englishMonths = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

  static String _month(DateTime date, {bool short = false}) => switch (L10n.language) {
    'ko' => '${date.month}월',
    'ja' => '${date.month}月',
    _ => short ? _englishMonths[date.month - 1].substring(0, 3) : _englishMonths[date.month - 1],
  };

  static String day(DateTime date) => switch (L10n.language) {
    'ko' => '${date.month}월 ${date.day}일',
    'ja' => '${date.month}月${date.day}日',
    _ => '${_month(date, short: true)} ${date.day}',
  };

  static String month(DateTime date) => _month(date, short: true);

  static String title(TasteRecap recap) {
    final calendar = TasteCalendar(TasteControl.currentTimeZone);
    final start = calendar.local(recap.interval.start);
    switch (recap.period) {
      case TastePeriod.month:
        return switch (L10n.language) {
          'ko' => '${start.year}년 ${start.month}월',
          'ja' => '${start.year}年${start.month}月',
          _ => '${_month(start)} ${start.year}',
        };
      case TastePeriod.year:
        return switch (L10n.language) {
          'ko' => '${start.year}년',
          'ja' => '${start.year}年',
          _ => '${start.year}',
        };
      default:
        return '${day(start)} – ${day(calendar.local(recap.interval.end.subtract(const Duration(seconds: 1))))}';
    }
  }

  static String signed(int value) => '${value > 0 ? '+' : ''}${_grouped(value)}';
  static String modeName(TasteMode mode) => L10n.text(mode == TasteMode.booru ? 'Images' : 'Comics');
  static String _grouped(int value) => '$value'.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
}

class RecapIndexEntry {
  RecapIndexEntry({
    required this.at,
    required this.kind,
    required this.key,
    required this.item,
    required this.tags,
    required this.context,
    this.dwell,
    this.signal,
  });
  final double at;
  final TasteEventKind kind;
  final String key;
  final TasteItem item;
  final List<String> tags;
  final DiscoveryContext context;
  final TasteDwell? dwell;
  final String? signal;
}

/// Decoded history with every tag decision already made, so that many issues can be
/// built from one pass. Pure and deterministic: tests feed it events and a library.
class RecapIndex {
  RecapIndex({required List<TasteEvent> events, required TasteControl control, required this.mode, required this.library})
    : timeZone = control.timeZone,
      calendar = TasteCalendar(control.timeZone) {
    final byID = <String, TasteEvent>{};
    for (final event in events) {
      if (event.epoch != control.epoch) continue;
      final existing = byID[event.id];
      byID[event.id] = existing == null || TasteEvent.ordered(existing, event) ? event : existing;
    }
    final ordered = byID.values.toList()..sort(TasteEvent.compare);
    final metadata = <String, Set<String>>{};
    for (final event in ordered) {
      metadata.putIfAbsent(event.item.source, () => {}).addAll(event.item.metadata.map(TasteTagPolicy.normalize));
    }
    List<String> eligible(TasteItem item) {
      final blocked = metadata[item.source] ?? const <String>{};
      return item.tags
          .map(TasteTagPolicy.normalize)
          .toSet()
          .where((tag) => TasteTagPolicy.eligible(tag, metadata: blocked) && control.allows(tag, source: item.source, mode: mode))
          .toList()
        ..sort();
    }

    final resolved = <String, (TasteItem, List<String>)>{};
    for (final event in ordered) {
      if (const {TasteEventKind.save, TasteEventKind.seed, TasteEventKind.imported, TasteEventKind.metadata}.contains(event.kind) && event.item.id != 0) {
        resolved[event.item.key] = (event.item, eligible(event.item));
      }
    }
    for (final event in ordered) {
      final known = resolved[event.item.key];
      final tags = event.kind == TasteEventKind.search ? eligible(event.item) : known?.$2 ?? eligible(event.item);
      final item = known?.$1 ?? event.item;
      if (event.kind == TasteEventKind.search && event.context.origin == DiscoveryOrigin.search) {
        for (final tag in tags) {
          final key = TasteControl.tagKey(source: item.source, tag: tag);
          searched[key] = math.min(searched[key] ?? double.infinity, event.at);
        }
      }
      if (const {TasteEventKind.save, TasteEventKind.seed, TasteEventKind.imported}.contains(event.kind)) {
        for (final tag in tags) {
          tagHistory.putIfAbsent(tag, () => []).add(event.at);
        }
        latest[item.key] = (item, tags);
      } else if (event.kind == TasteEventKind.remove) {
        latest.remove(item.key);
      }
      if (event.kind == TasteEventKind.open && event.signal == null) lastOpened[item.key] = math.max(lastOpened[item.key] ?? 0, event.at);
      entries.add(
        RecapIndexEntry(
          at: event.at,
          kind: event.kind,
          key: item.key,
          item: item,
          tags: tags,
          context: event.context,
          dwell: event.dwell,
          signal: event.signal,
        ),
      );
    }
  }

  final TasteMode mode;
  final String timeZone;
  final TasteCalendar calendar;
  final Map<String, RecapWorkInfo> library;
  final entries = <RecapIndexEntry>[];
  final tagHistory = <String, List<double>>{};
  final searched = <String, double>{};
  final latest = <String, (TasteItem, List<String>)>{};
  final lastOpened = <String, double>{};

  int _firstEntry(double time) {
    var low = 0, high = entries.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (entries[middle].at < time) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  int _savedCount(String tag, double time) {
    final times = tagHistory[tag];
    if (times == null) return 0;
    var low = 0, high = times.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (times[middle] < time) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  static const _anonymous = {'anonymous', 'unknown', 'unknown_artist', 'artist_request', 'original'};

  static List<(String, RecapRole)> _people(RecapWorkInfo info) => [
    for (final name in info.artists) (name, RecapRole.artist),
    for (final name in info.series) (name, RecapRole.series),
    for (final name in info.characters) (name, RecapRole.character),
  ];

  TasteRecap? recap({required TastePeriod period, required int offset, DateTime? now, bool rediscovers = true}) {
    final clock = now ?? DateTime.now();
    final interval = period.interval(offset: offset, now: clock, timeZone: timeZone);
    final previous = period.interval(offset: offset - 1, now: clock, timeZone: timeZone);
    if (interval == null || previous == null) return null;
    final result = TasteRecap(mode: mode, period: period, offset: offset, interval: interval, isComplete: !clock.isBefore(interval.end));
    final start = interval.startSeconds, end = interval.endSeconds;
    final previousStart = previous.startSeconds, middle = (start + end) / 2;

    final chosen = <String, RecapIndexEntry>{}, earlier = <String, RecapIndexEntry>{};
    final opened = <String>{}, openedEarlier = <String>{};
    final sessionsByWork = <String, Set<String>>{}, viewingsByWork = <String, int>{}, secondsByWork = <String, double>{};
    final searchSessions = <String>{};
    final days = <DateTime, RecapDay>{};
    final touched = <DateTime, Set<String>>{};
    for (var index = _firstEntry(previousStart); index < entries.length; index++) {
      final entry = entries[index];
      if (entry.at >= end) break;
      // Feedback on a recommendation is not activity with the work.
      if (entry.signal != null) continue;
      if (entry.at < start) {
        if (entry.kind == TasteEventKind.save) earlier.putIfAbsent(entry.key, () => entry);
        if (entry.kind == TasteEventKind.open) openedEarlier.add(entry.key);
        continue;
      }
      final moment = calendar.fromSeconds(entry.at), day = calendar.startOfDay(moment);
      switch (entry.kind) {
        case TasteEventKind.save:
          if (chosen[entry.key] == null) {
            chosen[entry.key] = entry;
            (days[day] ??= RecapDay(day)).saved += 1;
            (touched[day] ??= {}).add(entry.key);
            result.hours[calendar.hour(moment)] += 1;
          }
        case TasteEventKind.open:
          opened.add(entry.key);
          final dwell = entry.dwell;
          if (dwell != null) {
            result.seconds += dwell.seconds;
            result.pages += dwell.pages;
            if (dwell.finished) result.finished += 1;
            secondsByWork[entry.key] = (secondsByWork[entry.key] ?? 0) + dwell.seconds;
            viewingsByWork[entry.key] = (viewingsByWork[entry.key] ?? 0) + 1;
          } else {
            (sessionsByWork[entry.key] ??= {}).add(entry.context.session);
            (touched[day] ??= {}).add(entry.key);
            result.hours[calendar.hour(moment)] += 1;
          }
        case TasteEventKind.search:
          if (entry.context.origin == DiscoveryOrigin.search) searchSessions.add(entry.context.session);
        default:
          break;
      }
    }
    result
      ..saves = chosen.length
      ..previousSaves = earlier.length
      ..opens = opened.length
      ..previousOpens = openedEarlier.length
      ..searches = searchSessions.length;
    for (final MapEntry(key: day, value: keys) in touched.entries) {
      (days[day] ??= RecapDay(day)).touched = keys.length;
    }
    result
      ..days = _fill(days, interval)
      ..activeDays = days.length;
    result.longestStreak = _longestRun(result.days);

    String spoken(String name) => TasteTagPolicy.normalize(name);
    final tags = <String, RecapTag>{}, sources = <String, Map<String, int>>{}, personal = <String, RecapPerson>{};
    final firstHalf = <String, int>{}, secondHalf = <String, int>{};
    for (final entry in chosen.values) {
      final info = library[entry.key] ?? const RecapWorkInfo();
      final credited = _people(info).map((person) => spoken(person.$1)).toSet();
      for (final (name, role) in _people(info)) {
        if (_anonymous.contains(spoken(name))) continue;
        final person = personal['${role.name}:$name'] ??= RecapPerson(name: name, role: role, count: 0);
        person
          ..count += 1
          ..works.add(entry.key);
      }
      switch (entry.context.origin) {
        case DiscoveryOrigin.search:
          result.origins.search += 1;
        case DiscoveryOrigin.feed:
          result.origins.feed += 1;
        case DiscoveryOrigin.recommendation:
          result.origins.recommendation += 1;
        default:
          result.origins.other += 1;
      }
      for (final name in entry.tags) {
        if (credited.contains(name) || (entry.context.constraints.contains(name) && !entry.context.included.contains(name))) continue;
        final tag = tags[name] ??= RecapTag(name: name, source: entry.item.source, count: 0);
        tag
          ..count += 1
          ..works.add(entry.key);
        if (entry.context.preferenceAction) {
          if (entry.context.chosenTags.contains(name)) {
            tag.confirmed += 1;
          } else {
            tag
              ..hidden += 1
              ..sessions.add(entry.context.session);
          }
        }
        final counts = sources[name] ??= {};
        counts[entry.item.source] = (counts[entry.item.source] ?? 0) + 1;
        final half = entry.at < middle ? firstHalf : secondHalf;
        half[name] = (half[name] ?? 0) + 1;
      }
    }
    final previousCounts = <String, int>{};
    for (final entry in earlier.values) {
      for (final name in entry.tags) {
        previousCounts[name] = (previousCounts[name] ?? 0) + 1;
      }
      for (final (name, role) in _people(library[entry.key] ?? const RecapWorkInfo())) {
        personal['${role.name}:$name']?.previousCount += 1;
      }
    }
    final previousOrder = previousCounts.entries.toList()..sort((a, b) => a.value == b.value ? a.key.compareTo(b.key) : b.value.compareTo(a.value));
    final previousRanks = {for (final (index, entry) in previousOrder.indexed) entry.key: index + 1};
    final ranked = tags.values.toList()..sort((a, b) => a.count == b.count ? a.name.compareTo(b.name) : b.count.compareTo(a.count));
    for (final (index, tag) in ranked.indexed) {
      final counted = (sources[tag.name] ?? const <String, int>{}).entries.toList()
        ..sort((a, b) => a.value == b.value ? a.key.compareTo(b.key) : b.value.compareTo(a.value));
      tag
        ..rank = index + 1
        ..previousRank = previousRanks[tag.name]
        ..previousCount = previousCounts[tag.name] ?? 0
        ..isNew = _savedCount(tag.name, start) == 0
        ..source = counted.firstOrNull?.key ?? tag.source;
    }
    result
      ..tags = ranked
      ..people = (personal.values.toList()..sort((a, b) => a.count == b.count ? a.id.compareTo(b.id) : b.count.compareTo(a.count)));
    RecapTag? best(Map<String, int> counts) {
      MapEntry<String, int>? top;
      for (final entry in counts.entries) {
        if (top == null || entry.value > top.value || (entry.value == top.value && entry.key.compareTo(top.key) < 0)) top = entry;
      }
      return top == null ? null : ranked.where((tag) => tag.name == top!.key).firstOrNull;
    }

    result
      ..opening = best(firstHalf)
      ..closing = best(secondHalf);
    final everything = math.max(1, latest.length);
    RecapTag? signature;
    for (final tag in ranked.where((tag) => tag.count >= 2 || ranked.length < 4)) {
      if (signature == null || _signatureScore(tag, everything) > _signatureScore(signature, everything)) signature = tag;
    }
    result
      ..signature = signature
      ..highlights = _highlights(ranked, period, (tag) {
        final key = TasteControl.tagKey(source: tag.source, tag: tag.name);
        return ((searched[key] ?? double.infinity) < end, _savedCount(tag.name, previousStart));
      });

    final counts = {for (final tag in ranked) tag.name: tag.count};
    double score(List<String> tags) => tags.fold<int>(0, (sum, tag) => sum + (counts[tag] ?? 0)) / math.max(1, math.sqrt(tags.length));
    RecapWork? work(String key, List<String> tags, TasteItem item) {
      final info = library[key];
      if (info == null) return null;
      // A viewing and the open that began it are one visit, not two.
      return RecapWork(
        item: item,
        info: info,
        opens: math.max(viewingsByWork[key] ?? 0, sessionsByWork[key]?.length ?? 0),
        seconds: secondsByWork[key] ?? 0,
        score: score(tags),
      );
    }

    result.saved = [for (final entry in chosen.entries) ?work(entry.key, entry.value.tags, entry.value.item)]
      ..sort((a, b) => a.score == b.score ? a.id.compareTo(b.id) : b.score.compareTo(a.score));
    final viewed = [
      for (final key in {...secondsByWork.keys, ...sessionsByWork.keys})
        if (latest[key] case final value?) ?work(key, value.$2, value.$1),
    ];
    RecapWork? revisited;
    for (final candidate in viewed.where((work) => work.opens >= 2)) {
      if (revisited == null) {
        revisited = candidate;
        continue;
      }
      final better =
          candidate.seconds > revisited.seconds ||
          (candidate.seconds == revisited.seconds &&
              (candidate.opens > revisited.opens || (candidate.opens == revisited.opens && candidate.id.compareTo(revisited.id) < 0)));
      if (better) revisited = candidate;
    }
    result.revisited = revisited;

    final top = ranked.take(10).map((tag) => tag.name).toSet();
    if (rediscovers && period != TastePeriod.week && top.isNotEmpty) {
      final settled = start - 30 * 86400, quiet = end - 60 * 86400;
      result.rediscover = [
        for (final MapEntry(:key, value: value) in latest.entries)
          if (chosen[key] == null && (lastOpened[key] ?? 0) < quiet && value.$2.isNotEmpty)
            if (library[key] case final info? when (info.savedAt == null ? 0 : unixSeconds(info.savedAt)) < settled)
              if (value.$2.where(top.contains).toList() case final overlap when overlap.isNotEmpty)
                RecapWork(item: value.$1, info: info, score: score(overlap)),
      ]..sort((a, b) => a.score == b.score ? a.id.compareTo(b.id) : b.score.compareTo(a.score));
      if (result.rediscover.length > 6) result.rediscover = result.rediscover.sublist(0, 6);
    }
    final nextNames = <String>{};
    result.next = [
      ...result.highlights.map((highlight) => highlight.tag),
      ...ranked.skip(3).where((tag) => tag.isNew || tag.count > tag.previousCount),
      ...ranked.skip(3),
    ].where((tag) => nextNames.add(tag.name)).take(3).toList();
    result.persona = _persona(result, clock);
    return result;
  }

  double _signatureScore(RecapTag tag, int total) => tag.count * math.log(1 + total / math.max(1, tagHistory[tag.name]?.length ?? 1));

  List<RecapDay> _fill(Map<DateTime, RecapDay> days, TasteInterval interval) {
    final result = <RecapDay>[];
    var day = interval.start;
    while (day.isBefore(interval.end)) {
      result.add(days[day] ?? RecapDay(day));
      day = calendar.addDays(day, 1);
    }
    return result;
  }

  static int _longestRun(List<RecapDay> days) {
    var best = 0, run = 0;
    for (final day in days) {
      run = day.touched > 0 ? run + 1 : 0;
      best = math.max(best, run);
    }
    return best;
  }

  /// Ordered by how surprising each pattern is. The chart's leader is already
  /// on its own page, so it only qualifies when nothing else does.
  static List<RecapHighlight> _highlights(List<RecapTag> tags, TastePeriod period, (bool, int) Function(RecapTag tag) history) {
    final required = period == TastePeriod.week ? 2 : 3;
    final found = <RecapHighlight>[];
    for (final tag in tags) {
      final (searched, older) = history(tag);
      if (tag.confirmed == 0 && !searched && tag.hidden >= 5 && tag.sessions.length >= 3) {
        found.add(RecapHighlight(kind: RecapHighlightKind.hidden, tag: tag));
      } else if (tag.previousCount == 0 && !tag.isNew && older >= 3 && tag.count >= 2) {
        found.add(RecapHighlight(kind: RecapHighlightKind.comeback, tag: tag));
      } else if (tag.isNew && tag.count >= required) {
        found.add(RecapHighlight(kind: RecapHighlightKind.newcomer, tag: tag));
      } else if (tag.previousCount > 0 && tag.count >= required && tag.count >= tag.previousCount * 2) {
        found.add(RecapHighlight(kind: RecapHighlightKind.rising, tag: tag));
      }
    }
    found.sort((a, b) => a.kind.index == b.kind.index ? a.tag.rank.compareTo(b.tag.rank) : a.kind.index.compareTo(b.kind.index));
    return [...found.where((highlight) => highlight.tag.rank > 1), ...found.where((highlight) => highlight.tag.rank == 1)].take(3).toList();
  }

  RecapPersona? _persona(TasteRecap recap, DateTime now) {
    if (recap.saves + recap.opens < 5) return null;
    int percent(int part, int whole) => whole == 0 ? 0 : (part / whole * 100).round();
    int sum(Iterable<int> values) => values.fold(0, (total, value) => total + value);
    final activity = sum(recap.hours);
    final night = sum(recap.hours.sublist(22, 24)) + sum(recap.hours.sublist(0, 5));
    final dawn = sum(recap.hours.sublist(5, 10));
    final weekend = sum(recap.days.where((day) => const {1, 7}.contains(calendar.weekday(day.date))).map((day) => day.touched));
    final total = sum(recap.days.map((day) => day.touched));
    final elapsed = math.max(1, recap.days.where((day) => !day.date.isAfter(now)).length);
    final traits = <RecapLine>[];
    final RecapRhythm rhythm;
    if (percent(night, activity) >= 40) {
      rhythm = RecapRhythm.midnight;
      traits.add(RecapLine('%@%% of your activity came after 10 PM', ['${percent(night, activity)}']));
    } else if (percent(dawn, activity) >= 30) {
      rhythm = RecapRhythm.dawn;
      traits.add(RecapLine('%@%% of your activity came before 10 AM', ['${percent(dawn, activity)}']));
    } else if (recap.period != TastePeriod.week && percent(weekend, total) >= 55) {
      rhythm = RecapRhythm.weekend;
      traits.add(RecapLine('%@%% of your activity fell on weekends', ['${percent(weekend, total)}']));
    } else if (percent(recap.activeDays, elapsed) >= 50) {
      rhythm = RecapRhythm.steady;
      traits.add(RecapLine('Active on %@ of %@ days', ['${recap.activeDays}', '$elapsed']));
    } else {
      rhythm = RecapRhythm.daylight;
      traits.add(RecapLine('Most active around %@', [RecapPersonaClock.hour(recap.peakHour ?? 12)]));
    }
    final saveRate = percent(recap.saves, math.max(recap.opens, recap.saves));
    final searchShare = percent(recap.origins.search, recap.origins.total), feedShare = percent(recap.origins.feed, recap.origins.total);
    // A tag nearly every work carries says nothing about focus.
    final leaders = recap.tags.where((tag) => tag.count * 5 < recap.saves * 4).take(3).expand((tag) => tag.works).toSet();
    final focus = percent(leaders.length, recap.saves);
    final newcomers = recap.tags.where((tag) => tag.isNew).length;
    final breadth = percent(newcomers, recap.tags.length);
    final RecapStyle style;
    if (recap.opens >= 15 && saveRate <= 15) {
      style = RecapStyle.curator;
      traits.add(RecapLine('You kept %@ of %@ works you opened', ['${recap.saves}', '${recap.opens}']));
    } else if (recap.saves >= 3 && searchShare >= 55) {
      style = RecapStyle.hunter;
      traits.add(RecapLine('%@%% of saves came from your searches', ['$searchShare']));
    } else if (recap.saves >= 5 && focus >= 70) {
      style = RecapStyle.devotee;
      traits.add(RecapLine('Your top 3 tags cover %@%% of your saves', ['$focus']));
    } else if (recap.tags.length >= 8 && breadth >= 35) {
      style = RecapStyle.explorer;
      traits.add(RecapLine('%@ tags were new to your collection', ['$newcomers']));
    } else if (recap.saves >= 3 && feedShare >= 60) {
      style = RecapStyle.wanderer;
      traits.add(RecapLine('%@%% of saves came from browsing', ['$feedShare']));
    } else {
      style = RecapStyle.collector;
      traits.add(RecapLine('%@ works joined your collection', ['${recap.saves}']));
    }
    if (recap.longestStreak >= 3) traits.add(RecapLine('Longest streak: %@ days', ['${recap.longestStreak}']));
    return RecapPersona(rhythm: rhythm, style: style, traits: traits);
  }

  /// Every period with activity, newest first, numbered like a magazine's run.
  List<TasteRecap> issues({TastePeriod period = TastePeriod.month, DateTime? now, int limit = 36}) {
    final clock = now ?? DateTime.now();
    final first = entries
        .where((entry) => entry.kind == TasteEventKind.save || (entry.kind == TasteEventKind.open && entry.at > 0 && entry.signal == null))
        .firstOrNull;
    if (first == null) return [];
    final firstMoment = calendar.fromSeconds(first.at), current = calendar.local(clock);
    final span = switch (period) {
      TastePeriod.week => calendar.week(clock).start.difference(calendar.week(firstMoment).start).inDays ~/ 7,
      TastePeriod.year => current.year - firstMoment.year,
      _ => (current.year - firstMoment.year) * 12 + current.month - firstMoment.month,
    };
    final result = <TasteRecap>[];
    for (var offset = 0; offset >= -math.max(0, span); offset--) {
      if (result.length >= limit) break;
      // Shelves show many issues. Library matching waits until one is opened.
      final recap = this.recap(period: period, offset: offset, now: clock, rediscovers: false);
      if (recap != null && recap.hasActivity) result.add(recap);
    }
    for (final (index, recap) in result.indexed) {
      recap.issue = result.length - index;
    }
    return result;
  }

  TasteRecap? yearly({required int offset, DateTime? now}) {
    final recap = this.recap(period: TastePeriod.year, offset: offset, now: now);
    if (recap == null) return null;
    recap.months = [
      for (var month = 0; month < 12; month++)
        () {
          final start = calendar.addMonths(recap.interval.start, month), end = calendar.addMonths(start, 1);
          final seen = <String>{}, counts = <String, int>{};
          for (var index = _firstEntry(unixSeconds(start)); index < entries.length && entries[index].at < unixSeconds(end); index++) {
            final entry = entries[index];
            if (entry.kind != TasteEventKind.save || !seen.add(entry.key)) continue;
            for (final tag in entry.tags) {
              counts[tag] = (counts[tag] ?? 0) + 1;
            }
          }
          MapEntry<String, int>? top;
          for (final entry in counts.entries) {
            if (top == null || entry.value > top.value || (entry.value == top.value && entry.key.compareTo(top.key) < 0)) top = entry;
          }
          return TasteRecapMonth(start: start, saves: seen.length, topTag: top?.key);
        }(),
    ];
    return recap;
  }
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
  rhythm,
  time,
  year,
  favorite,
  rediscover,
  persona,
  next;

  static List<RecapPage> pages(TasteRecap recap) {
    if (!recap.hasActivity) return [cover];
    return [
      cover,
      numbers,
      if (recap.tags.isNotEmpty) chart,
      if (recap.period != TastePeriod.week && recap.people.isNotEmpty && (recap.people.first.count) >= 2) person,
      if (recap.period != TastePeriod.week && recap.saved.isNotEmpty) palette,
      if (recap.highlights.isNotEmpty) discovery,
      if (recap.months.isNotEmpty) year,
      if (recap.activeDays >= 2) rhythm,
      if (recap.seconds >= 300) time,
      if (recap.revisited != null) favorite,
      if (recap.rediscover.isNotEmpty) rediscover,
      if (recap.persona != null) persona,
      next,
    ];
  }
}

/// A complete issue made of invented works. It runs through the real builder, so
/// the sample shows exactly what a person's own issue will contain.
abstract final class TasteRecapSample {
  static TasteRecap? sample({required TasteMode mode, DateTime? now, String? timeZone}) {
    final clock = now ?? DateTime.now();
    final zone = timeZone ?? TasteControl.currentTimeZone;
    final control = TasteControl(timeZone: zone);
    final source = mode == TasteMode.comics ? MangaUrls.source : 'https://sample.invalid';
    final tags = mode == TasteMode.booru
        ? ['sky', 'cloud', 'scenery', 'sunset', 'ocean', 'rain', 'forest', 'night', 'lantern', 'umbrella', 'train', 'snow']
        : [
            'tag:slice_of_life', 'tag:adventure', 'tag:fantasy', 'tag:school_life', 'tag:romance', 'tag:mystery', //
            'tag:travel', 'tag:cooking', 'tag:music', 'tag:sports', 'tag:seasons', 'tag:friendship',
          ];
    const artists = ['Mira Sato', 'Noa Lindqvist', 'Hana Okabe', 'Theo Marsh'];
    final interval = TastePeriod.month.interval(offset: -1, now: clock, timeZone: zone);
    final earlier = TastePeriod.month.interval(offset: -2, now: clock, timeZone: zone);
    if (interval == null || earlier == null) return null;
    final events = <TasteEvent>[];
    final library = <String, RecapWorkInfo>{};
    void add(TasteEventKind kind, TasteItem item, {required double at, required DiscoveryContext context, TasteDwell? dwell}) =>
        events.add(TasteEvent(id: 'sample-${events.length}', kind: kind, item: item, context: context, dwell: dwell, at: at));
    const day = 86400.0;
    final start = interval.startSeconds;
    for (var index = 0; index < 46; index++) {
      final tagIndexes = [index % 3, 3 + index % 4, index % 9 == 0 ? 11 : 6 + index % 3];
      final item = TasteItem(source: source, id: index + 1, tags: [for (final value in tagIndexes) tags[value]]);
      final origin = index % 3 == 0
          ? DiscoveryContext(origin: DiscoveryOrigin.search, query: tags[index % 3], session: 's${index % 7}')
          : DiscoveryContext(origin: DiscoveryOrigin.feed, session: 's${index % 7}');
      final date = start + (index % 26) * day + (index % 4 == 0 ? 3 : 21) * 3600 + index * 90;
      add(TasteEventKind.open, item, at: date - 120, context: origin);
      add(TasteEventKind.save, item, at: date, context: origin);
      add(
        TasteEventKind.open,
        item,
        at: date + 30,
        context: origin,
        dwell: TasteDwell(seconds: 180 + (index % 5) * 200, pages: 8 + index % 18, finished: index % 3 == 0),
      );
      if (index == 4) {
        for (var visit = 1; visit <= 4; visit++) {
          add(TasteEventKind.open, item, at: date + visit * 18000, context: origin, dwell: const TasteDwell(seconds: 300, pages: 20));
        }
      }
      library[item.key] = RecapWorkInfo(
        title: L10n.text('Sample work %@', ['${index + 1}']),
        artists: [artists[index % 5 == 0 ? 1 : (index % 3 == 0 ? 2 : 0)]],
        savedAt: DateTime.fromMicrosecondsSinceEpoch((date * 1e6).round(), isUtc: true),
      );
    }
    for (var index = 0; index < 18; index++) {
      final item = TasteItem(source: source, id: index + 100, tags: [tags[index % 5], tags[5 + index % 3]]);
      add(
        TasteEventKind.save,
        item,
        at: earlier.startSeconds + index * day,
        context: DiscoveryContext(origin: DiscoveryOrigin.feed, session: 'old$index'),
      );
    }
    for (var index = 0; index < 6; index++) {
      final item = TasteItem(source: source, id: index + 200, tags: [tags[index % 3]]);
      add(TasteEventKind.seed, item, at: 0, context: DiscoveryContext.unknown);
      library[item.key] = RecapWorkInfo(
        title: L10n.text('Sample work %@', ['${index + 47}']),
        artists: [artists[3]],
        savedAt: DateTime.fromMillisecondsSinceEpoch(86400000, isUtc: true),
      );
    }
    for (var index = 0; index < 5; index++) {
      add(
        TasteEventKind.search,
        TasteItem(source: source, id: 0, tags: [tags[index]]),
        at: start + index * 4 * day,
        context: DiscoveryContext(origin: DiscoveryOrigin.search, query: tags[index], session: 'q$index'),
      );
    }
    final recap = RecapIndex(events: events, control: control, mode: mode, library: library).recap(period: TastePeriod.month, offset: -1, now: clock);
    return recap
      ?..isSample = true
      ..issue = 12;
  }
}
