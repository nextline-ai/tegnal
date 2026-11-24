import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../addons/addon_market.dart';
import '../support/l10n.dart';
import 'lab_sheet.dart';

/// Alerts for a new cheat-sheet edition, switched on at the foot of the sheet (iOS `LabSheetAlerts`).
///
/// There is no push server. The switch, a periodic job that fetches and verifies the signed edition, and the notification
/// itself live on the Android side (`LabSheetAlerts.kt`), so they work while the app is closed. This side hands it what it
/// needs (where to fetch, the key that signs, the words in the app's language) and asks it what it knows.
abstract final class LabSheetAlerts {
  static const channel = MethodChannel('work.nextline.tegnal/labAlerts');

  /// Only the Android app has the job; elsewhere (tests, desktop builds) the switch is not shown.
  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// Whether the switch is on.
  static Future<bool> isOn() async => supported && await _call<bool>('isOn') == true;

  /// Turns alerts on or off. Turning on asks for permission to notify (Android 13 and later); false when it was refused.
  /// [known] is the newest edition date already on the device: only a later one is news.
  static Future<bool> set(bool on, {String? known}) async {
    if (!supported) return false;
    if (!on) {
      await _call<void>('disable');
      return true;
    }
    await configure();
    return await _call<bool>('enable', {'known': known}) == true;
  }

  /// The words and the source, again whenever the app starts with the switch on, so a changed language is followed.
  static Future<void> configure() => _call<void>('configure', {
    'url': LabSheetSource.url.toString(),
    'key': base64.encode(base64.decode(AddonMarket.livePublicKey)),
    'title': L10n.text('lab.sheet.alert.title'),
    'body': L10n.text('lab.sheet.alert.body'),
    'channel': L10n.text('lab.sheet.alerts'),
  });

  /// Whether Android still lets the app notify. It can be taken back in the system settings while the switch stays on.
  static Future<bool> allowed() async => supported && await _call<bool>('allowed') == true;

  static Future<void> openSettings() => _call<void>('openSettings');

  /// True once after the app was opened from an alert.
  static Future<bool> takeOpen() async => supported && await _call<bool>('takeOpen') == true;

  static Future<T?> _call<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on Object {
      return null;
    }
  }
}
