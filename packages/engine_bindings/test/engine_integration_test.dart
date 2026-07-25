@Tags(['engine'])
library;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:test/test.dart';

void main() {
  late Engine engine;

  setUpAll(() {
    engine = Engine.open(netsPath: '../../native/wildbg-nets/neural-nets');
  });

  tearDownAll(() => engine.dispose());

  test('starting position is roughly even', () {
    final p = engine.evaluate(BoardState.initial(), Player.white);
    expect(p.win, closeTo(0.5, 0.07));
    expect(p.winGammon, lessThan(p.win));
    expect(p.winBackgammon, lessThanOrEqualTo(p.winGammon));
    expect(p.equity, closeTo(0, 0.3));
  });

  test('a winning race is recognized', () {
    final pts = List<int>.filled(24, 0);
    pts[0] = 2;
    pts[23] = -15;
    final b = BoardState(points: pts, whiteOff: 13);
    final p = engine.evaluate(b, Player.white);
    expect(p.win, greaterThan(0.95));
  });

  test('bestMove returns a legal move', () {
    final best =
        engine.bestMove(BoardState.initial(), Player.white, Dice(3, 1));
    final legal = MoveGenerator.legalMoves(
        BoardState.initial(), Player.white, Dice(3, 1));
    expect(legal.any((m) => m.sameAs(best)), isTrue,
        reason: 'engine best move must be legal: $best');
  });

  test('bestMove works for black too (perspective round-trip)', () {
    final best =
        engine.bestMove(BoardState.initial(), Player.black, Dice(6, 5));
    final legal = MoveGenerator.legalMoves(
        BoardState.initial(), Player.black, Dice(6, 5));
    expect(legal.any((m) => m.sameAs(best)), isTrue,
        reason: 'black best move must be legal: $best');
  });

  test('rankMoves ranks every legal move, best first', () {
    final ranked =
        engine.rankMoves(BoardState.initial(), Player.white, Dice(3, 1));
    final legal = MoveGenerator.legalMoves(
        BoardState.initial(), Player.white, Dice(3, 1));
    expect(ranked, hasLength(legal.length));
    for (var i = 1; i < ranked.length; i++) {
      expect(ranked[i - 1].equity, greaterThanOrEqualTo(ranked[i].equity));
    }
    // ignore: avoid_print
    print('top 3-1 move: ${ranked.first.move} (eq ${ranked.first.equity.toStringAsFixed(3)})');
  });

  test('engine best move sits near the top of our 0-ply ranking', () {
    final best =
        engine.bestMove(BoardState.initial(), Player.white, Dice(3, 1));
    final ranked =
        engine.rankMoves(BoardState.initial(), Player.white, Dice(3, 1));
    final index = ranked.indexWhere((s) => s.move.sameAs(best));
    expect(index, inInclusiveRange(0, 3),
        reason: 'engine pick $best ranked #$index in 0-ply ranking');
  });

  test('cube_info returns sane values', () {
    final advice = engine.cubeInfo(BoardState.initial(), Player.white);
    expect(advice.equityCubeless, closeTo(0, 0.3));
    expect(advice.equityCubeless.isFinite, isTrue);
    expect(advice.equityNoDouble.isFinite, isTrue);
    expect(advice.equityDoubleTake.isFinite, isTrue);
    expect(advice.shouldDouble, isFalse,
        reason: 'nobody doubles the opening position');
  });

  test('a clear but takeable-lead race is a proper double/pass', () {
    // White (3 on each of points 1-5, pip 45) leads a pure race against
    // black (pip 52); no gammon is on the table. wildbg evaluates ~81% wins.
    // This lands inside Janowski's doubling window: doubling beats holding
    // the centered cube (shouldDouble), yet the opponent is losing too badly
    // to take (equity_double_take >= 1.0, so shouldAccept is false).
    // See native/wildbg/crates/logic/src/cube.rs.
    final pts = List<int>.filled(24, 0);
    for (var i = 0; i < 5; i++) {
      pts[i] = 3; // white 3 on each of points 1..5
    }
    for (final e in {18: 3, 19: 1, 20: 3, 21: 3, 22: 3, 23: 2}.entries) {
      pts[e.key] = -e.value; // black, pip 52
    }
    final advice = engine.cubeInfo(BoardState(points: pts), Player.white);
    expect(advice.shouldDouble, isTrue,
        reason: 'clear takeable lead is a double');
    // NB: shouldAccept=false here rests on only a ~2.4pp win-probability
    // margin past the take point; if the neural nets are ever upgraded this
    // threshold may flip and the fixture will need retuning.
    expect(advice.shouldAccept, isFalse,
        reason: 'the trailer is too far behind to take');
  });

  test('a crushing gammonish race is TOO GOOD to double', () {
    // White wins a near-certain gammon (black has borne off nothing). Under
    // Janowski's formula (cube.rs), such a position yields
    // equity_no_double > 1.0, so playing on for the gammon beats cashing a
    // single point: shouldDouble is FALSE (not true). This is the
    // "too good to double" branch, mirroring cube.rs's own unit test.
    final pts = List<int>.filled(24, 0);
    pts[0] = 2;
    pts[23] = -15;
    final crushing = BoardState(points: pts, whiteOff: 13);
    final advice = engine.cubeInfo(crushing, Player.white);
    expect(advice.shouldDouble, isFalse,
        reason: 'too good to double: play on for the gammon');
    expect(advice.shouldAccept, isFalse,
        reason: 'if doubled the opponent must drop');
    expect(advice.equityNoDouble, greaterThan(1.0),
        reason: 'too-good signal per Janowski cube model');
  });

  test('match-aware cube advice on a crushing race (5-away/5-away)', () {
    // Same near-certain-gammon fixture as the money "too good" test above, but
    // now scored at 5-away/5-away with the cube at 1. "Too good to double" is a
    // MONEY concept (playing on for the gammon beats cashing a single point);
    // at a match score the dead-cube model weighs the actual gammon value in
    // MET points. We assert exactly what the model computes, with the numbers
    // printed for auditing rather than asserting money folklore.
    final pts = List<int>.filled(24, 0);
    pts[0] = 2;
    pts[23] = -15;
    final crushing = BoardState(points: pts, whiteOff: 13);
    final probs = engine.evaluate(crushing, Player.white);
    const advisor = MatchCubeAdvisor();
    final advice = advisor.advise(
        probs: probs, moverAway: 5, opponentAway: 5, cubeValue: 1);
    // ignore: avoid_print
    print('crushing 5a/5a: $probs -> $advice');
    // The mover is winning far too heavily for the opponent to take: dropping
    // (bank 1 point) is much better for them than playing on doubled.
    expect(advice.shouldTake, isFalse,
        reason: 'opponent is crushed and must drop');
    // Observed model result here: shouldDouble is FALSE. This is the too-good
    // phenomenon surfacing at match play: on the near-certain gammon, NOT
    // doubling banks 2 points (5->3 away, MET 0.64795), whereas doubling lets
    // the opponent DROP for just 1 point (5->4 away, MET 0.57732), which is
    // worse for the mover. We assert the computed booleans are self-consistent
    // rather than hard-coding this (nets upgrades could shift the margins).
    final minDoubled = advice.equityDoubleTake < advice.equityDoubleDrop
        ? advice.equityDoubleTake
        : advice.equityDoubleDrop;
    expect(advice.shouldDouble, minDoubled > advice.equityNoDouble);
    expect(advice.equityNoDouble.isFinite, isTrue);
    expect(advice.equityDoubleTake.isFinite, isTrue);
  });

  test('dispose then use throws', () {
    final e = Engine.open(netsPath: '../../native/wildbg-nets/neural-nets');
    e.dispose();
    e.dispose(); // idempotent
    expect(() => e.evaluate(BoardState.initial(), Player.white),
        throwsStateError);
  });
}
