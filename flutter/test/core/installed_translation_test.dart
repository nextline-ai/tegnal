import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/data/installed_translation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('work.nextline.tegnal/installed_translation');
  final calls = <MethodCall>[];
  final png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'installed image handler receives an image handoff without gallery writes',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'capability' ? 'direct' : null;
          });
      expect(
        await InstalledTranslation.availability(),
        InstalledTranslationAvailability.direct,
      );
      await InstalledTranslation.sendImage(png);
      expect(calls.map((call) => call.method), ['capability', 'shareImage']);
      expect(calls.last.arguments['png'], png);
    },
  );

  test('missing and unsupported handlers are reported without launching or downloading', () async {
    var status = 'missing';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return status;
        });
    expect(
      await InstalledTranslation.availability(),
      InstalledTranslationAvailability.missing,
    );
    status = 'unsupported';
    expect(
      await InstalledTranslation.availability(),
      InstalledTranslationAvailability.unsupported,
    );
    expect(calls.map((call) => call.method), ['capability', 'capability']);
  });

  test(
    'manual import is a distinct explicit action and failures stay graceful',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'capability') return 'manual';
            if (call.method == 'shareImage') {
              throw PlatformException(code: 'unavailable');
            }
            return null;
          });
      expect(
        await InstalledTranslation.availability(),
        InstalledTranslationAvailability.manualImport,
      );
      expect(calls.map((call) => call.method), ['capability']);
      await InstalledTranslation.sendImage(png, manualImport: true);
      expect(calls.last.method, 'saveImageAndOpen');
      await expectLater(
        InstalledTranslation.sendImage(png),
        throwsA(isA<InstalledTranslationException>()),
      );
    },
  );

  test('desktop does not invoke Android channels', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    expect(
      await InstalledTranslation.availability(),
      InstalledTranslationAvailability.unsupported,
    );
    await expectLater(
      InstalledTranslation.sendImage(png),
      throwsA(isA<InstalledTranslationException>()),
    );
    expect(calls, isEmpty);
  });
}
