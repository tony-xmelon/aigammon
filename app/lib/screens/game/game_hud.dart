import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';

import '../../game/match_controller.dart';
import 'tap_when_disabled.dart';

/// The compact header score, named from the local player's point of view where
/// there IS one: "You 2–3 AI · to 5" against the computer (or "… Opp …" online,
/// per [GameScreen.opponentLabel]), with the local side's score first.
///
/// Falls back to the neutral "W 2–3 B · to 5" in hot-seat, where both sides are
/// local, and for any controller with no locally-human side at all (an AI-vs-AI
/// harness), since "You" would then be a lie.
String _compactScore(MatchController c, String opponentLabel) {
  final m = c.match;
  final localWhite = c.isLocalHuman(Player.white);
  final localBlack = c.isLocalHuman(Player.black);
  final soleLocal = localWhite != localBlack;
  if (!soleLocal) {
    return 'W ${m.whiteScore}–${m.blackScore} B · to ${m.matchLength}';
  }
  final (mine, theirs) = localWhite
      ? (m.whiteScore, m.blackScore)
      : (m.blackScore, m.whiteScore);
  return 'You $mine–$theirs $opponentLabel · to ${m.matchLength}';
}

/// Entries in the header overflow (⋮) menu — one, always available wherever
/// there is a local human at all.
///
/// The three per-value Resign entries it used to hold have collapsed into a
/// single "Surrender…" that opens a sheet where the values are named with what
/// they are worth; see the game screen's Surrender sheet for why the
/// entry no longer disappears off-gate. The old "Game record" entry is GONE too: the
/// record is now the always-visible score sheet under the board.
enum _MenuAction { surrender }

// --- HUD (two rows) ----------------------------------------------------------

/// The game screen's header — the SINGLE home for every piece of match summary information,
/// in two compact rows of FIXED total height ([_hudHeight]).
///
/// * Row 1, the match context: "You 1–0 AI · to 3 · Game 2", an optional
///   Crawford badge and the cube chip, then (right) the thinking dot, the Double
///   button and the overflow (⋮) menu.
/// * Row 2, small and muted: who you are playing and the live pip counts —
///   "vs AI · Easy · Pips 129–78" (hot-seat "White vs Black · Pips …", online
///   "vs Opp · Pips …").
///
/// ## Why everything moved up here
///
/// The reported "duplicate info in the header and the line under the board. best
/// use the header for all summary info … and leave the bottom of the screen for
/// the move history and actions". The game number and match score used to be
/// printed a SECOND time on the score sheet's own context line, and the pip
/// counts had a standalone 20px line of their own between the sheet and the
/// action bar. Both are gone: the sheet is now nothing but move history (it
/// gained the context line's height, so more turns are visible within the same
/// 112px), and the space under the board belongs to history and actions alone.
///
/// ## Fixed height
///
/// Both rows are ALWAYS present — row 2 reserves its height even with nothing
/// worth saying — for the same reason the action bar is pinned to 64px: the
/// board fills the slot beneath this, so a header that grew or shrank mid-match
/// (a Crawford badge appearing, a name getting longer) would resize the board
/// (F6). What scales to fit is the TEXT: row 1's left group (context line +
/// badge + chip) and row 2's line each sit in their own [FittedBox], so they
/// shrink rather than overflow at any width or system text scale. Row 1's
/// right-hand controls — the thinking dot, Double, ⋮ — are outside that box and
/// keep their natural size, which is what leaves the left group its width.
///
/// Keeping Double/Surrender up here (rather than in the bottom bar) puts the
/// risky actions away from where thumbs rest.
class GameHud extends StatelessWidget {
  const GameHud({
    super.key,
    required this.controller,
    this.showScoring = true,
    this.opponentLabel = 'AI',
    this.opponentDetail,
    this.onSurrender,
    this.showDouble = true,
    this.onDoubled,
  });

  /// Height of row 1 (the match context plus the action controls).
  ///
  /// NOT the natural height of its tallest child: a [PopupMenuButton]'s
  /// [IconButton] asks for the 48px minimum touch target, and Double (compact
  /// density) for 32. 40 is a deliberate squeeze — the row's [BoxConstraints]
  /// clamp the icon button's 48 down, so it renders at 40 with its hit box
  /// filling the row rather than overflowing it. Anything less would start
  /// clipping Double.
  static const double _row1Height = 40;

  /// Height of row 2 (the muted opponent/pips line).
  ///
  /// 18, not the 16 it started as: the line's natural height at fontSize 12 is
  /// ~17, so 16 put every render through the [FittedBox] at ~94% — a permanent
  /// silent shrink, and one that got worse rather than better as the system text
  /// scale went up. At 18 the line renders unscaled at scale 1.0 and only starts
  /// scaling when the user has actually asked for larger text.
  static const double _row2Height = 18;

  /// Padding above row 1 and below row 2. The 2px row 2 gained came from here,
  /// so the header's total is unchanged (see [_hudHeight]).
  static const double _verticalPadding = 3;

  /// The header's FIXED total height — the top half of the screen's layout
  /// budget (see [_GameScreenState._scoreSheetHeight] for the whole table).
  static const double _hudHeight =
      _row1Height + _row2Height + 2 * _verticalPadding;

  final MatchController controller;

  /// Whether the running match score is shown (the settings `showScoring`).
  final bool showScoring;

  /// What the score calls the non-local side. See [GameScreen.opponentLabel].
  final String opponentLabel;

  /// An extra qualifier for the opponent on row 2 — the AI difficulty ("Easy")
  /// where the caller knows it. Null (hot-seat, online, a bare test harness)
  /// simply drops that segment; the row keeps its height either way.
  final String? opponentDetail;

  /// Opens the Surrender sheet. Null only when NO side is locally human (an
  /// AI-vs-AI harness), which is the one case where the ⋮ has nothing to offer
  /// and is therefore disabled.
  final VoidCallback? onSurrender;

  /// Whether the header carries the Double button.
  ///
  /// False in the TABLETOP layout only. This header sits at one edge of a device
  /// two people share, but the button acts for whoever is on turn — so the
  /// player who is NOT on turn could double on their opponent's behalf simply by
  /// reaching over. There the verb belongs to the per-edge action bars, which
  /// are owner-gated; everywhere else exactly one human can be on turn at all,
  /// so the shared header is unambiguous and keeps it.
  final bool showDouble;

  /// Called just before the header's Double is submitted, so the screen can
  /// report it. The header has no analytics sink of its own — it is a
  /// presentation widget — and the screen owns the one that is injected.
  final VoidCallback? onDoubled;

  bool get _humanDeciding {
    if (controller.awaitingHumanTurn) return true;
    for (final side in [Player.white, Player.black]) {
      if (controller.isLocalHuman(side) &&
          (controller.pendingMoveOf(side).value != null ||
              controller.pendingCubeOf(side).value != null ||
              controller.pendingResignOf(side).value != null)) {
        return true;
      }
    }
    return false;
  }

  bool get _doublingLegal {
    if (controller.cubeless) return false;
    final s = controller.state;
    return !s.isCrawfordGame &&
        (s.cube.owner == null || s.cube.owner == s.turn);
  }

  /// Offers a double, re-checking AT INVOCATION the very condition the button's
  /// enabled-ness was built from.
  ///
  /// Same race, and the same reason, as the screen's own Roll handler: Double and
  /// Surrender share the pre-roll gate with Roll. The enabled-ness is baked into
  /// the last build, so two presses inside one frame both run the callback that
  /// frame captured while the match moves on underneath them.
  ///
  /// Unlike Roll, this re-checks BOTH halves of the precondition, because
  /// [MatchController.offerDouble] has two: the gate must be open AND doubling
  /// must be legal right now. Mirroring only the gate was not enough — a second
  /// press lands after the opponent has taken the cube, by which time the gate
  /// has reopened for the roll but the double is no longer on offer, and the
  /// throw comes from the legality check instead ("doubling is not legal now").
  /// Re-checking exactly `atGate && _doublingLegal` cannot drift from the
  /// button's own condition.
  void _offerDouble() {
    if (!controller.awaitingHumanTurn || !_doublingLegal) return;
    onDoubled?.call();
    controller.offerDouble();
  }

  /// One sentence explaining why a tap on the (disabled) Double button just
  /// did nothing — the one thing the button itself cannot say. Mirrors
  /// exactly the two halves of [_offerDouble]'s own guard, so it is only ever
  /// reached when at least one of them is false.
  String _doubleBlockedReason(bool atGate) {
    if (!atGate) return 'You can only double before rolling, on your turn.';
    final s = controller.state;
    if (s.isCrawfordGame) {
      return 'No doubling in the Crawford game — this single game decides '
          'the match.';
    }
    if (s.cube.owner != null && s.cube.owner != s.turn) {
      return 'Only the cube owner can double, and the other side owns it '
          'right now.';
    }
    return 'Doubling is not available right now.';
  }

  void _explainDoubleBlocked(BuildContext context, bool atGate) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 104, left: 12, right: 12),
        content: Text(_doubleBlockedReason(atGate)),
      ),
    );
  }

  /// Row 1's text: the match context — "You 1–0 AI · to 3 · Game 2", or just
  /// "Game 2" when the score is switched off.
  ///
  /// `gameNumber` is 0 until the first game starts, and the header is on screen
  /// from the first frame, so it reads "Game 1" rather than "Game 0".
  String _contextLine() {
    final number = controller.gameNumber < 1 ? 1 : controller.gameNumber;
    if (!showScoring) return 'Game $number';
    return '${_compactScore(controller, opponentLabel)} · Game $number';
  }

  /// Row 2's text: who is playing, and the live pip counts — "vs AI · Easy ·
  /// Pips 129–78".
  ///
  /// Named from the local player's point of view where there IS one (so the
  /// first pip count is always yours, matching the score's "You" first), and
  /// neutrally as "White vs Black" in hot-seat — where both sides are local and
  /// neither of them is "you" — and for a controller with no local side at all.
  /// Same rule as [_compactScore].
  ///
  /// Pip counts come from the COMMITTED board, so they step once per move rather
  /// than flickering through a half-entered turn.
  String _detailLine() {
    final board = controller.state.board;
    final white = board.pipCount(Player.white);
    final black = board.pipCount(Player.black);
    final localWhite = controller.isLocalHuman(Player.white);
    final localBlack = controller.isLocalHuman(Player.black);
    final soleLocal = localWhite != localBlack;
    final String who;
    final int mine;
    final int theirs;
    if (!soleLocal) {
      who = 'White vs Black';
      (mine, theirs) = (white, black);
    } else {
      who = 'vs $opponentLabel';
      (mine, theirs) = localWhite ? (white, black) : (black, white);
    }
    final detail = opponentDetail;
    return [
      who,
      if (detail != null && detail.isNotEmpty) detail,
      'Pips $mine–$theirs',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final cube = state.cube;
    final scheme = Theme.of(context).colorScheme;
    // The thinking dot reflects a genuine AI await, not a human's own decision
    // (the controller keeps `isThinking` true while it awaits a human move too).
    final showThinking = controller.isThinking && !_humanDeciding;
    // Double is only meaningful at the human's own pre-roll gate.
    final atGate = controller.awaitingHumanTurn;

    return Material(
      // Keyed so tests can scope an assertion to the HEADER.
      key: const ValueKey('hud'),
      color: scheme.surfaceContainerHighest,
      // Pinned rather than merely implied by the rows: the header's height is
      // half the screen's fixed layout budget, so it is stated once, here.
      child: SizedBox(
        height: _hudHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: 12, vertical: _verticalPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                key: const ValueKey('hudContextRow'),
                height: _row1Height,
                child: Row(
                  children: [
                    // The left group (context line, Crawford badge, cube chip)
                    // takes ALL the space the right-hand controls leave. A bare
                    // `Flexible` + `Spacer` split the free space evenly instead,
                    // which truncated the longer line to "You 0–1 AI · t…" on a
                    // phone.
                    //
                    // The group scales to fit as ONE unit rather than flexing
                    // the text alone: a clipped context line tells the player
                    // nothing, whereas a slightly smaller row still reads — and
                    // the badge and chip beside it are RIGID, so a flexing text
                    // could not absorb them. In a 1-point match (Crawford from
                    // the first roll) that rigid pair plus the line overflowed
                    // the row by a hair on a 390pt phone. Scaling the whole
                    // group can never overflow, at any width or text scale.
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Row(
                          // Unbounded inside the FittedBox: measured at natural
                          // size, then scaled — no child here may be Flexible.
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _contextLine(),
                              maxLines: 1,
                              softWrap: false,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            if (state.isCrawfordGame) ...[
                              const SizedBox(width: 8),
                              const _MiniBadge(
                                  icon: Icons.star, label: 'Crawford'),
                            ],
                            // The cube chip is hidden in a cubeless match.
                            if (!controller.cubeless) ...[
                              const SizedBox(width: 8),
                              _CubeChip(value: cube.value, owner: cube.owner),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (showThinking) ...[
                      const _ThinkingDot(),
                      const SizedBox(width: 8),
                    ],
                    // Omitted entirely in a cubeless match, and in the tabletop
                    // layout — where it is not the header's verb to offer, since
                    // the header is shared by two players and this button acts
                    // for whoever is on turn. It moves to the per-edge action
                    // bars instead (see [_GameScreenState._actionBar]).
                    if (!controller.cubeless && showDouble)
                      TapWhenDisabled(
                        onDisabledTap: () =>
                            _explainDoubleBlocked(context, atGate),
                        child: OutlinedButton.icon(
                          onPressed: atGate && _doublingLegal
                              ? _offerDouble
                              : null,
                          icon: const Icon(Icons.control_point_duplicate,
                              size: 16),
                          label: const Text('Double'),
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12),
                          ),
                        ),
                      ),
                    // ALWAYS enabled wherever a local human exists. Gating the
                    // whole ⋮ on the pre-roll gate hid the only way to concede a
                    // game at precisely the moments a losing player looks for
                    // it, which read as the feature not existing ("add surrender
                    // option" — of something that had shipped long before). The
                    // SHEET now owns the legality question and explains it; see
                    // [_GameScreenState._surrenderDialog].
                    PopupMenuButton<_MenuAction>(
                      icon: const Icon(Icons.more_vert),
                      tooltip: 'More actions',
                      enabled: onSurrender != null,
                      onSelected: (action) {
                        switch (action) {
                          case _MenuAction.surrender:
                            onSurrender!();
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: _MenuAction.surrender,
                          child: Text('Surrender…'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(
                key: const ValueKey('hudDetailRow'),
                height: _row2Height,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _detailLine(),
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small icon+label chip (e.g. the Crawford marker).
class _MiniBadge extends StatelessWidget {
  const _MiniBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: scheme.onSecondaryContainer),
          const SizedBox(width: 4),
          Text(label,
              style:
                  TextStyle(color: scheme.onSecondaryContainer, fontSize: 12)),
        ],
      ),
    );
  }
}

/// The doubling-cube chip: value plus the owner's initial (or centred when
/// nobody owns it).
class _CubeChip extends StatelessWidget {
  const _CubeChip({required this.value, required this.owner});

  final int value;
  final Player? owner;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final suffix = owner == null
        ? ''
        : ' ${owner == Player.white ? 'W' : 'B'}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text('×$value$suffix',
          style: TextStyle(color: scheme.onSecondaryContainer, fontSize: 12)),
    );
  }
}

/// A small static dot signalling the AI is thinking (a compact replacement for
/// the old "thinking…" chip). Deliberately not animated, so tests that
/// `pumpAndSettle` through AI turns are not blocked by a perpetual animation.
class _ThinkingDot extends StatelessWidget {
  const _ThinkingDot();

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Thinking',
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
