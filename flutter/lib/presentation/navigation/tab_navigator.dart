import 'package:cupertino_ui/cupertino_ui.dart';

/// Each tab's own `NavigationStack`: pushed screens stay under the floating tab bar, and
/// the system back gesture pops the selected tab before leaving the app.
class TabNavigator extends StatefulWidget {
  const TabNavigator({super.key, required this.active, required this.builder});
  final bool active;
  final WidgetBuilder builder;

  @override
  State<TabNavigator> createState() => _TabNavigatorState();
}

class _TabNavigatorState extends State<TabNavigator> {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) => NavigatorPopHandler<Object?>(
    enabled: widget.active,
    onPopWithResult: (_) => _navigator.currentState?.maybePop(),
    child: Navigator(
      key: _navigator,
      onGenerateRoute: (settings) => CupertinoPageRoute<void>(settings: settings, builder: widget.builder),
    ),
  );
}
