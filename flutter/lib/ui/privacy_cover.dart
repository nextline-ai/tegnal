import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Covers private app content while this Flutter view is inactive.
///
/// Place this inside `MaterialApp.builder` so its `Theme` reflects the app's
/// selected appearance. Android also draws a native resume cover and separately
/// disables content snapshots for Recents, which can precede lifecycle events.
class TegnalPrivacyCover extends StatefulWidget {
  const TegnalPrivacyCover({
    super.key,
    required this.child,
    this.inactiveGracePeriod = const Duration(milliseconds: 120),
    this.resumeHold = const Duration(milliseconds: 600),
    this.transitionDuration = const Duration(milliseconds: 900),
  });

  final Widget child;
  final Duration inactiveGracePeriod;
  final Duration resumeHold;
  final Duration transitionDuration;

  @override
  State<TegnalPrivacyCover> createState() => _TegnalPrivacyCoverState();
}

class _TegnalPrivacyCoverState extends State<TegnalPrivacyCover>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _privacyChannel = MethodChannel('work.nextline.tegnal/privacy');

  late final AnimationController _exit;
  Timer? _inactiveTimer;
  Timer? _resumeTimer;
  bool _visible = false;
  bool _reduceMotion = false;
  Brightness? _lastBrightness;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _exit = AnimationController(
      vsync: this,
      duration: widget.transitionDuration,
    )..addStatusListener(_onAnimationStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    final brightness = Theme.of(context).brightness;
    if (_lastBrightness != brightness) {
      _lastBrightness = brightness;
      unawaited(_setNativeAppearance(brightness));
    }
  }

  @override
  void didUpdateWidget(covariant TegnalPrivacyCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transitionDuration != widget.transitionDuration) {
      _exit.duration = widget.transitionDuration;
    }
  }

  Future<void> _setNativeAppearance(Brightness brightness) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _privacyChannel.invokeMethod<void>('setAppearance', {
        'dark': brightness == Brightness.dark,
      });
    } on MissingPluginException {
      // Widget tests and non-Android embedding hosts have no native cover.
    } on PlatformException {
      // Native appearance updates are best-effort; Android owns its cover.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _inactiveTimer?.cancel();
        _inactiveTimer = null;
        _beginResume();
      case AppLifecycleState.inactive:
        // Android reports inactive for window-focus changes, including IME
        // startup before any inset arrives. Its native onPause cover and task
        // snapshot protection handle leaving the app; focus loss alone must
        // never add a full-screen artwork layer over a keyboard animation.
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) return;
        // Window focus changes around the soft keyboard can briefly produce an
        // inactive state. Defer this path and ignore it while the IME is open;
        // paused/hidden still cover immediately.
        if (MediaQuery.viewInsetsOf(context).bottom > 0) return;
        _inactiveTimer?.cancel();
        _inactiveTimer = Timer(widget.inactiveGracePeriod, () {
          // The IME's viewInsets update can arrive after the lifecycle event.
          // Recheck at expiry so that delayed keyboard metrics do not flash the
          // privacy artwork over a focused text field.
          if (!mounted || MediaQuery.viewInsetsOf(context).bottom > 0) return;
          _show();
        });
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // Android's Activity owns the opaque resume cover and task snapshot
        // protection. A second Flutter cover produces two branded slides.
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) return;
        _inactiveTimer?.cancel();
        _inactiveTimer = null;
        _show();
    }
  }

  void _show() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _exit.stop();
    _exit.value = 0;
    if (!_visible && mounted) setState(() => _visible = true);
  }

  void _beginResume() {
    // Scene/lifecycle observers may report the same activation more than
    // once. Preserve the original hold instead of restarting it.
    if (!_visible || _resumeTimer != null || _exit.isAnimating) return;
    _resumeTimer = Timer(widget.resumeHold, () {
      if (!mounted || !_visible) return;
      _exit.duration = _reduceMotion
          ? const Duration(milliseconds: 150)
          : widget.transitionDuration;
      _exit.forward(from: 0);
    });
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _visible && mounted) {
      setState(() => _visible = false);
      _exit.value = 0;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inactiveTimer?.cancel();
    _resumeTimer?.cancel();
    _exit.dispose();
    super.dispose();
  }

  Widget _artwork() {
    final brightness = _lastBrightness ?? Brightness.light;
    final dark = brightness == Brightness.dark;
    return ColoredBox(
      color: dark ? Colors.black : Colors.white,
      child: Center(
        child: Image.asset(
          dark
              ? 'assets/branding/splash_dark.jpg'
              : 'assets/branding/splash_light.jpg',
          fit: BoxFit.contain,
          excludeFromSemantics: true,
          errorBuilder: (context, error, stackTrace) => Text(
            'TEGNAL',
            style: Theme.of(context).textTheme.headlineLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      ExcludeSemantics(
        excluding: _visible,
        child: AbsorbPointer(absorbing: _visible, child: widget.child),
      ),
      if (_visible)
        Positioned.fill(
          child: Semantics(
            container: true,
            label: 'TEGNAL',
            child: ExcludeSemantics(
              child: AnimatedBuilder(
                animation: _exit,
                child: _artwork(),
                builder: (context, child) {
                  final animation = Tween<double>(begin: 1, end: 0).animate(
                    CurvedAnimation(parent: _exit, curve: Curves.easeInOut),
                  );
                  if (_reduceMotion) {
                    return FadeTransition(opacity: animation, child: child);
                  }
                  return SlideTransition(
                    position:
                        Tween<Offset>(
                          begin: Offset.zero,
                          end: const Offset(0, -1.02),
                        ).animate(
                          CurvedAnimation(
                            parent: _exit,
                            curve: Curves.easeInOut,
                          ),
                        ),
                    child: child,
                  );
                },
              ),
            ),
          ),
        ),
    ],
  );
}
