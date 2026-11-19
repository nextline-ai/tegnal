import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/presentation/home/home_media.dart';
import 'package:tegnal/presentation/home/home_travel.dart';
import 'package:tegnal/presentation/home/home_world.dart';

void main() {
  test('home remembers who uses the library', () {
    // Before anything is known, the choice made while setting up the app stands in.
    expect(HomeHabit().prefersLibrary(startsLearning: false), isTrue);
    expect(HomeHabit().prefersLibrary(startsLearning: true), isFalse);
    final habit = HomeHabit();
    for (var index = 0; index < 3; index++) {
      habit.record(HomeRealm.study);
    }
    expect(habit.prefersLibrary(startsLearning: false), isFalse, reason: 'Someone who only learns has no library prepared');
    habit.record(HomeRealm.library);
    expect(habit.prefersLibrary(startsLearning: true), isTrue);
    for (var index = 0; index < HomeHabit.limit; index++) {
      habit.record(HomeRealm.study);
    }
    expect(habit.recent, 'S' * HomeHabit.limit);
    expect(habit.prefersLibrary(startsLearning: false), isFalse, reason: 'An old visit to the library is forgotten');
    expect(HomeHabit('LxS?L').recent, 'LSL');
  });

  test('the journey is one smooth curve', () {
    expect(HomeTravel.camera(0), 0);
    expect(HomeTravel.camera(1), closeTo(HomeTravel.distance, 0.0001));
    var last = -1.0;
    for (var step = 0; step <= 200; step++) {
      final camera = HomeTravel.camera(step / 200);
      expect(camera, greaterThanOrEqualTo(last), reason: 'The camera never turns back');
      last = camera;
    }
    // The scene follows a finger from the first point, and a finger alone cannot finish the journey.
    const height = 874.0;
    expect(HomeTravel.camera(HomeTravel.progressForDrag(40, height)) * height, closeTo(40, 4));
    expect(HomeTravel.camera(HomeTravel.progressForDrag(height * 3, height)), lessThan(1), reason: 'The picture is never pulled right off the screen');
    expect(HomeTravel.progressForDrag(0, height), 0);
    // The camera ends clear of the world's edge and of everything that reaches past it.
    expect(HomeTravel.distance, closeTo(HomeTravel.depth + 1 + HomeTravel.overhang, 0.0001));
    // Pulling a place back brings that edge in under the finger, point for point at first.
    final resting = HomeTravel.camera(HomeTravel.progressForPull(0, height));
    expect(resting, closeTo(HomeTravel.distance - HomeTravel.slack, 0.01));
    final pulled = HomeTravel.camera(HomeTravel.progressForPull(60, height));
    expect((resting - pulled) * height, closeTo(60, 6));
    final committed = HomeTravel.camera(HomeTravel.progressForPull(height * HomeTravel.returnCommit, height));
    expect(committed, lessThan(HomeTravel.depth + 1 + 0.22), reason: 'A pull far enough to go back has what hangs from the edge on screen');
    // The moment and the camera are each other's inverse.
    for (final t in [0.05, 0.3, 0.62, 0.9]) {
      expect(HomeTravel.progressForCamera(HomeTravel.camera(t)), closeTo(t, 0.0001));
    }
    // An animation starts where the finger was and ends exactly at its goal, without stepping backward.
    List<double> moments(double from, double to, double seconds, {double leaving = 0, double landing = 1}) => [
      for (var frame = 0; frame <= 180; frame++) HomeTravel.moment(frame / 180, start: from, end: to, seconds: seconds, leaving: leaving, landing: landing),
    ];
    final out = moments(0.2, 1, 1.8, leaving: 1.4);
    expect(out.first, closeTo(0.2, 0.0001));
    expect(out.last, closeTo(1, 0.0001));
    for (var index = 1; index < out.length; index++) {
      expect(out[index], greaterThanOrEqualTo(out[index - 1]));
    }
    final back = moments(0.9, 0, 1.7, landing: 0);
    expect(back.last, closeTo(0, 0.0001));
    for (var index = 1; index < back.length; index++) {
      expect(back[index], lessThanOrEqualTo(back[index - 1]));
    }
    // A fast finger's speed carries on, within bounds.
    expect(HomeTravel.slope(start: 0.2, end: 1, seconds: 1.8, leaving: 100), 2.6);
    expect(HomeTravel.slope(start: 0.2, end: 1, seconds: 1.8), 0.35);
    // Dust and stars show while moving, not at rest.
    expect(HomeTravel.drift(0), 0);
    expect(HomeTravel.drift(0.3), closeTo(1, 0.0001));
    expect(HomeTravel.drift(1), 0);
  });

  test('the picture fills any screen around the word TEGNAL', () {
    // A phone has the picture's own shape and shows all of it.
    final phone = HomeFraming.frame(const Size(402, 874));
    expect(phone.left, closeTo(0, 0.5));
    expect(phone.top, closeTo(0, 0.5));
    expect(phone.width, closeTo(402, 0.5));
    expect(phone.height, closeTo(874, 0.5));
    // A tablet either way up, and a desktop window, are covered edge to edge with the word in the middle.
    for (final size in const [Size(1366, 1024), Size(1024, 1366), Size(1512, 900), Size(1032, 1376)]) {
      final frame = HomeFraming.frame(size);
      expect(frame.left, lessThanOrEqualTo(0));
      expect(frame.top, lessThanOrEqualTo(0));
      expect(frame.right, greaterThanOrEqualTo(size.width - 0.5));
      expect(frame.bottom, greaterThanOrEqualTo(size.height - 0.5));
      expect(frame.width / frame.height, closeTo(HomeFraming.pictureSize.width / HomeFraming.pictureSize.height, 0.001));
      expect(frame.left + frame.width * HomeFraming.focus.dx, closeTo(size.width / 2, 0.5));
      expect(frame.top + frame.height * HomeFraming.focus.dy, closeTo(size.height / 2, 0.5), reason: 'The word TEGNAL is level with the middle of $size');
    }
  });

  test('the world finds every drawing and film', () {
    for (final realm in HomeRealm.values) {
      for (final plane in HomeWorld.planes(realm)) {
        for (final sprite in plane.sprites) {
          expect(HomeArt.sizes.containsKey(sprite.art), isTrue, reason: '${sprite.art} has no size');
        }
        // Whatever moves with the camera or faster has passed the world's end before that end is on screen.
        if (plane.depth >= 1) {
          expect(plane.sprites.every((sprite) => sprite.at <= HomeTravel.depth + 0.5), isTrue, reason: 'Nothing in the $realm world stands beyond its edge');
        }
      }
      expect(HomeArt.sizes.containsKey(HomeWorld.edge(realm)), isTrue);
    }
    for (final art in HomeArt.sizes.keys) {
      expect(File(HomeArt.path(art)).existsSync(), isTrue, reason: '${HomeArt.path(art)} is missing');
    }
    for (final name in ['home_intro.mp4', 'home_loop.mp4', 'home_theme.mp3', 'home_blur.jpg', 'home_poster.jpg']) {
      expect(File('assets/home/$name').existsSync(), isTrue, reason: '$name is missing');
    }
  });

  test('every drawing has the size the layout expects', () async {
    for (final entry in HomeArt.sizes.entries) {
      final codec = await instantiateImageCodec(File(HomeArt.path(entry.key)).readAsBytesSync());
      final frame = await codec.getNextFrame();
      expect(Size(frame.image.width.toDouble(), frame.image.height.toDouble()), entry.value, reason: entry.key);
      frame.image.dispose();
      codec.dispose();
    }
  });

  test('the world ends in its edge, laid side by side on a wide screen', () {
    for (final size in const [Size(402, 874), Size(1032, 1376), Size(1376, 1032)]) {
      for (final realm in HomeRealm.values) {
        final layout = HomeRealmLayout(realm, size);
        // The world lies between the picture and its end.
        expect(layout.world.height, closeTo(size.height * HomeTravel.depth, 0.01));
        expect(realm == HomeRealm.library ? layout.world.bottom : layout.world.top, closeTo(layout.line, 0.01));
        // At the journey's end the camera has carried the edge and its shade off the screen.
        final slide = layout.slide(1);
        final veil = layout.veilRect.shift(Offset(0, slide));
        expect(veil.overlaps(Offset.zero & size), isFalse, reason: '$realm on $size');
        // The edge tiles cover the whole width, each no wider than a phone's edge.
        final near = layout.edge.where((piece) => piece.art == HomeWorld.edge(realm)).toList();
        expect(near.map((piece) => piece.rect.left).reduce((a, b) => a < b ? a : b), lessThanOrEqualTo(0));
        expect(near.map((piece) => piece.rect.right).reduce((a, b) => a > b ? a : b), greaterThanOrEqualTo(size.width));
        expect(near.every((piece) => piece.rect.width <= HomeArt.unit(size) * 1.3 * 1.5 + 1), isTrue);
      }
      // Two lanterns hang from the cave's roof; the sky has none.
      expect(HomeRealmLayout(HomeRealm.library, size).edge.where((piece) => piece.art == 'HomeLantern').length, 2);
      expect(HomeRealmLayout(HomeRealm.study, size).edge.where((piece) => piece.art == 'HomeLantern'), isEmpty);
    }
  });
}
