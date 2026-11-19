import 'package:flutter/foundation.dart';

import '../booru/booru_store.dart';
import '../generation/generation_store.dart';
import '../support/l10n.dart';
import 'study_models.dart';
import 'study_path.dart';
import 'study_store.dart';

/// The kinds of badge, in the order the gallery shows them.
enum StudyAwardFamily {
  lessons,
  sections,
  streak,
  tags,
  perfect,
  combo,
  xp,
  studio,
  speed;

  String get rawValue => name;

  String get title => L10n.text(switch (this) {
    lessons => 'Lessons',
    sections => 'Sections',
    streak => 'Day streak',
    tags => 'Tags',
    perfect => 'Perfect Lessons',
    combo => 'Right in a Row',
    xp => 'Experience',
    studio => 'Studio',
    speed => 'Speed Round',
  });
}

/// How hard a badge is, from bronze up to prism.
enum StudyAwardMetal {
  bronze,
  silver,
  gold,
  prism;

  int get rawValue => index;
}

/// A badge the learner can earn. Badges come in families, and most families have several, each harder than the last.
class StudyAward {
  const StudyAward({
    required this.id,
    required this.family,
    required this.metal,
    required this.symbol,
    required this.title,
    required this.detail,
    required this.goal,
    this.section,
    this.color,
    this.sectionTitle,
  });

  final String id;
  final StudyAwardFamily family;
  final StudyAwardMetal metal;
  final String symbol;

  /// English wording, which is also the key of its translations. A section's badge is named by the section instead.
  final String title;
  final String detail;

  /// How much of the family's measure earns it.
  final int goal;

  /// For a section's badge: which section, its colour and its own name.
  final String? section;
  final String? color;
  final StudyText? sectionTitle;

  /// The pictures to generate before the generator shows its advanced settings.
  static const advancedPictures = 3;

  /// Every badge there is, in the order the gallery shows them.
  static List<StudyAward> all([StudyPath? path]) {
    final shaped = path ?? StudyPath.bundled;
    List<StudyAward> make(StudyAwardFamily family, List<(int, String, String, String)> rows) => [
      for (final (index, row) in rows.indexed)
        StudyAward(
          id: '${family.rawValue}-${row.$1}',
          family: family,
          metal: StudyAwardMetal.values[index < 3 ? index : 3],
          symbol: row.$2,
          title: row.$3,
          detail: row.$4,
          goal: row.$1,
        ),
    ];
    return [
      ...make(StudyAwardFamily.lessons, [
        (1, 'figure.walk', 'First Step', 'Finish your first lesson.'),
        (10, 'book.fill', 'Getting Going', 'Finish 10 lessons.'),
        (30, 'books.vertical.fill', 'Dedicated Learner', 'Finish 30 lessons.'),
      ]),
      // The last of the family is the whole path, however long the path is.
      StudyAward(
        id: 'lessons-all',
        family: StudyAwardFamily.lessons,
        metal: StudyAwardMetal.prism,
        symbol: 'graduationcap.fill',
        title: 'Graduate',
        detail: 'Finish every lesson on the map.',
        goal: shaped.lessons.isEmpty ? 1 : shaped.lessons.length,
      ),
      for (final section in shaped.sections.where((section) => section.lessons.isNotEmpty))
        StudyAward(
          id: 'section-${section.id}',
          family: StudyAwardFamily.sections,
          metal: StudyAwardMetal.gold,
          symbol: section.lessons.first.symbol,
          title: '',
          detail: 'Finish every lesson of this section.',
          goal: section.lessons.length,
          section: section.id,
          color: section.color,
          sectionTitle: section.title,
        ),
      ...make(StudyAwardFamily.streak, [
        (3, 'flame.fill', 'Three in a Row', 'Study 3 days in a row.'),
        (7, 'flame.fill', 'A Full Week', 'Study 7 days in a row.'),
        (14, 'flame.fill', 'Two Weeks Strong', 'Study 14 days in a row.'),
        (30, 'flame.fill', 'A Month of Study', 'Study 30 days in a row.'),
      ]),
      ...make(StudyAwardFamily.tags, [
        (10, 'tag.fill', 'Tag Collector', 'Learn 10 tags well.'),
        (50, 'tag.fill', 'Tag Scholar', 'Learn 50 tags well.'),
        (150, 'tag.fill', 'Walking Dictionary', 'Learn 150 tags well.'),
        (300, 'tag.fill', 'Tag Master', 'Learn 300 tags well.'),
      ]),
      ...make(StudyAwardFamily.perfect, [
        (1, 'star.fill', 'Flawless', 'Finish a lesson with three stars.'),
        (10, 'star.fill', 'Sharp Eye', 'Finish 10 lessons with three stars.'),
        (25, 'star.fill', 'Perfectionist', 'Finish 25 lessons with three stars.'),
      ]),
      ...make(StudyAwardFamily.combo, [
        (5, 'bolt.horizontal.fill', 'Warming Up', 'Get 5 answers right in a row.'),
        (10, 'bolt.horizontal.fill', 'Hot Streak', 'Get 10 answers right in a row.'),
        (20, 'bolt.horizontal.fill', "Can't Be Stopped", 'Get 20 answers right in a row.'),
      ]),
      ...make(StudyAwardFamily.xp, [
        (100, 'bolt.fill', 'First Hundred', 'Earn 100 XP.'),
        (500, 'bolt.fill', 'Five Hundred Club', 'Earn 500 XP.'),
        (2000, 'bolt.fill', 'Two Thousand Strong', 'Earn 2,000 XP.'),
      ]),
      const StudyAward(id: 'studio-key', family: StudyAwardFamily.studio, metal: StudyAwardMetal.bronze, symbol: 'key.fill', title: 'Connected', detail: 'Save your Civitai API key.', goal: 1),
      const StudyAward(id: 'studio-1', family: StudyAwardFamily.studio, metal: StudyAwardMetal.silver, symbol: 'wand.and.stars', title: 'First Picture', detail: 'Generate your first picture.', goal: 1),
      const StudyAward(
        id: 'studio-3',
        family: StudyAwardFamily.studio,
        metal: StudyAwardMetal.silver,
        symbol: 'slider.horizontal.3',
        title: 'Advanced Unlocked',
        detail: "Generate 3 pictures. This opens the generator's advanced settings.",
        goal: advancedPictures,
      ),
      const StudyAward(id: 'studio-10', family: StudyAwardFamily.studio, metal: StudyAwardMetal.gold, symbol: 'photo.stack.fill', title: 'Studio Regular', detail: 'Generate 10 pictures.', goal: 10),
      const StudyAward(id: 'studio-50', family: StudyAwardFamily.studio, metal: StudyAwardMetal.prism, symbol: 'paintpalette.fill', title: 'Prolific', detail: 'Generate 50 pictures.', goal: 50),
      ...make(StudyAwardFamily.speed, [
        (10, 'hare.fill', 'Quick Fingers', 'Score 10 in a Speed Round.'),
        (20, 'hare.fill', 'Lightning', 'Score 20 in a Speed Round.'),
      ]),
    ];
  }

  String get name => sectionTitle?.resolved() ?? L10n.text(title);
  String get explanation => L10n.text(detail);

  @override
  bool operator ==(Object other) =>
      other is StudyAward &&
      other.id == id &&
      other.family == family &&
      other.metal == metal &&
      other.symbol == symbol &&
      other.title == title &&
      other.detail == detail &&
      other.goal == goal &&
      other.section == section &&
      other.color == color &&
      (other.sectionTitle == null ? sectionTitle == null : sectionTitle != null && mapEquals(other.sectionTitle, sectionTitle));
  @override
  int get hashCode => Object.hash(id, family, metal, symbol, title, detail, goal, section, color);
  @override
  String toString() => 'StudyAward($id)';
}

/// What the learner has done so far, as the numbers badges are measured by.
class StudyFacts {
  StudyFacts({
    this.lessons = 0,
    Map<String, int>? sections,
    this.streak = 0,
    this.learned = 0,
    this.perfect = 0,
    this.combo = 0,
    this.xp = 0,
    this.key = false,
    this.pictures = 0,
    this.speed = 0,
  }) : sections = sections ?? {};

  factory StudyFacts.of({
    required StudyPath path,
    required Map<String, StudyLessonRecord> records,
    required List<StudyDay> days,
    required Map<String, StudyProgress> progress,
    required Map<String, int> stats,
    DateTime? now,
    Duration? utcOffset,
  }) => StudyFacts(
    lessons: path.lessons.where((lesson) => records[lesson.id] != null).length,
    sections: {for (final section in path.sections) section.id: section.lessons.where((lesson) => records[lesson.id] != null).length},
    // The longest run ever reached counts, so that a badge in sight is not lost to one missed day.
    streak: _most(StudySummary.of(curriculum: StudyCurriculum.empty, progress: const {}, days: days, now: now, utcOffset: utcOffset).streak, stats[StudyCounter.streak] ?? 0),
    learned: progress.values.where((value) => value.isLearned).length,
    perfect: records.values.where((record) => record.stars >= 3).length,
    combo: stats[StudyCounter.combo] ?? 0,
    xp: days.fold(0, (total, day) => total + day.xp),
    key: (stats[StudyCounter.key] ?? 0) > 0,
    pictures: stats[StudyCounter.pictures] ?? 0,
    speed: stats[StudyCounter.speed] ?? 0,
  );

  static int _most(int a, int b) => a > b ? a : b;

  int lessons;

  /// Lessons finished in each section, by the section's identifier.
  Map<String, int> sections;
  int streak;
  int learned;
  int perfect;
  int combo;
  int xp;
  bool key;
  int pictures;
  int speed;

  /// How far along the learner is toward a badge, in the badge's own measure.
  int value(StudyAward award) => switch (award.family) {
    StudyAwardFamily.lessons => lessons,
    StudyAwardFamily.sections => sections[award.section ?? ''] ?? 0,
    StudyAwardFamily.streak => streak,
    StudyAwardFamily.tags => learned,
    StudyAwardFamily.perfect => perfect,
    StudyAwardFamily.combo => combo,
    StudyAwardFamily.xp => xp,
    StudyAwardFamily.studio => award.id == 'studio-key' ? (key ? 1 : 0) : pictures,
    StudyAwardFamily.speed => speed,
  };

  bool has(StudyAward award) => value(award) >= award.goal;

  /// From zero to one.
  double progress(StudyAward award) => award.goal <= 0 ? 1 : (value(award) / award.goal).clamp(0.0, 1.0);

  @override
  bool operator ==(Object other) =>
      other is StudyFacts &&
      other.lessons == lessons &&
      mapEquals(other.sections, sections) &&
      other.streak == streak &&
      other.learned == learned &&
      other.perfect == perfect &&
      other.combo == combo &&
      other.xp == xp &&
      other.key == key &&
      other.pictures == pictures &&
      other.speed == speed;
  @override
  int get hashCode => Object.hash(lessons, Object.hashAllUnordered(sections.entries.map((entry) => Object.hash(entry.key, entry.value))), streak, learned, perfect, combo, xp, key, pictures, speed);
}

/// Counters kept for badges that nothing else in the store remembers.
abstract final class StudyCounter {
  static const combo = 'combo', streak = 'streak', key = 'key', pictures = 'pictures', speed = 'speed';
}

class StudyAwardRecord {
  const StudyAwardRecord({required this.id, required this.earned, required this.seen});
  final String id;
  final DateTime earned;

  /// False until its celebration has been shown.
  final bool seen;

  @override
  bool operator ==(Object other) => other is StudyAwardRecord && other.id == id && other.earned == earned && other.seen == seen;
  @override
  int get hashCode => Object.hash(id, earned, seen);
}

/// Works out which badges have been earned, and hands back the ones still to be celebrated.
abstract final class StudyAwards {
  static StudyFacts facts(BooruStore store, {StudyPath? path, DateTime? now, Duration? utcOffset}) {
    final study = store.studyStore;
    T read<T>(T Function() body, T fallback) {
      try {
        return body();
      } on Object {
        return fallback;
      }
    }

    return StudyFacts.of(
      path: path ?? StudyPath.bundled,
      records: read(study.lessons, {}),
      days: read(study.days, []),
      progress: read(study.progress, {}),
      stats: read(study.stats, {}),
      now: now,
      utcOffset: utcOffset,
    );
  }

  /// Brings the counters and the earned badges up to date. Returns the badges earned but not yet shown, in gallery order.
  static List<StudyAward> refresh(BooruStore store, {StudyPath? path, required GenerationStore? generation, DateTime? now, Duration? utcOffset}) {
    final study = store.studyStore;
    T read<T>(T Function() body, T fallback) {
      try {
        return body();
      } on Object {
        return fallback;
      }
    }

    void attempt(void Function() body) => read<void>(body, null);

    // Without a generator to ask, the counters it feeds stay as they are; every other badge is still worked out.
    if (generation != null) {
      attempt(() => study.raise(StudyCounter.pictures, generation.pictures.length));
      if (generation.hasKey) attempt(() => study.raise(StudyCounter.key, 1));
    }
    final days = read(study.days, <StudyDay>[]);
    attempt(
      () => study.raise(StudyCounter.streak, StudySummary.of(curriculum: StudyCurriculum.empty, progress: const {}, days: days, now: now, utcOffset: utcOffset).streak),
    );
    final found = facts(store, path: path, now: now, utcOffset: utcOffset);
    final all = StudyAward.all(path);
    final known = read(study.awards, <String, StudyAwardRecord>{});
    attempt(() => study.grant([for (final award in all) if (found.has(award) && known[award.id] == null) award.id]));
    final records = read(study.awards, <String, StudyAwardRecord>{});
    return [for (final award in all) if (records[award.id]?.seen == false) award];
  }
}
