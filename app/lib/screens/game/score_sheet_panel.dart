import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';

import '../../board/board_theme.dart';
import '../../game/game_record.dart';
import '../../tutor/move_assessment.dart';

/// The always-visible two-column score sheet under the board.
///
/// Stateful for exactly one reason: it owns the row list's [ScrollController]
/// and the auto-pin bookkeeping behind it ([_ScoreSheetPanelState._scrolledRows]).
/// Everything it PRINTS arrives as values, folded once per event log by the
/// screen, so the rows are neither re-derived nor re-scanned here.
class ScoreSheetPanel extends StatefulWidget {
  const ScoreSheetPanel({
    super.key,
    required this.rows,
    required this.leftSide,
    required this.columnLabels,
    required this.assessments,
    required this.revealedBest,
    required this.onToggleBest,
  });

  /// Total height of the always-present score sheet. FIXED and unconditional,
  /// for the same reason as the action bar: the board FILLS the slot above it,
  /// so a panel that grew with its content (or came and went) would resize the
  /// board on every turn (F6).
  ///
  /// ## The screen's fixed-height budget
  ///
  /// Everything outside the board's slot is a constant for a given screen, so
  /// the board can never reflow mid-match:
  ///
  ///     header ([GameHud])              64  (40 + 18 + 2*3)
  ///     score sheet (this)             112
  ///     action bar                      64
  ///     tutor advice slot (tutor only)  28
  ///
  /// There are exactly TWO budgets, chosen once per screen and never changed
  /// afterwards, because every input to the tabletop layout (the mode, the
  /// orientation, the tabletop flag) is fixed for the life of the screen:
  ///
  ///     every mode but tabletop hot-seat   240 + 28 with a tutor
  ///     tabletop hot-seat                  304 + 28 with a tutor
  ///
  /// The extra 64 is the top player's action bar, which is mounted for the
  /// whole match rather than only on its owner's turn — that is what keeps the
  /// per-screen budget CONSTANT, and it is why the inactive bar is
  /// dimmed-and-disabled rather than removed.
  ///
  /// Round 6 rebalanced it: the header grew from one row to two (+8) while the
  /// standalone 20px pip line was deleted outright, so the board's slot GAINED
  /// 12px. Inside the unchanged 112px sheet, dropping its duplicate context line
  /// moved 18px from chrome to move rows (~5 rows visible, up from ~3). On a
  /// 390x844 phone the board's slot is ~568px (aspect ~0.69, inside the
  /// [BoardView.minAspect] clamp).
  static const double height = 112;

  /// The sheet's rows, folded from the event log by the caller (once per log).
  final List<ScoreSheetRow> rows;

  /// Which side owns the LEFT column.
  final Player leftSide;

  /// The two column labels, left first — "You"/"AI", or the neutral "W"/"B".
  final (String, String) columnLabels;

  /// Post-move assessments by event index; a cell with one gains a mark dot,
  /// an equity loss and a tap target.
  final Map<int, MoveAssessment> assessments;

  /// Event indices whose best-play line is currently revealed.
  final Set<int> revealedBest;

  /// Toggles the best-play line under an assessed cell.
  final void Function(int eventIndex) onToggleBest;

  @override
  State<ScoreSheetPanel> createState() => _ScoreSheetPanelState();
}

class _ScoreSheetPanelState extends State<ScoreSheetPanel> {
  /// Scroll controller for the row list, kept so it can auto-scroll to the
  /// newest row as live events append.
  final ScrollController _scroll = ScrollController();

  /// The number of RENDERED ROWS the sheet was last auto-scrolled for. A row
  /// appearing re-pins the list to the bottom; anything else leaves a user who
  /// scrolled up to re-read an earlier turn exactly where they are.
  ///
  /// Rows, not events: the two do not move together. A RollEvent adds no row at
  /// all (the roll is printed as a prefix on the move it produces), and a Black
  /// move joins the open row rather than starting one — so keying this on the
  /// event count yanked the list back down two or three times per exchange for
  /// content that had not moved, which is precisely when a reader is looking
  /// at it.
  int _scrolledRows = -1;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Height of the sheet's single header line (the two column labels).
  static const double _headerHeight = 16;

  /// Width of the turn-number gutter left of the two move columns, shared by the
  /// header's column labels and every row so the columns line up.
  static const double _gutter = 22;

  /// Horizontal inset of the sheet's rows and header.
  static const double _inset = 8;

  /// The ALWAYS-VISIBLE two-column score sheet, sitting between the board and
  /// the action bar. This replaced a 32px collapsed strip that expanded into a
  /// scrimmed overlay sheet — a design the reported feedback rejected outright
  /// ("move history still looks like a popup"). Nothing here opens or closes:
  /// the whole game so far is on screen, scrollable, at all times.
  ///
  /// Layout: a slim header (game number + match score, then the two column
  /// labels), a hairline, then a scrollable list of [buildScoreSheet] rows —
  /// numbered turn rows with one cell per side, and full-width span rows for the
  /// opening / cube / resignation events. Newest row at the BOTTOM, auto-pinned
  /// there as rows append (see [_scrolledRows] for how a manual scroll-up is
  /// respected).
  ///
  /// The caller mounts this behind its own revision notifier, so a rebuild here
  /// means a row (or a mark on one) actually moved — not that the dice tumbled.
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = widget.rows;
    // Re-pin to the newest row when a ROW appears, but not on any other rebuild
    // (a roll, a tutor assessment landing, a best-play line revealed) — so a
    // user who scrolled up to re-read turn 3 stays there until the sheet
    // actually grows. See [_scrolledRows].
    if (rows.length != _scrolledRows) {
      _scrolledRows = rows.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
    final leftSide = widget.leftSide;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: SizedBox(
        key: const ValueKey('scoreSheet'),
        height: ScoreSheetPanel.height,
        child: Column(
          children: [
            _header(leftSide),
            Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                        'No moves yet',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      key: const ValueKey('scoreSheetList'),
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      itemCount: rows.length,
                      itemBuilder: (context, i) =>
                          _row(rows[i], i, leftSide),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// The sheet's header: just the two column labels, aligned over the move
  /// columns.
  ///
  /// It used to carry a game/score context line above them ("Game 2 · You 1–0
  /// AI · to 3") — a verbatim duplicate of the header's own score, which is the
  /// "duplicate info" the reported feedback objected to. That line is gone and
  /// the HEADER is now the only place summary information lives; the sheet keeps
  /// its overall height and spends the reclaimed 18px on move rows instead.
  Widget _header(Player leftSide) {
    final scheme = Theme.of(context).colorScheme;
    final (left, right) = widget.columnLabels;
    final labelStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: scheme.onSurfaceVariant,
      letterSpacing: 0.3,
    );
    return SizedBox(
      key: const ValueKey('scoreSheetHeader'),
      height: _headerHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _inset),
        child: Row(
          children: [
            const SizedBox(width: _gutter),
            Expanded(child: Text(left, style: labelStyle)),
            const SizedBox(width: 6),
            Expanded(child: Text(right, style: labelStyle)),
          ],
        ),
      ),
    );
  }

  /// One sheet row: a numbered two-cell turn row, or a full-width span row.
  Widget _row(ScoreSheetRow row, int index, Player leftSide) =>
      switch (row) {
        ScoreSheetTurn() => _turnRow(row, index, leftSide),
        ScoreSheetSpan() => _spanRow(row, index),
      };

  /// A numbered turn row: the turn number in the gutter, then one equal-width
  /// cell per side (the left one being [leftSide]'s).
  Widget _turnRow(ScoreSheetTurn row, int index, Player leftSide) {
    final scheme = Theme.of(context).colorScheme;
    final left = row.cellFor(leftSide);
    final right = row.cellFor(leftSide.opponent);
    return Padding(
      key: ValueKey('sheetRow$index'),
      padding: const EdgeInsets.symmetric(horizontal: _inset, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _gutter,
            child: Text(
              '${row.number}.',
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(child: _cell(left, ValueKey('sheetLeft$index'))),
          const SizedBox(width: 6),
          Expanded(child: _cell(right, ValueKey('sheetRight$index'))),
        ],
      ),
    );
  }

  /// One move cell: an optional mark dot, the dice + notation, and the equity
  /// loss — e.g. a red dot, "66: 22/16 16/10 13/…", "−0.130". The dot and the
  /// number carry the verdict, so the mark WORD ("Blunder") is dropped here:
  /// there is no room for it in a ~180pt column, and the ⓘ explainer covers what
  /// the number means.
  ///
  /// The loss sits in its OWN inflexible slot at the end of the row rather than
  /// inside the notation's text run. As one ellipsized span the two competed for
  /// the same line, and a four-hop doubles play ("66: 22/16 16/10 13/7 13/7")
  /// always won — truncating the cell to "… 13/7 ·…" and eating the very number
  /// the cell exists to show. Now the NOTATION gives way instead, and the score
  /// is always legible.
  ///
  /// An assessed cell is tappable: it toggles a second "Best: …" line beneath
  /// the notation (the sheet scrolls, so the extra line costs the board nothing).
  /// An empty cell (the side has not moved this turn) renders as blank space.
  Widget _cell(ScoreCell? cell, Key key) {
    if (cell == null) return SizedBox(key: key);
    final scheme = Theme.of(context).colorScheme;
    final assessment = widget.assessments[cell.eventIndex];
    final revealed = widget.revealedBest.contains(cell.eventIndex);
    final base = TextStyle(
      fontSize: 12,
      color: scheme.onSurface,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    Color? markColor;
    String markLabel = '';
    String lossText = '';
    // A dance offers no choice, so grading it "best" is noise — no mark at all.
    if (assessment != null && assessment.ranked.isNotEmpty) {
      final (color, label) = _markStyle(assessment.mark);
      markColor = color;
      markLabel = label;
      final loss = assessment.equityLoss;
      // A best play has no number worth printing; the mark WORD carries it (and
      // the dot is already green). It is the mark word itself rather than a
      // lowercase copy of it, so the column and the dot's label cannot disagree
      // about their own casing — see below, where the dot then keeps quiet
      // rather than have a reader hear "Best … best".
      lossText = loss >= 0.001 ? '−${loss.toStringAsFixed(3)}' : label;
    }

    final line = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (markColor != null) ...[
          Padding(
            padding: const EdgeInsets.only(top: 4),
            // The dot carries the verdict in COLOUR, which is no verdict at all
            // to a screen reader (or to a colour-blind eye reading green against
            // amber). The mark word rides with it as the node's label — the
            // column has no room to print it, but nothing stops it being said.
            // Except on a best play, where the loss slot IS printing that word:
            // there the dot stays silent rather than echo the line beside it.
            child: Semantics(
              label: lossText == markLabel ? null : markLabel,
              child: Icon(Icons.circle, size: 8, color: markColor),
            ),
          ),
          const SizedBox(width: 3),
        ],
        Expanded(
          child: Text(
            cell.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: base,
          ),
        ),
        if (markColor != null) ...[
          const SizedBox(width: 4),
          Text(
            lossText,
            maxLines: 1,
            style: base.copyWith(
                color: markColor, fontWeight: FontWeight.w600),
          ),
        ],
      ],
    );

    if (assessment == null) return KeyedSubtree(key: key, child: line);

    return InkWell(
      key: key,
      onTap: () => widget.onToggleBest(cell.eventIndex),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          line,
          if (revealed && assessment.best.checkerMoves.isNotEmpty)
            Text(
              'Best: ${assessment.best}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: base.copyWith(
                  fontSize: 11, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  /// A full-width span row (the opening, a cube action, a resignation): an
  /// actor-tinted dot in the gutter, then the line across BOTH columns.
  Widget _spanRow(ScoreSheetSpan row, int index) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: ValueKey('sheetSpan$index'),
      padding: const EdgeInsets.symmetric(horizontal: _inset, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _gutter,
            child: row.actor == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: _actorDot(row.actor),
                  ),
          ),
          Expanded(
            child: Text(
              row.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Mark → (colour, label): best/good green, dubious amber, error orange,
  /// blunder red, and the single source of truth for the mark vocabulary. The
  /// label is never PRINTED in a cell (the dot plus the loss number is all that
  /// fits in a ~180pt column) but it is what the dot's semantics node says, so
  /// the verdict is not colour-only.
  (Color, String) _markStyle(MoveMark mark) => switch (mark) {
        MoveMark.best => (Colors.green.shade700, 'Best'),
        MoveMark.good => (Colors.green.shade600, 'Good'),
        MoveMark.dubious => (Colors.amber.shade800, 'Dubious'),
        MoveMark.error => (Colors.orange.shade800, 'Error'),
        MoveMark.blunder => (Colors.red.shade700, 'Blunder'),
      };

  /// A small leading dot in the actor's checker colour (ivory for White, ebony
  /// for Black), or an empty transparent slot for a neutral line (the opening).
  Widget _actorDot(Player? actor) {
    if (actor == null) return const SizedBox(width: 10, height: 10);
    final isWhite = actor == Player.white;
    final color =
        isWhite ? BoardTheme.light.whiteChecker : BoardTheme.light.blackChecker;
    final border = isWhite
        ? BoardTheme.light.whiteCheckerBorder
        : BoardTheme.light.blackCheckerBorder;
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: border, width: 1),
      ),
    );
  }
}
