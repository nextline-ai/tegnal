import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/app/privacy_cover.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the window cover hears about each change of setting once, and the launch messages', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('work.nextline.tegnal/privacy'), (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    PrivacyCover.configure(resumeAnimation: true);
    PrivacyCover.configure(resumeAnimation: true);
    PrivacyCover.configure(resumeAnimation: false);
    PrivacyCover.launchReady();
    PrivacyCover.skipLaunchSplash();
    await pumpEventQueue();
    expect(calls.map((call) => call.method), ['configure', 'configure', 'launchReady', 'skipLaunchSplash']);
    expect(calls[0].arguments, {'resumeAnimation': true});
    expect(calls[1].arguments, {'resumeAnimation': false});
    expect(calls[2].arguments, isNull);
  });
}
