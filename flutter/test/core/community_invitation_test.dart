import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/data/library_store.dart';

void main() {
  test('native invitation cadence starts on display and persists across settings and relaunch', () {
    final store = LibraryStore.memory();
    final controllers = <AppController>[];
    AppController environment() {
      final controller = AppController(store);
      controllers.add(controller);
      return controller;
    }

    addTearDown(() {
      for (final controller in controllers) {
        controller.dispose();
      }
      store.close();
    });
    final now = DateTime.utc(2026, 10, 28);
    const key = 'discord.invitation.nextPresentation';
    double timestamp(int days) =>
        now.add(Duration(days: days)).millisecondsSinceEpoch / 1000;
    store.setSetting('discord.invitation.nextShow', timestamp(3));
    store.setSetting('discord.invitation.dismissed', true);
    final prepared = environment()..presentDiscordInvitationIfDue(at: now);
    expect(prepared.discordInvitationVisible, isTrue);
    expect(store.setting(key, 0), 0);
    final current = environment()..presentDiscordInvitationIfDue(at: now);
    current.recordDiscordInvitationDisplay(at: now);
    expect(store.setting(key), timestamp(3));
    current.presentDiscordInvitationIfDue(at: now.add(const Duration(days: 1)));
    current.recordDiscordInvitationDisplay(
      at: now.add(const Duration(days: 1)),
    );
    expect(store.setting(key), timestamp(3));
    expect(
      environment()..presentDiscordInvitationIfDue(
        at: now.add(const Duration(days: 3, seconds: -1)),
      ),
      isA<AppController>().having(
        (c) => c.discordInvitationVisible,
        'before due',
        isFalse,
      ),
    );
    final relaunched = environment()
      ..presentDiscordInvitationIfDue(at: now.add(const Duration(days: 3)));
    expect(relaunched.discordInvitationVisible, isTrue);
    relaunched.recordDiscordInvitationDisplay(
      at: now.add(const Duration(days: 3)),
    );
    relaunched.dismissDiscordInvitation(at: now.add(const Duration(days: 3)));
    expect(relaunched.discordInvitationVisible, isFalse);
    expect(store.setting(key), timestamp(10));
    relaunched.presentDiscordInvitationIfDue(
      at: now.add(const Duration(days: 4)),
    );
    expect(relaunched.discordInvitationVisible, isFalse);
    final afterDismissal = environment()
      ..presentDiscordInvitationIfDue(
        at: now.add(const Duration(days: 10, seconds: -1)),
      );
    expect(afterDismissal.discordInvitationVisible, isFalse);
    afterDismissal.presentDiscordInvitationIfDue(
      at: now.add(const Duration(days: 10)),
    );
    expect(afterDismissal.discordInvitationVisible, isTrue);
  });
}
