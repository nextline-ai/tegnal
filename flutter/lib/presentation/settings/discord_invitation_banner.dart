import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/support/l10n.dart';
import '../../core/support/mode_settings.dart';
import '../design/tegnal_theme.dart';
import 'settings_view.dart';

/// `DiscordInvitationBanner`: a compact invitation row in Discord's color above the settings,
/// shown every few days until dismissed.
class DiscordInvitationBanner extends StatefulWidget {
  const DiscordInvitationBanner({super.key, required this.invitation});
  final DiscordInvitation invitation;

  @override
  State<DiscordInvitationBanner> createState() => _DiscordInvitationBannerState();
}

class _DiscordInvitationBannerState extends State<DiscordInvitationBanner> {
  static const _discordColor = Color.fromARGB(255, 88, 101, 242);

  @override
  void initState() {
    super.initState();
    widget.invitation.presentIfDue();
    // Counted only once it is on screen; staying in Settings keeps its date.
    if (widget.invitation.visible) WidgetsBinding.instance.addPostFrameCallback((_) => widget.invitation.recordDisplay());
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.invitation.visible) return const SizedBox.shrink();
    const white = Color(0xFFFFFFFF);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(26),
        child: ColoredBox(
          color: _discordColor,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.only(left: 16, right: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      link: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => launchUrl(DeveloperSection.community, mode: LaunchMode.externalApplication),
                        child: Row(
                          children: [
                            const SizedBox(width: 24, child: Icon(CupertinoIcons.bubble_left_bubble_right_fill, size: 22, color: white)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(L10n.text('Join us on Discord'), style: TegnalType.style(17, color: white)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: L10n.text('Close'),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(widget.invitation.dismiss),
                      child: const SizedBox(width: 28, height: 44, child: Icon(CupertinoIcons.xmark, size: 14, color: white)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
