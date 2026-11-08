// `WeeklyHabitsTests` from native-ios/TEGNALTests/ReaderUXTests.swift.

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/presentation/content/reader_models.dart';
import 'package:tegnal/presentation/settings/backup_reminder.dart';

void main() {
  test('the backup reminder waits a week from first launch and from the last save', () {
    final store = MemoryPreferences();
    final start = DateTime.utc(2026, 11, 1);
    expect(
      BackupReminder.isDue(now: start, store: store),
      isFalse,
      reason: 'A new install is not asked at once',
    );
    expect(BackupReminder.isDue(now: start.add(const Duration(days: 6)), store: store), isFalse);
    expect(BackupReminder.isDue(now: start.add(const Duration(days: 7)), store: store), isTrue);

    BackupReminder.saved(now: start.add(const Duration(days: 7)), store: store);
    expect(
      BackupReminder.isDue(now: start.add(const Duration(days: 13)), store: store),
      isFalse,
      reason: 'A saved backup restarts the week',
    );
    expect(BackupReminder.isDue(now: start.add(const Duration(days: 14)), store: store), isTrue);

    BackupReminder.shown(now: start.add(const Duration(days: 14)), store: store);
    expect(
      BackupReminder.isDue(now: start.add(const Duration(days: 15)), store: store),
      isFalse,
      reason: 'Showing it starts the next week',
    );

    BackupReminder.setEnabled(false, store);
    expect(
      BackupReminder.isDue(now: start.add(const Duration(days: 60)), store: store),
      isFalse,
      reason: 'Only Settings turns it off',
    );
  });

  test('only a single tag opens in the tag language', () {
    expect(TagBrowsing.matches('tag:example'), isTrue);
    expect(TagBrowsing.matches('female:glasses'), isTrue);
    expect(TagBrowsing.matches('artist:someone'), isFalse, reason: 'Artists keep their own language');
    expect(TagBrowsing.matches('language:korean'), isFalse);
    expect(TagBrowsing.matches('tag:example tag:other'), isFalse);
    expect(TagBrowsing.matches('example'), isFalse);
    expect(TagBrowsing.matches('tag:'), isFalse);
    expect(TagBrowsing.matches(':example'), isFalse);
  });

  test('thumbnail gestures keep their defaults and a tap always acts', () {
    final store = MemoryPreferences();
    expect(ThumbnailGesture.tap.action(defaults: store), ThumbnailAction.open);
    expect(ThumbnailGesture.doubleTap.action(defaults: store), ThumbnailAction.upNext);
    expect(ThumbnailGesture.hold.action(defaults: store), ThumbnailAction.bookmark);

    ThumbnailGesture.doubleTap.choose(ThumbnailAction.bookmark, defaults: store);
    ThumbnailGesture.hold.choose(ThumbnailAction.details, defaults: store);
    expect(ThumbnailGesture.doubleTap.action(defaults: store), ThumbnailAction.bookmark);
    expect(ThumbnailGesture.hold.action(defaults: store), ThumbnailAction.details);

    store.set(ThumbnailGesture.tap.key(), ThumbnailAction.none.name);
    expect(ThumbnailGesture.tap.action(defaults: store), ThumbnailAction.open, reason: 'A tap must always do something');
    expect(ThumbnailGesture.tap.choices(), isNot(contains(ThumbnailAction.none)));
  });

  test('image mode gestures keep today\'s behavior and their own choices', () {
    final store = MemoryPreferences();
    expect(ThumbnailGesture.tap.action(booru: true, defaults: store), ThumbnailAction.open);
    expect(ThumbnailGesture.doubleTap.action(booru: true, defaults: store), ThumbnailAction.none);
    expect(ThumbnailGesture.hold.action(booru: true, defaults: store), ThumbnailAction.favorite);
    ThumbnailGesture.hold.choose(ThumbnailAction.folder, booru: true, defaults: store);
    expect(ThumbnailGesture.hold.action(booru: true, defaults: store), ThumbnailAction.folder);
    expect(ThumbnailGesture.hold.action(defaults: store), ThumbnailAction.bookmark, reason: 'Each mode keeps its own choices');
    store.set(ThumbnailGesture.doubleTap.key(booru: true), ThumbnailAction.upNext.name);
    expect(ThumbnailGesture.doubleTap.action(booru: true, defaults: store), ThumbnailAction.none, reason: 'Images have no Up Next');
  });
}
