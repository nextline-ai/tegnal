import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/support/app_platform.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('the phone keeps its web view, Drive sync and translation', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(AppPlatform.isDesktop, isFalse);
    expect(AppPlatform.hasWebView, isTrue);
    expect(AppPlatform.hasDriveSync, isTrue);
    expect(AppPlatform.hasImageTranslation, isTrue);
  });

  test('Windows and Linux leave out what needs the phone', () {
    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(AppPlatform.isDesktop, isTrue, reason: '$platform');
      expect(AppPlatform.hasWebView, isFalse, reason: '$platform');
      expect(AppPlatform.hasDriveSync, isFalse, reason: '$platform');
      expect(AppPlatform.hasImageTranslation, isFalse, reason: '$platform');
    }
  });
}
