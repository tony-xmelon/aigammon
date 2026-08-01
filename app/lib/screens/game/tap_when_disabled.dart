import 'package:flutter/material.dart';

/// Wraps [child] — typically a [ButtonStyleButton] whose `onPressed` may be
/// null — so a tap the button itself swallows while disabled still reaches
/// [onDisabledTap]. A disabled Material button gone dead cannot say WHY; this
/// exists for the controls where the reason is worth a sentence.
///
/// Relies on how Flutter resolves a tap between an ancestor and a descendant
/// gesture detector, not a documented contract, so the reasoning is worth
/// writing down: a disabled [ButtonStyleButton] still builds an [InkWell]
/// whose hit-test region is opaque — it just registers no tap recognizer — so
/// the pointer event still reaches every ancestor along that hit path,
/// including this one. With no recognizer inside the button competing for the
/// same pointer, this widget's [GestureDetector] is the ONLY arena member and
/// wins every time. When the child IS enabled, its own recognizer sits
/// DEEPER in the hit path and is dispatched (and therefore resolves the
/// arena) first, so [onDisabledTap] is never invoked for a live tap — proven
/// by the existing "two Double presses" race test, which still asserts
/// exactly one [DoubleEvent] with this wrapper in place.
class TapWhenDisabled extends StatelessWidget {
  const TapWhenDisabled({
    super.key,
    required this.onDisabledTap,
    required this.child,
  });

  final VoidCallback onDisabledTap;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      GestureDetector(onTap: onDisabledTap, child: child);
}
