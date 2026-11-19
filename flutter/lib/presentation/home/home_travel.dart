import 'dart:math' as math;

/// The two places the home scene leads to: the library below the ground, learning mode above the clouds.
enum HomeRealm {
  library,
  study;

  /// Which way the world moves on screen while travelling there: up when sinking, down when rising.
  double get direction => this == library ? 1 : -1;

  /// The letter [HomeHabit] keeps for a visit.
  String get code => this == library ? 'L' : 'S';
}

/// Which places were opened lately. The library reads its first pages from the network as the app
/// opens, and that is only worth doing for someone who goes there.
class HomeHabit {
  HomeHabit([String recent = '']) : recent = _last(recent.split('').where((letter) => letter == 'L' || letter == 'S').join());

  static const key = 'home.recentPlaces';
  static const limit = 8;

  /// One letter for each place opened, the newest last.
  String recent;

  static String _last(String value) => value.length <= limit ? value : value.substring(value.length - limit);

  /// Before anything is known, the choice made while setting up the app stands in.
  bool prefersLibrary({required bool startsLearning}) => recent.isEmpty ? !startsLearning : recent.contains(HomeRealm.library.code);

  void record(HomeRealm realm) => recent = _last(recent + realm.code);
}

/// The journey between the home scene (0) and a place (1), as plain numbers, so that the finger,
/// the animation and the tests all read the same curve.
///
/// The world is one tall picture. The home scene is its middle; the ground under it ends in the
/// roof of a cave, with the library in the open space below, and the sky over it ends in the top
/// of the clouds, with learning mode above them. A journey is the camera moving along it.
abstract final class HomeTravel {
  /// Seconds from letting go at the home scene to standing in the place.
  static const duration = 2.2;

  /// The same when the app opens straight into a place: the scene is passed through, not stayed in.
  static const quickDuration = 1.7;

  /// Seconds for the way back.
  static const returnDuration = 1.9;

  /// How far from the home scene the ground or the sky ends, in screen heights.
  static const depth = 2.2;

  /// What reaches past that end: what hangs from the cave's roof, the tops of the clouds, and the shade or mist beyond them.
  static const overhang = 0.5;

  /// How far the camera moves in all: to the end, across the screen, and clear of what reaches past it.
  static const distance = depth + 1 + overhang;

  /// How much of that reach is already back in view when a place starts being pulled; it is the faint end of the shade.
  static const slack = 0.25;

  /// How far a finger has to pull, as a share of the screen's height, for letting go to travel.
  static const commit = 0.17;

  /// The same for pulling a place back toward the scene.
  static const returnCommit = 0.14;

  /// A flick this fast, in logical pixels a second, travels without the distance.
  static const flick = 900.0;
  static const _lead = 0.6;

  static double clamp(double value) => math.min(1, math.max(0, value));

  static double smooth(double value) {
    final u = clamp(value);
    return u * u * (3 - 2 * u);
  }

  /// A curve from 0 to 1 that leaves with one slope and arrives with another.
  static double hermite(double s, {required double from, required double to}) {
    final u = clamp(s), u2 = u * u, u3 = u2 * u;
    return from * (u3 - 2 * u2 + u) + (3 * u2 - 2 * u3) + to * (u3 - u2);
  }

  /// The camera's place in screen heights. It leaves at once, so that it can follow a finger, and comes gently to rest.
  static double camera(double t) => distance * hermite(t, from: _lead, to: 0);

  /// How fast the camera moves, in screen heights for each unit of the journey.
  static double cameraSpeed(double t) {
    const step = 0.001;
    final low = math.max(0.0, t - step), high = math.min(1.0, t + step);
    return (camera(high) - camera(low)) / (high - low);
  }

  /// The moment of the journey at which the camera has moved this far.
  static double progressForCamera(double target) {
    if (target <= 0) return 0;
    if (target >= distance) return 1;
    var low = 0.0, high = 1.0;
    for (var index = 0; index < 26; index++) {
      final middle = (low + high) / 2;
      if (camera(middle) < target) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return (low + high) / 2;
  }

  /// How far the world has followed a finger, in screen heights: closely at first, then more and more loosely.
  static double follow(double pulled, double height) {
    if (height <= 0 || pulled <= 0) return 0;
    return 0.9 * (1 - math.exp(-(pulled / height) * 1.11));
  }

  /// The moment a finger at the home scene has pulled to.
  static double progressForDrag(double drag, double height) => progressForCamera(follow(drag, height));

  /// The moment a finger pulling a place back has reached: the world's edge comes back in under it.
  static double progressForPull(double pull, double height) => progressForCamera(distance - slack - follow(pull, height));

  /// Dust or stars drifting past, while moving.
  static double drift(double t) => smooth(t / 0.1) * (1 - smooth((t - 0.6) / 0.25));

  /// How steeply an animation leaves `start`: as fast as the journey was already moving when the finger let go,
  /// in units a second, within bounds.
  static double slope({required double start, required double end, required double seconds, double leaving = 0}) {
    final span = (end - start).abs();
    if (span <= 0.0001 || seconds <= 0) return 0;
    return math.min(2.6, math.max(0.35, leaving * seconds / span));
  }

  /// The moment an animation from `start` to `end` has reached at `u`, its share of the time (0 to 1).
  /// `landing` is the slope it arrives with: 1 runs on into the place, 0 comes to rest.
  static double moment(double u, {required double start, required double end, required double seconds, double leaving = 0, double landing = 1}) {
    final span = end - start;
    if (span.abs() <= 0.0001 || seconds <= 0) return end;
    return start +
        span *
            hermite(
              u,
              from: slope(start: start, end: end, seconds: seconds, leaving: leaving),
              to: landing,
            );
  }
}
