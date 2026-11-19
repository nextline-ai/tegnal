import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/app/privacy_cover.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the window cover hears the launch messages', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('work.nextline.tegnal/privacy'), (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    PrivacyCover.launchReady();
    PrivacyCover.skipLaunchSplash();
    await pumpEventQueue();
    expect(calls.map((call) => call.method), ['launchReady', 'skipLaunchSplash']);
    expect(calls[0].arguments, isNull);
  });
}
