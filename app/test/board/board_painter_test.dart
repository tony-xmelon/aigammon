// Golden comparisons are platform-locked: the PNGs were generated on the
// Windows dev machine, and Linux CI antialiasing drifts by <0.1%. CI
// excludes this tag (flutter test -x golden); run locally without flags.
@Tags(['golden'])
library;

import 'package:aigammon_app/board/board_geometry.dart';
import 'package:aigammon_app/board/board_painter.dart';
import 'package:aigammon_app/board/board_theme.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _size = Size(800, 600);

/// A PORTRAIT board: 450 wide at [BoardView.minAspect] (0.62), i.e. the exact
/// shape [BoardView] hands the geometry on a phone in portrait, scaled up so
/// the golden is readable. Guards the tall-board metrics — checkers sized by
/// the column width, triangle length capped, dice grown into the roomier
/// middle band — which the landscape goldens above can never exercise.
const _portrait = Size(450, 726);

Widget _harness(BoardPainter painter, [Size size = _size]) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: RepaintBoundary(
          child: CustomPaint(size: size, painter: painter),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('golden: initial position, light theme, white bottom', (t) async {
    await t.binding.setSurfaceSize(_size);
    final geometry = BoardGeometry(_size, whiteAtBottom: true);
    final painter = BoardPainter(
      board: BoardState.initial(),
      geometry: geometry,
      theme: BoardTheme.light,
      // Both persistent pairs: White (mover, right, bright) and Black (waiting,
      // left, dimmed) each show a roll so the two pairs are visibly distinct.
      whiteDice: Dice(3, 1),
      blackDice: Dice(5, 4),
      diceMover: Player.white,
      cube: const CubeState.initial(),
    );
    await t.pumpWidget(_harness(painter));
    await expectLater(
      find.byType(RepaintBoundary),
      matchesGoldenFile('goldens/initial_light.png'),
    );
  });

  testWidgets('golden: mid-game, dark theme, bars/off/highlights/cube',
      (t) async {
    await t.binding.setSurfaceSize(_size);
    final board = BoardState(
      points: const [
        2, 0, 0, 0, 0, 6, // White 6-stack on index 5
        0, 3, 0, 0, 0, 0,
        2, 0, 0, 0, -4, 0,
        -3, 0, 0, 0, 0, -2,
      ],
      whiteBar: 1,
      blackBar: 2,
      whiteOff: 1,
      blackOff: 4,
    );
    final geometry = BoardGeometry(_size, whiteAtBottom: true);
    final painter = BoardPainter(
      board: board,
      geometry: geometry,
      theme: BoardTheme.dark,
      // White is the mover (bright, right); Black's pair persists dimmed (left).
      whiteDice: Dice(6, 4),
      blackDice: Dice(2, 5),
      diceMover: Player.white,
      cube: const CubeState(value: 2, owner: Player.black),
      // Showcases every highlight type at once: subtle source rings on the two
      // selectable sources' top checkers, uniform green destination triangles,
      // and the bright selected ring on White's BEATEN checker resting on the
      // bar (the beaten-chip-highlight fix).
      highlightedSources: const {5, 7},
      highlightedDestinations: const {2, 3},
      selectedCheckerLocation: CheckerMove.bar,
      movingPlayer: Player.white,
    );
    await t.pumpWidget(_harness(painter));
    await expectLater(
      find.byType(RepaintBoundary),
      matchesGoldenFile('goldens/midgame_dark.png'),
    );
  });

  testWidgets('golden: initial position, light theme, PORTRAIT board',
      (t) async {
    await t.binding.setSurfaceSize(_portrait);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final geometry = BoardGeometry(_portrait, whiteAtBottom: true);
    final painter = BoardPainter(
      board: BoardState.initial(),
      geometry: geometry,
      theme: BoardTheme.light,
      whiteDice: Dice(3, 1),
      blackDice: Dice(5, 4),
      diceMover: Player.white,
      cube: const CubeState.initial(),
    );
    await t.pumpWidget(_harness(painter, _portrait));
    await expectLater(
      find.byType(RepaintBoundary),
      matchesGoldenFile('goldens/initial_light_portrait.png'),
    );
  });

  test('shouldRepaint reacts to every input', () {
    BoardPainter make({
      BoardState? board,
      BoardTheme? theme,
      Dice? whiteDice,
      Dice? blackDice,
      Player? diceMover,
      CubeState? cube,
      Set<int> src = const {},
      Set<int> dst = const {},
      Set<int> combined = const {},
      int? sel,
      Player? mover,
      bool whiteAtBottom = true,
    }) =>
        BoardPainter(
          board: board ?? BoardState.initial(),
          geometry: BoardGeometry(_size, whiteAtBottom: whiteAtBottom),
          theme: theme ?? BoardTheme.light,
          whiteDice: whiteDice,
          blackDice: blackDice,
          diceMover: diceMover,
          cube: cube,
          highlightedSources: src,
          highlightedDestinations: dst,
          combinedDestinations: combined,
          selectedCheckerLocation: sel,
          movingPlayer: mover,
        );

    final base = make();
    expect(base.shouldRepaint(make()), isFalse);
    expect(base.shouldRepaint(make(theme: BoardTheme.dark)), isTrue);
    expect(base.shouldRepaint(make(whiteDice: Dice(2, 2))), isTrue);
    expect(base.shouldRepaint(make(blackDice: Dice(2, 2))), isTrue);
    expect(base.shouldRepaint(make(diceMover: Player.white)), isTrue);
    expect(
        base.shouldRepaint(make(cube: const CubeState.initial())), isTrue);
    expect(base.shouldRepaint(make(src: const {1})), isTrue);
    expect(base.shouldRepaint(make(dst: const {2})), isTrue);
    expect(base.shouldRepaint(make(combined: const {4})), isTrue);
    expect(base.shouldRepaint(make(sel: 3)), isTrue);
    expect(base.shouldRepaint(make(mover: Player.white)), isTrue);
    expect(base.shouldRepaint(make(whiteAtBottom: false)), isTrue);
    expect(
        base.shouldRepaint(make(
            board: BoardState(points: List.filled(24, 0)))),
        isTrue);
  });
}
