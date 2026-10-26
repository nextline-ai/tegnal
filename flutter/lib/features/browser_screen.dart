import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/app_controller.dart';
import '../data/session_client.dart';
import '../ui/l10n.dart';

/// Android opens the real WebView Activity. Desktop opens the default external
/// browser and explicitly explains that its session is separate from the app.
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, required this.url});
  final Uri url;
  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  bool _opening = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_open());
    });
  }

  Future<void> _open() async {
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      await BrowserSession.open(
        widget.url,
        labels: {
          'close': L10n.tr(context, 'Close'),
          'back': L10n.tr(context, 'Back'),
          'retry': L10n.tr(context, 'Retry'),
          'browser': L10n.tr(context, 'Open in browser'),
          'connectionError': L10n.tr(
            context,
            'This website could not connect inside the app.',
          ),
          'certificateError': L10n.tr(
            context,
            'The secure connection could not be verified.',
          ),
          'separateSession': L10n.tr(
            context,
            'Browser sign-ins are separate from TEGNAL and will not unlock app catalog requests.',
          ),
          'browserUnavailable': L10n.tr(
            context,
            'Unable to open the default browser.',
          ),
        },
      );
      if (!mounted) return;
      if (BrowserSession.supported) {
        Navigator.of(context).pop();
      } else {
        setState(() {
          _opening = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _opening = false;
          _error = AppController.errorMessage(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_opening) const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                _error ??
                    L10n.tr(
                      context,
                      BrowserSession.supported
                          ? 'Complete website verification or sign in, then close the browser to retry in TEGNAL.'
                          : 'Opened in your default browser. External browser sign-ins and cookies are not imported into TEGNAL.',
                    ),
                textAlign: TextAlign.center,
              ),
              if (!_opening)
                TextButton(
                  onPressed: _open,
                  child: Text(
                    L10n.tr(context, _error == null ? 'Open website' : 'Retry'),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
    appBar: AppBar(title: Text(widget.url.host)),
  );
}
