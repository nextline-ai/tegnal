import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/app/privacy_cover.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the window cover hears about each change of appearance or setting once', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('work.nextline.tegnal/privacy'), (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    PrivacyCover.configure(dark: true, resumeAnimation: true);
    PrivacyCover.configure(dark: true, resumeAnimation: true);
    PrivacyCover.configure(dark: false, resumeAnimation: true);
    PrivacyCover.configure(dark: false, resumeAnimation: false);
    PrivacyCover.skipLaunchSplash();
    await pumpEventQueue();
    expect(calls.map((call) => call.method), ['configure', 'configure', 'configure', 'skipLaunchSplash']);
    expect(calls[1].arguments, {'dark': false, 'resumeAnimation': true});
    expect(calls[2].arguments, {'dark': false, 'resumeAnimation': false});
  });
}
