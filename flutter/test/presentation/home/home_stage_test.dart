import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/presentation/home/home_stage.dart';
import 'package:tegnal/presentation/home/home_travel.dart';

void main() {
  HomeStage make({Map<String, Object?> defaults = const {}, Map<String, Object?> booru = const {}, bool enabled = true}) =>
      HomeStage(defaults: MemoryPreferences({...defaults}), booruDefaults: MemoryPreferences({...booru}), enabled: enabled);

  test('only one place can be the one the app opens in', () {
    final stage = make();
    expect(stage.preferred, isNull);
    stage.startsLearning = true;
    stage.startsInLibrary = true;
    expect(stage.startsLearning, isFalse, reason: 'Opening in viewing mode turns opening in learning mode off');
    expect(stage.preferred, HomeRealm.library);
    stage.startsLearning = true;
    expect(stage.startsInLibrary, isFalse);
    expect(stage.preferred, HomeRealm.study);
    expect(stage.booruDefaults.boolean(HomeStage.startKey), isTrue);
    expect(stage.booruDefaults.boolean(HomeStage.libraryStartKey), isFalse);
    stage.startsLearning = false;
    expect(stage.preferred, isNull);
    // Both stored on is read as learning mode only.
    expect(make(booru: {HomeStage.startKey: true, HomeStage.libraryStartKey: true}).startsInLibrary, isFalse);
  });

  test('the library is prepared only for someone who goes there', () {
    final fresh = make();
    expect(fresh.libraryWarm && fresh.libraryMounted, isTrue, reason: 'A new install chose viewing in setup');
    expect(fresh.libraryOpened, isFalse);
    final learner = make(defaults: {HomeHabit.key: 'SSSS'});
    expect(learner.libraryWarm || learner.libraryMounted, isFalse);
    learner.leanToward(HomeRealm.study);
    expect(learner.libraryWarm, isFalse);
    learner.leanToward(HomeRealm.library);
    expect(learner.libraryWarm, isTrue, reason: 'A finger heading down warms the library');
    final startsLearning = make(booru: {HomeStage.startKey: true});
    expect(startsLearning.libraryMounted, isFalse);
    expect(startsLearning.studying, isTrue);
    final startsInLibrary = make(defaults: {HomeHabit.key: 'SS'}, booru: {HomeStage.libraryStartKey: true});
    expect(startsInLibrary.libraryMounted, isTrue);
  });

  test('a journey departs, arrives and comes home', () {
    final stage = make(defaults: {HomeHabit.key: 'S'});
    expect(stage.atHome && stage.coversScreen, isTrue);
    expect(stage.mount(HomeRealm.library), isTrue, reason: 'Built just now');
    expect(stage.mount(HomeRealm.library), isFalse);
    stage.depart(HomeRealm.library);
    expect(stage.moving && stage.coversScreen, isTrue);
    expect(stage.defaults.string(HomeHabit.key), 'SL');
    stage.engagement.value = 1;
    stage.arrive(HomeRealm.library);
    expect(stage.place, HomePlace.library);
    expect(stage.libraryOpened, isTrue);
    expect(stage.coversScreen, isFalse);
    expect(stage.engagement.value, 0);
    stage.beginReturn();
    expect(stage.coversScreen, isTrue);
    stage.pull.value = 40;
    stage.cancelReturn();
    expect(stage.pull.value, 0);
    expect(stage.coversScreen, isFalse);
    stage.arriveHome();
    expect(stage.atHome, isTrue);
  });

  test('viewing mode\'s onboarding waits for the library itself', () {
    final stage = make();
    expect(stage.libraryOnScreen, isFalse, reason: 'The home scene is on screen');
    stage.mount(HomeRealm.study);
    stage.depart(HomeRealm.study);
    stage.arrive(HomeRealm.study);
    expect(stage.libraryOnScreen, isFalse, reason: 'Learning mode has onboardings of its own');
    stage.arriveHome();
    stage.mount(HomeRealm.library);
    stage.depart(HomeRealm.library);
    expect(stage.libraryOnScreen, isFalse, reason: 'Still on the way');
    stage.arrive(HomeRealm.library);
    expect(stage.libraryOnScreen, isTrue);
    final direct = make(enabled: false);
    expect(direct.libraryOnScreen, isTrue);
    direct.enterStudy();
    expect(direct.libraryOnScreen, isFalse);
  });

  test('crossing between places goes through the scene', () {
    final stage = make();
    final asked = <HomeRealm>[];
    stage.transfer = asked.add;
    expect(stage.cross(HomeRealm.study), isFalse, reason: 'The scene itself is on screen');
    stage.mount(HomeRealm.library);
    stage.depart(HomeRealm.library);
    stage.arrive(HomeRealm.library);
    expect(stage.cross(HomeRealm.library), isTrue);
    expect(asked, isEmpty, reason: 'Already there');
    expect(stage.cross(HomeRealm.study), isTrue);
    expect(asked, [HomeRealm.study]);
    stage.beginReturn();
    expect(stage.cross(HomeRealm.study), isTrue);
    expect(asked.length, 1, reason: 'Nothing is asked while moving');
  });

  test('without the scene, the places open each other directly', () {
    final stage = make(enabled: false);
    expect(stage.place, HomePlace.library);
    expect(stage.coversScreen, isFalse);
    expect(stage.libraryWarm && stage.libraryMounted && stage.libraryOpened && stage.studyMounted, isTrue);
    expect(stage.cross(HomeRealm.study), isFalse);
    stage.enterStudy();
    expect(stage.studying, isTrue);
    expect(stage.place, HomePlace.study);
    stage.leaveStudy();
    expect(stage.studying, isFalse);
    expect(stage.place, HomePlace.library);
    expect(make(enabled: false, booru: {HomeStage.startKey: true}).place, HomePlace.study);
  });

  test('the intro, the hints, the music switch and the way-back hint', () async {
    final stage = make(booru: {HomeStage.libraryStartKey: true});
    final went = <HomeRealm>[];
    stage.travelQuickly = went.add;
    stage.openPreferred();
    await Future<void>.delayed(Duration.zero);
    expect(went, isEmpty, reason: 'Not before the blur has cleared');
    stage.finishIntro();
    await Future<void>.delayed(Duration.zero);
    expect(went, [HomeRealm.library]);
    stage.openPreferred();
    await Future<void>.delayed(Duration.zero);
    expect(went.length, 1, reason: 'Only once');

    final changes = <bool>[];
    stage.onMutedChange = changes.add;
    stage.muted = true;
    expect(stage.defaults.boolean(HomeStage.mutedKey), isTrue);
    expect(changes, [true]);
    expect(make(defaults: {HomeStage.mutedKey: true}).muted, isTrue);

    expect([for (var index = 0; index < 4; index++) stage.takeReturnHint()], [true, true, true, false]);
  });
}
