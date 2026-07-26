import 'dart:math' as math;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/widgets.dart';

import 'board_geometry.dart';
import 'board_theme.dart';

/// Renders a [BoardState] (plus optional dice, cube, and interaction
/// highlights) using a [BoardGeometry] for placement and a [BoardTheme] for
/// colours. Purely declarative: give it inputs, it paints; [shouldRepaint]
/// compares every input so it only repaints on a real change.
class BoardPainter extends CustomPainter {
  BoardPainter({
    required this.board,
    required this.geometry,
    required this.theme,
    this.whiteDice,
    this.blackDice,
    this.diceMover,
    this.cube,
    this.highlightedSources = const {},
    this.highlightedDestinations = const {},
    this.combinedDestinations = const {},
    this.selectedCheckerLocation,
    this.strongHighlightLocations = const {},
    this.movingPlayer,
    this.hiddenChecker,
    this.overlayChecker,
    this.diceTapHint = false,
    this.usedDiceSlots = const {},
  });

  final BoardState board;
  final BoardGeometry geometry;
  final BoardTheme theme;

  /// The most recent roll to persist on WHITE's dice pair (white bodies, dark
  /// pips), or `null` when White has not rolled yet this game (a blank dimmed
  /// outline is drawn). Persists across turns so the opponent's roll stays
  /// visible after the turn passes.
  final Dice? whiteDice;

  /// The most recent roll to persist on BLACK's dice pair (dark bodies, light
  /// pips), or `null` when Black has not rolled yet this game.
  final Dice? blackDice;

  /// The side currently to move: its pair renders in the right half at full
  /// opacity; the waiting side's pair renders in the mirrored left half, dimmed.
  /// Defaults to [Player.white] when `null` (a bare display board).
  final Player? diceMover;

  final CubeState? cube;

  /// Selectable (but not-yet-picked-up) sources: each renders as a subtle ring
  /// around its TOP CHECKER (point index 0..23, or [CheckerMove.bar]).
  final Set<int> highlightedSources;

  /// Legal destinations for the picked-up source: each renders as a uniform
  /// highlight on the target TRIANGLE (point index 0..23, or [CheckerMove.off]
  /// for the bear-off strip).
  final Set<int> highlightedDestinations;

  /// Landing points of COMBINED (multi-hop, same-checker) moves for the
  /// picked-up source: each renders as a DIMMER (reduced-opacity) variant of the
  /// destination highlight, so a tap there enters the whole chain. Disjoint from
  /// [highlightedDestinations] (the caller subtracts the direct set); if a point
  /// appears in both, the bright direct highlight wins. Empty by default, in
  /// which case painting is byte-identical to the un-extended path.
  final Set<int> combinedDestinations;

  /// The picked-up source whose TOP CHECKER wears the bright selection ring:
  /// a point index 0..23, or [CheckerMove.bar]. `null` when nothing is picked
  /// up. Anchoring the highlight to the checker (not the triangle) means a
  /// beaten checker resting on the bar highlights just like any other.
  final int? selectedCheckerLocation;

  /// Locations whose top checker wears the SAME bright selection ring as
  /// [selectedCheckerLocation], as a SET.
  ///
  /// Live move entry picks up one checker at a time, so it uses the single
  /// [selectedCheckerLocation]. A recorded move's overlay (the analysis screen's
  /// Played/Best board) has to mark every ORIGIN of a play that may move two or
  /// three different checkers, and the user asked for those origins to wear the
  /// strong yellow ring rather than the thin "could be picked up" source ring —
  /// hence a set. Painted identically to the selection ring; empty by default,
  /// in which case painting is byte-identical to the un-extended path.
  final Set<int> strongHighlightLocations;

  /// The side to move, used only to resolve WHICH bar half a bar source/selection
  /// refers to (both players may have checkers on the bar at once). Required for
  /// a bar ring to render; ignored for point sources.
  final Player? movingPlayer;

  /// A single checker to SUPPRESS while it travels as [overlayChecker] during a
  /// move animation: the [stackIndex]-th checker at [location] (a point index
  /// 0..23, or [CheckerMove.bar]) belonging to [isWhite]. `null` when nothing is
  /// hidden — in which case painting is byte-identical to the un-extended path.
  final ({int location, int stackIndex, bool isWhite})? hiddenChecker;

  /// A checker to draw on top of everything at [center] during a move animation
  /// (the travelling piece). `null` when idle.
  final ({Offset center, bool isWhite})? overlayChecker;

  /// Whether to ring the [diceMover]'s dice pair as a "tap here to roll"
  /// affordance. Set only while the board actually accepts a dice tap (the
  /// local player's pre-roll gate); `false` otherwise, in which case painting is
  /// byte-identical to the un-extended path.
  final bool diceTapHint;

  /// Slots of the MOVER's dice pair already consumed by the hops staged so far
  /// (slot 0 is `dice.die1`, slot 1 is `dice.die2`), rendered heavily dimmed so
  /// a played die reads as spent. Empty outside move entry — and after an Undo,
  /// which restores the die to full brightness. See `dice_usage.dart` for how
  /// hops are mapped back onto slots.
  final Set<int> usedDiceSlots;

  @override
  void paint(Canvas canvas, Size size) {
    _paintBackground(canvas, size);
    _paintTriangles(canvas);
    _paintOffDestination(canvas);
    _paintBar(canvas);
    _paintPointCheckers(canvas);
    _paintBarCheckers(canvas);
    _paintOffTrays(canvas);
    // Selection rings ride ABOVE the checkers so they read as haloes, never
    // hidden behind the discs.
    _paintSelectionRings(canvas);
    _paintDice(canvas);
    if (cube != null) _paintCube(canvas);
    // The travelling checker rides above every static checker/tray.
    final overlay = overlayChecker;
    if (overlay != null) _drawChecker(canvas, overlay.center, overlay.isWhite);
  }

  /// Whether the [s]-th checker of [isWhite] at point/bar [location] is the one
  /// currently hidden (lifted into the travelling [overlayChecker]).
  bool _isHidden(int location, int s, bool isWhite) {
    final h = hiddenChecker;
    return h != null &&
        h.location == location &&
        h.stackIndex == s &&
        h.isWhite == isWhite;
  }

  // --- Board furniture -------------------------------------------------------

  void _paintBackground(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = theme.boardColor);
    // The rail's thickness is the geometry's, so the playing field it insets
    // for and the band actually painted can never drift apart.
    final border = geometry.frameThickness;
    canvas.drawRect(
      rect.deflate(border / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = border
        ..color = theme.barColor,
    );
  }

  void _paintTriangles(Canvas canvas) {
    for (var i = 0; i < 24; i++) {
      final rect = geometry.pointRect(i);
      final baseAtBottom =
          geometry.whiteAtBottom ? i < 12 : i >= 12;
      final baseY = baseAtBottom ? rect.bottom : rect.top;
      final apexY = baseAtBottom ? rect.top : rect.bottom;
      final path = Path()
        ..moveTo(rect.left, baseY)
        ..lineTo(rect.right, baseY)
        ..lineTo(rect.center.dx, apexY)
        ..close();
      final color = i.isEven ? theme.pointDark : theme.pointLight;
      canvas.drawPath(path, Paint()..color = color);

      // A direct destination wins over a combined landing when both apply.
      if (highlightedDestinations.contains(i)) {
        _paintDestinationTriangle(canvas, path);
      } else if (combinedDestinations.contains(i)) {
        _paintCombinedTriangle(canvas, path);
      }
    }
  }

  /// Paints a destination highlight whose resulting pixels do NOT depend on the
  /// underlying point colour: an OPAQUE uniform fill (which fully neutralises the
  /// dark/light point beneath) topped by an opaque edge ring. Because the fill
  /// is opaque, a highlighted destination is pixel-identical over both point
  /// colours — the user's "different colours on white and red" complaint.
  void _paintDestinationTriangle(Canvas canvas, Path path) {
    canvas.drawPath(path, Paint()..color = theme.highlightDestinationFill);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = geometry.checkerRadius * 0.22
        ..color = theme.highlightDestination,
    );
  }

  /// Combined-move landing: a DIMMER variant of the direct destination
  /// highlight — the same green fill + ring at reduced opacity — so it reads as
  /// "reachable by playing both dice with this checker" without competing with
  /// the bright single-hop targets.
  void _paintCombinedTriangle(Canvas canvas, Path path) {
    canvas.drawPath(
        path,
        Paint()
          ..color = theme.highlightDestinationFill.withValues(alpha: 0.42));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = geometry.checkerRadius * 0.18
        ..color = theme.highlightDestination.withValues(alpha: 0.55),
    );
  }

  /// Highlights the moving player's bear-off strip when `off` is a destination,
  /// using the SAME opaque fill + ring as the triangle destinations so it reads
  /// uniformly. No-op unless [movingPlayer] is known.
  void _paintOffDestination(Canvas canvas) {
    final player = movingPlayer;
    if (player == null) return;
    final direct = highlightedDestinations.contains(CheckerMove.off);
    final combined = !direct && combinedDestinations.contains(CheckerMove.off);
    if (!direct && !combined) return;
    final tray = geometry.offRect(player);
    final fillAlpha = combined ? 0.42 : 1.0;
    final ringAlpha = combined ? 0.55 : 1.0;
    canvas.drawRect(tray,
        Paint()..color = theme.highlightDestinationFill.withValues(alpha: fillAlpha));
    canvas.drawRect(
      tray.deflate(geometry.checkerRadius * 0.11),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = geometry.checkerRadius * (combined ? 0.18 : 0.22)
        ..color = theme.highlightDestination.withValues(alpha: ringAlpha),
    );
  }

  // --- Selection rings (checker-anchored) ------------------------------------

  /// Draws the checker-anchored selection haloes ABOVE all checkers: a subtle
  /// ring on every selectable source's top checker, and a bright glowing ring on
  /// the picked-up source's top checker.
  void _paintSelectionRings(Canvas canvas) {
    for (final loc in highlightedSources) {
      final c = _topCheckerCenter(loc);
      if (c != null) _drawSourceRing(canvas, c);
    }
    // The strong ring set (a recorded move's origins) is painted with exactly
    // the live selection's ring, so "this is the checker that moves" reads the
    // same on the analysis board as it does mid-turn.
    for (final loc in strongHighlightLocations) {
      final c = _topCheckerCenter(loc);
      if (c != null) _drawSelectedRing(canvas, c);
    }
    final sel = selectedCheckerLocation;
    if (sel != null) {
      final c = _topCheckerCenter(sel);
      if (c != null) _drawSelectedRing(canvas, c);
    }
  }

  /// Centre of the TOP checker resting at [location] (a point index 0..23 or
  /// [CheckerMove.bar]) on the current [board]. `null` when the location holds
  /// no checker, or when a bar location is queried without a [movingPlayer].
  Offset? _topCheckerCenter(int location) {
    if (location == CheckerMove.bar) {
      final player = movingPlayer;
      if (player == null) return null;
      final n = board.barFor(player);
      if (n == 0) return null;
      return geometry.barCheckerCenter(player, n - 1, n);
    }
    if (location < 0 || location >= 24) return null;
    final count = board.points[location].abs();
    if (count == 0) return null;
    return geometry.checkerCenter(location, count - 1, count);
  }

  /// Subtle halo on a selectable-but-unpicked source's top checker.
  void _drawSourceRing(Canvas canvas, Offset center) {
    final r = geometry.checkerRadius;
    canvas.drawCircle(
      center,
      r * 1.06,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.13
        ..color = theme.highlightSource,
    );
  }

  /// Bright glowing halo on the picked-up source's top checker.
  void _drawSelectedRing(Canvas canvas, Offset center) {
    final r = geometry.checkerRadius;
    // Soft outer glow.
    canvas.drawCircle(
      center,
      r * 1.24,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.46
        ..color = theme.selectedOutline.withValues(alpha: 0.30),
    );
    // Crisp bright ring.
    canvas.drawCircle(
      center,
      r * 1.14,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.22
        ..color = theme.selectedOutline,
    );
  }

  void _paintBar(Canvas canvas) {
    final rect = geometry.barRect(Player.white).expandToInclude(
          geometry.barRect(Player.black),
        );
    canvas.drawRect(rect, Paint()..color = theme.barColor);
  }

  // --- Checkers --------------------------------------------------------------

  void _paintPointCheckers(Canvas canvas) {
    for (var i = 0; i < 24; i++) {
      final count = board.points[i];
      if (count == 0) continue;
      final isWhite = count > 0;
      final n = count.abs();
      for (var s = 0; s < n; s++) {
        if (_isHidden(i, s, isWhite)) continue;
        _drawChecker(canvas, geometry.checkerCenter(i, s, n), isWhite);
      }
      if (n > 5) {
        _drawCountLabel(canvas, geometry.checkerCenter(i, n - 1, n), n, isWhite);
      }
    }
  }

  void _paintBarCheckers(Canvas canvas) {
    for (final player in Player.values) {
      final n = board.barFor(player);
      final isWhite = player == Player.white;
      for (var s = 0; s < n; s++) {
        if (_isHidden(CheckerMove.bar, s, isWhite)) continue;
        _drawChecker(canvas, geometry.barCheckerCenter(player, s, n), isWhite);
      }
      if (n > 5) {
        _drawCountLabel(
            canvas, geometry.barCheckerCenter(player, n - 1, n), n, isWhite);
      }
    }
  }

  void _drawChecker(Canvas canvas, Offset center, bool isWhite) {
    final r = geometry.checkerRadius;
    // Per-player rim: a light checker gets a dark rim, a dark checker a light
    // rim, so the silhouette reads on any surface (the contrast-matrix guard).
    final rim = isWhite ? theme.whiteCheckerBorder : theme.blackCheckerBorder;
    canvas.drawCircle(
      center,
      r,
      Paint()..color = isWhite ? theme.whiteChecker : theme.blackChecker,
    );
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.15
        ..color = rim,
    );
    // Inner ring for a little depth.
    canvas.drawCircle(
      center,
      r * 0.62,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.08
        ..color = rim.withValues(alpha: 0.35),
    );
  }

  void _drawCountLabel(Canvas canvas, Offset center, int count, bool isWhite) {
    _outlinedText(
      canvas,
      '$count',
      center,
      geometry.checkerRadius * 1.05,
      isWhite ? theme.blackChecker : theme.whiteChecker,
      isWhite ? theme.whiteChecker : theme.blackChecker,
      bold: true,
    );
  }

  // --- Bear-off trays --------------------------------------------------------

  /// Draws a player's borne-off checkers as a horizontal row of discs from the
  /// tray strip's leading (left) edge, with an outlined count at the trailing
  /// (right) end. Discs compress horizontally if 15 would overflow the row.
  void _paintOffTrays(Canvas canvas) {
    for (final player in Player.values) {
      final n = board.offFor(player);
      if (n == 0) continue;
      final tray = geometry.offRect(player);
      final isWhite = player == Player.white;
      // A borne-off disc scales with the strip, but never grows PAST a board
      // checker — on a tall (portrait) board the strip is the roomier of the
      // two, and a tray full of oversized checkers reads as a different piece.
      final r = math.min(tray.height * 0.38, geometry.checkerRadius);
      final cy = tray.center.dy;
      final pad = tray.height * 0.28;
      // Reserve a slot at the trailing end for the count text.
      final textW = tray.height * 1.1;
      final rowLeft = tray.left + pad + r;
      final rowRight = tray.right - pad - textW - r;
      final avail = math.max(0.0, rowRight - rowLeft);
      final step = n > 1 ? math.min(_off2r(r), avail / (n - 1)) : 0.0;
      final disc = Paint()
        ..color = isWhite ? theme.whiteChecker : theme.blackChecker;
      final border = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.16
        ..color = isWhite ? theme.whiteCheckerBorder : theme.blackCheckerBorder;
      for (var s = 0; s < n; s++) {
        final c = Offset(rowLeft + step * s, cy);
        canvas.drawCircle(c, r, disc);
        canvas.drawCircle(c, r, border);
      }
      // Outlined count at the trailing end: light fill, contrasting outline so
      // it reads clearly whether it sits over felt or over a disc.
      _outlinedText(
        canvas,
        '$n',
        Offset(tray.right - pad - textW / 2, cy),
        tray.height * 0.62,
        theme.whiteChecker,
        theme.blackChecker,
        bold: true,
      );
    }
  }

  /// Full-diameter spacing for the tray discs.
  double _off2r(double r) => r * 2;

  // --- Dice ------------------------------------------------------------------

  /// Paints BOTH players' persistent dice pairs: the WHITE pair (white bodies,
  /// dark pips) and the BLACK pair (dark bodies, light pips). Each pair carries a
  /// per-player rim (the same inverted-rim rule as the checkers) so it reads on
  /// the felt. The [diceMover]'s pair is full-opacity in the right half; the
  /// waiting pair is dimmed in the mirrored left half. A pair with no roll yet
  /// this game renders as blank dimmed outlines (no pips).
  void _paintDice(Canvas canvas) {
    final mover = diceMover ?? Player.white;
    if (diceTapHint) _paintDiceTapHint(canvas, mover);
    _paintPlayerDice(canvas, Player.white, whiteDice, mover);
    _paintPlayerDice(canvas, Player.black, blackDice, mover);
  }

  /// The pre-roll "tap to roll" affordance: a soft glow plus a crisp rounded
  /// ring around the MOVER's dice pair, drawn UNDER the dice themselves so it
  /// reads as a halo rather than a frame over the pips. Deliberately quiet —
  /// the Roll button remains the primary, discoverable control.
  void _paintDiceTapHint(Canvas canvas, Player mover) {
    final rect = geometry.diceRect(mover, mover: mover);
    final pad = geometry.diceSide * 0.28;
    final halo = RRect.fromRectXY(
      rect.inflate(pad),
      geometry.diceSide * 0.34,
      geometry.diceSide * 0.34,
    );
    canvas.drawRRect(
      halo,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = geometry.diceSide * 0.24
        ..color = theme.selectedOutline.withValues(alpha: 0.22),
    );
    canvas.drawRRect(
      halo,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = geometry.diceSide * 0.07
        ..color = theme.selectedOutline.withValues(alpha: 0.85),
    );
  }

  /// Alpha applied to the WAITING player's dice so the mover's pair reads as the
  /// live roll while the opponent's persisted roll stays legible beneath it.
  static const double _waitingDiceOpacity = 0.6;

  /// Alpha applied to a die of the MOVER's pair that the staged hops have
  /// already consumed. Deliberately below [_waitingDiceOpacity]: a spent die
  /// must read as *disabled*, not merely as "not your turn".
  static const double _usedDiceOpacity = 0.28;

  void _paintPlayerDice(
      Canvas canvas, Player player, Dice? dice, Player mover) {
    final rect = geometry.diceRect(player, mover: mover);
    final side = geometry.diceSide;
    final gap = side * 0.5;
    final c = rect.center;
    final first = Offset(c.dx - (side + gap) / 2, c.dy);
    final second = Offset(c.dx + (side + gap) / 2, c.dy);
    final isWhite = player == Player.white;
    // WHITE pair: white checker body + dark pips; BLACK pair: dark body + light
    // pips. The rim is the checker's inverted per-player border, so a die's
    // silhouette clears the felt exactly as its checker does.
    final body = isWhite ? theme.whiteChecker : theme.blackChecker;
    final pip = isWhite ? theme.blackChecker : theme.whiteChecker;
    final rim = isWhite ? theme.whiteCheckerBorder : theme.blackCheckerBorder;
    final dim = player == mover ? 1.0 : _waitingDiceOpacity;
    // A die the mover has already played out is dimmed further still. Only the
    // mover's own pair can carry played dice (the waiting pair is a memento).
    double slot(int index) => (player == mover && usedDiceSlots.contains(index))
        ? _usedDiceOpacity
        : dim;
    _drawDie(canvas, first, side, dice?.die1, body, pip, rim, slot(0));
    _drawDie(canvas, second, side, dice?.die2, body, pip, rim, slot(1));
  }

  void _drawDie(Canvas canvas, Offset center, double side, int? value,
      Color body, Color pip, Color rim, double dim) {
    Color d(Color c) => dim >= 1.0 ? c : c.withValues(alpha: c.a * dim);
    final rect = Rect.fromCenter(center: center, width: side, height: side);
    final rr = RRect.fromRectXY(rect, side * 0.18, side * 0.18);
    canvas.drawRRect(rr, Paint()..color = d(body));
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = side * 0.08
        ..color = d(rim),
    );
    if (value == null) return; // no roll yet: a blank outlined die
    final pipR = side * 0.09;
    final pipPaint = Paint()..color = d(pip);
    // 3x3 grid coordinates.
    final l = center.dx - side * 0.26;
    final m = center.dx;
    final rgt = center.dx + side * 0.26;
    final t = center.dy - side * 0.26;
    final mid = center.dy;
    final b = center.dy + side * 0.26;
    final pips = <Offset>[
      if (value.isOdd) Offset(m, mid), // centre pip for 1,3,5
      if (value >= 2) ...[Offset(l, t), Offset(rgt, b)],
      if (value >= 4) ...[Offset(rgt, t), Offset(l, b)],
      if (value == 6) ...[Offset(l, mid), Offset(rgt, mid)],
    ];
    for (final p in pips) {
      canvas.drawCircle(p, pipR, pipPaint);
    }
  }

  // --- Doubling cube ---------------------------------------------------------

  void _paintCube(Canvas canvas) {
    final c = cube!;
    final side = geometry.checkerRadius * 2.1;
    final barRect = geometry.barRect(Player.white);
    final barCx = (barRect.left + barRect.right) / 2;
    final midY = size().height / 2;
    final Offset center;
    if (c.owner == null) {
      center = Offset(barCx, midY);
    } else {
      // Nudge the owned cube along the bar toward its owner's half so ownership
      // reads at a glance (bottom half = local-bottom player), staying clear of
      // the resting bar checkers that pile from the outer ends.
      final ownerAtBottom = geometry.barRect(c.owner!).center.dy > midY;
      center = Offset(barCx, midY + (ownerAtBottom ? side : -side));
    }
    final rect = Rect.fromCenter(center: center, width: side, height: side);
    final rr = RRect.fromRectXY(rect, side * 0.18, side * 0.18);
    canvas.drawRRect(rr, Paint()..color = theme.cubeColor);
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = side * 0.05
        ..color = theme.dicePipColor.withValues(alpha: 0.6),
    );
    _drawText(canvas, '${c.value}', center, side * 0.5, theme.dicePipColor,
        bold: true);
  }

  Size size() => geometry.size;

  // --- Text helper -----------------------------------------------------------

  void _drawText(Canvas canvas, String text, Offset center, double fontSize,
      Color color,
      {bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      center - Offset(tp.width / 2, tp.height / 2),
    );
  }

  /// Draws [text] centred at [center] with a [fill] over a contrasting [outline]
  /// stroke, so the glyphs stay legible over checkers or felt. Painted twice:
  /// the stroke pass first, the fill on top.
  void _outlinedText(Canvas canvas, String text, Offset center, double fontSize,
      Color fill, Color outline,
      {bool bold = false}) {
    final weight = bold ? FontWeight.bold : FontWeight.normal;
    final strokeWidth = math.max(1.0, fontSize * 0.14);
    final stroke = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: weight,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..strokeJoin = StrokeJoin.round
            ..color = outline,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final fillTp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: fill, fontSize: fontSize, fontWeight: weight),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final origin = center - Offset(fillTp.width / 2, fillTp.height / 2);
    stroke.paint(canvas, origin);
    fillTp.paint(canvas, origin);
  }

  @override
  bool shouldRepaint(BoardPainter old) {
    return old.board != board ||
        old.geometry.size != geometry.size ||
        old.geometry.whiteAtBottom != geometry.whiteAtBottom ||
        !identical(old.theme, theme) ||
        old.whiteDice != whiteDice ||
        old.blackDice != blackDice ||
        old.diceMover != diceMover ||
        old.cube != cube ||
        old.selectedCheckerLocation != selectedCheckerLocation ||
        old.movingPlayer != movingPlayer ||
        old.hiddenChecker != hiddenChecker ||
        old.overlayChecker != overlayChecker ||
        old.diceTapHint != diceTapHint ||
        !setEquals(old.usedDiceSlots, usedDiceSlots) ||
        !setEquals(old.strongHighlightLocations, strongHighlightLocations) ||
        !setEquals(old.highlightedSources, highlightedSources) ||
        !setEquals(old.highlightedDestinations, highlightedDestinations) ||
        !setEquals(old.combinedDestinations, combinedDestinations);
  }
}
