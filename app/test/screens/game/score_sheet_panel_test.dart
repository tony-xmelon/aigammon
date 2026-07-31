import 'package:aigammon_app/game/game_record.dart';
import 'package:aigammon_app/screens/game/score_sheet_panel.dart';
import 'package:aigammon_app/tutor/move_assessment.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A played move with [loss] equity given up. The ranking only has to be
/// NON-empty — an assessed cell is one with candidates behind it.
MoveAssessment _assessment(double loss) {
  final played = Move(const [CheckerMove(7, 4), CheckerMove(5, 4)]);
  return MoveAssessment(
    played: played,
    best: played,
    equityLoss: loss,
    ranked: [
      ScoredMove(
        move: played,
        probabilities: const Probabilities(
          win: 0.5,
          winGammon: 0.1,
          winBackgammon: 0.0,
          loseGammon: 0.1,
          loseBackgammon: 0.0,
        ),
      ),
    ],
  );
}

void main() {
  Widget panel(MoveAssessment assessment) => MaterialApp(
        home: Scaffold(
          body: ScoreSheetPanel(
            rows: const [
              ScoreSheetTurn(1,
                  white: ScoreCell(
                      text: '31: 8/5 6/5', actor: Player.white, eventIndex: 1)),
            ],
            leftSide: Player.white,
            columnLabels: const ('You', 'AI'),
            assessments: {1: assessment},
            revealedBest: const {},
            onToggleBest: (_) {},
          ),
        ),
      );

  // The mark dot speaks its verdict, because on screen the verdict is a colour
  // and nothing else. Where the loss slot has a number, the two say different
  // things and both are worth hearing.
  testWidgets('an assessed cell says its mark AND its loss', (t) async {
    final handle = t.ensureSemantics();
    await t.pumpWidget(panel(_assessment(0.06)));
    await t.pump();

    final cell = t.getSemantics(find.byKey(const ValueKey('sheetLeft0')));
    expect(cell.label, contains('Error'));
    expect(cell.label, contains('−0.060'));

    handle.dispose();
  });

  // A best play has no number, so the loss slot PRINTS the mark word instead —
  // and the dot then keeps quiet. Said twice it came out as "Best … best": the
  // same verdict, twice, in two different casings.
  testWidgets('a best play names its mark once, not twice', (t) async {
    final handle = t.ensureSemantics();
    await t.pumpWidget(panel(_assessment(0.0)));
    await t.pump();

    expect(find.text('Best'), findsOneWidget,
        reason: 'the printed word matches the mark word, casing included');
    expect(find.text('best'), findsNothing);

    final cell = t.getSemantics(find.byKey(const ValueKey('sheetLeft0')));
    expect('Best'.allMatches(cell.label).length, 1,
        reason: 'the dot does not echo the word the column already prints');

    handle.dispose();
  });
}
