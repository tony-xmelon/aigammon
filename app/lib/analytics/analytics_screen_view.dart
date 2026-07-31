import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_analytics.dart';

/// Reports one [AnalyticsEvents.screenView] when its subtree is first mounted.
///
/// **Why a widget and not a `NavigatorObserver`.** The observer approach needs
/// every route to carry a `RouteSettings(name: …)`, which would mean editing
/// each `Navigator.push` call site *and* trusting that a future one remembers.
/// Wrapping the screen's own `Scaffold` puts the declaration next to the thing
/// it names: a screen that exists is a screen that reports, and a reader of
/// `settings_screen.dart` can see its analytics name without leaving the file.
///
/// **What it does not do.** It fires on MOUNT, not on every re-appearance. When
/// a pushed route pops, the screen underneath was never unmounted, so it does
/// not re-report. That is the right trade for this app — the interesting
/// question is "which screens do people reach", not "how many times did the
/// board return to the front" — and getting the other behaviour would mean a
/// `RouteObserver` subscription in every screen's state.
class AnalyticsScreenView extends ConsumerStatefulWidget {
  const AnalyticsScreenView({
    super.key,
    required this.name,
    required this.child,
  });

  /// One of [AnalyticsScreens].
  final String name;

  final Widget child;

  @override
  ConsumerState<AnalyticsScreenView> createState() =>
      _AnalyticsScreenViewState();
}

class _AnalyticsScreenViewState extends ConsumerState<AnalyticsScreenView> {
  @override
  void initState() {
    super.initState();
    // `ref.read` (not watch): a screen view is a one-shot fact about this
    // mount, and re-firing it because the provider rebuilt would be a lie.
    ref.read(appAnalyticsProvider).logScreenView(widget.name);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
