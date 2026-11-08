import 'dart:io';

import 'package:flutter/foundation.dart';

/// What the platform the app runs on can do. The phone apps carry a web view, Google sign-in,
/// on-device translation and Android's own network stack; the Windows and Linux builds do not,
/// so the screens that depend on them stay out of the way there. A macOS build, used only to
/// check the desktop layout, counts as desktop too.
abstract final class AppPlatform {
  static bool get isDesktop => switch (defaultTargetPlatform) {
    TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS => true,
    _ => false,
  };

  /// Hidden browser pages, the embedded browser, site sign-in and client validation.
  static bool get hasWebView => !isDesktop;

  /// Google Drive sync signs in with Google's mobile sign-in.
  static bool get hasDriveSync => !isDesktop;

  /// ML Kit text recognition and translation run only on the phone.
  static bool get hasImageTranslation => !isDesktop;
}

/// The computer's time zone, as an IANA name where the system keeps one (Linux and macOS);
/// otherwise its abbreviation, or UTC when the clock runs on it. Taste statistics only need to
/// know whether days end at local midnight.
Future<String?> desktopTimeZone() async {
  try {
    final timezone = File('/etc/timezone');
    if (await timezone.exists()) {
      final name = (await timezone.readAsString()).trim();
      if (name.isNotEmpty) return name;
    }
    final link = Link('/etc/localtime');
    if (await link.exists()) {
      final target = await link.target();
      final marker = target.indexOf('zoneinfo/');
      if (marker >= 0) return target.substring(marker + 'zoneinfo/'.length);
    }
  } on Object {
    // Windows keeps neither file.
  }
  final now = DateTime.now();
  return now.timeZoneOffset == Duration.zero ? 'UTC' : now.timeZoneName;
}
