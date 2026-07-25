import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/tutor/move_assessment.dart';
import 'package:aigammon_app/tutor/tutor_service.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter_test/flutter_test.dart';

/// Canned engine: [assess] reads [ranked], [assessCube] reads [evalProbs].
class FakeEngine implements EngineFacade {
  FakeEngine({List<ScoredMove>? ranked, Probabilities? evalProbs})
      : ranked = ranked ?? const [],
        evalProbs = evalProbs ?? _defaultProbs;

  List<ScoredMove> ranked;
  Probabilities evalProbs;
  int rankMovesCalls = 0;
  int evaluateCalls = 0;
  Player? lastEvalMover;

  static const _defaultProbs = Probabilities(
    win: 0.5,
    winGammon: 0,
    winBackgammon: 0,
    loseGammon: 0,
    loseBackgammon: 0,
  );

  @override
  Future<Probabilities> evaluate(BoardState board, Player mover) async {
    evaluateCalls++;
    lastEvalMover = mover;
    return evalProbs;
  }

  @override
  Future<List<ScoredMove>> rankMoves(
      BoardState board, Player mover, Dice dice) async {
    rankMovesCalls++;
    return ranked;
  }

  @override
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover) async =>
      throw UnimplementedError();
}

/// A gammonless [ScoredMove] whose cubeless equity equals [equity]
/// (equity = 2*win - 1, so win = (equity + 1) / 2).
ScoredMove _scored(Move move, double equity) => ScoredMove(
      move: move,
      probabilities: Probabilities(
        win: (equity + 1) / 2,
        winGammon: 0,
        winBackgammon: 0,
        loseGammon: 0,
        loseBackgammon: 0,
      ),
    );

MatchContext _ctx(int a, int b, {bool crawfordPlayed = false}) => MatchContext(
      moverAway: a,
      opponentAway: b,
      crawfordPlayed: crawfordPlayed,
    );

/// Lone White checker on point 24 (index 23), everyone else borne off; dice
/// (4,2). The only legal play is the single-checker transit
/// 24/22 22/18 == [(23,21),(21,17)] — the fixture that exercises the tutor's
/// position-equivalence fallback.
GameState _transitState() => GameState.testState(
      board: BoardState(points: [
        -2, 0, 0, 0, 0, 0, //
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
      ], whiteOff: 14, blackOff: 13),
      turn: Player.white,
      phase: GamePhase.moving,
      dice: Dice(4, 2),
    );

/// White on the bar with all of Black's home entry points (for dice 6,2)
/// blocked: no legal play (a dance).
GameState _danceState() {
  final pts = List<int>.filled(24, 0);
  for (var i = 18; i < 24; i++) {
    pts[i] = -2; // Black holds points 19-24, blocking bar entry for 6 and 2.
  }
  pts[0] = -3;
  pts[12] = 14;
  return GameState.testState(
    board: BoardState(points: pts, whiteBar: 1),
    turn: Player.white,
    phase: GamePhase.moving,
    dice: Dice(6, 2),
  );
}

GameState _movingState() => GameState.testState(
      board: BoardState.initial(),
      turn: Player.white,
      phase: GamePhase.moving,
      dice: Dice(3, 1),
    );

GameState _awaitingRollState({CubeState? cube}) => GameState.testState(
      board: BoardState.initial(),
      turn: Player.white,
      phase: GamePhase.awaitingRoll,
      cube: cube ?? const CubeState.initial(),
    );

/// White has doubled; Black is now the DECIDER being asked to take or pass.
GameState _cubeOfferedState({CubeState? cube}) => GameState.testState(
      board: BoardState.initial(),
      turn: Player.black,
      phase: GamePhase.cubeOffered,
      cube: cube ?? const CubeState.initial(),
    );

/// A gammonless probabilities fixture with the given [win] chance.
Probabilities _probs(double win) => Probabilities(
      win: win,
      winGammon: 0,
      winBackgammon: 0,
      loseGammon: 0,
      loseBackgammon: 0,
    );

/// The Task-2 gammonful fixture (5-away/5-away): shouldDouble & shouldTake.
const _gammonfulProbs = Probabilities(
  win: 0.6,
  winGammon: 0.3,
  winBackgammon: 0.05,
  loseGammon: 0.1,
  loseBackgammon: 0.0,
);

void main() {
  group('markFor bands', () {
    test('boundary values map to the documented marks', () {
      expect(markFor(0.0), MoveMark.best);
      expect(markFor(0.0009), MoveMark.best); // < 0.001
      expect(markFor(0.0011), MoveMark.good); // >= 0.001, < 0.02
      expect(markFor(0.019), MoveMark.good); // < 0.02
      expect(markFor(0.02), MoveMark.dubious); // == dubious threshold
      expect(markFor(0.049), MoveMark.dubious); // < 0.05
      expect(markFor(0.05), MoveMark.error); // == error threshold
      expect(markFor(0.109), MoveMark.error); // < 0.11
      expect(markFor(0.11), MoveMark.blunder); // == blunder threshold
      expect(markFor(0.5), MoveMark.blunder);
    });
  });

  group('TutorService.hint', () {
    test('returns the engine ranking in the moving phase', () async {
      final top = Move([const CheckerMove(23, 20)]);
      final engine = FakeEngine(ranked: [_scored(top, 0.1)]);
      final tutor = TutorService(engine);
      final ranked = await tutor.hint(_movingState());
      expect(ranked, hasLength(1));
      expect(ranked.first.move, same(top));
    });

    test('empty on a dance (no legal play)', () async {
      final engine = FakeEngine(ranked: [_scored(_movingState().legalMoves.first, 0.1)]);
      final tutor = TutorService(engine);
      expect(await tutor.hint(_danceState()), isEmpty);
      expect(engine.rankMovesCalls, 0, reason: 'no ranking query on a dance');
    });

    test('empty outside the moving phase', () async {
      final tutor = TutorService(FakeEngine());
      expect(await tutor.hint(_awaitingRollState()), isEmpty);
    });
  });

  group('TutorService.assess', () {
    test('played == top play: loss 0, mark best', () async {
      final top = Move([const CheckerMove(23, 20)]);
      final other = Move([const CheckerMove(12, 9)]);
      final engine = FakeEngine(ranked: [
        _scored(top, 0.10),
        _scored(other, 0.04),
      ]);
      final tutor = TutorService(engine);
      final a = await tutor.assess(_movingState(), top);
      expect(a.equityLoss, closeTo(0, 1e-12));
      expect(a.mark, MoveMark.best);
      expect(a.best.sameAs(top), isTrue);
      expect(a.ranked, hasLength(2));
    });

    test('played == second play: loss 0.06 -> error band', () async {
      final top = Move([const CheckerMove(23, 20)]);
      final other = Move([const CheckerMove(12, 9)]);
      final engine = FakeEngine(ranked: [
        _scored(top, 0.10),
        _scored(other, 0.04),
      ]);
      final tutor = TutorService(engine);
      final a = await tutor.assess(_movingState(), other);
      expect(a.equityLoss, closeTo(0.06, 1e-9));
      expect(a.mark, MoveMark.error, reason: '0.06 in [0.05, 0.11)');
      expect(a.best.sameAs(top), isTrue);
    });

    test('resolves a transit-equivalent decomposition by applied board',
        () async {
      final before = _transitState();
      final canonical = before.legalMoves.single;
      // Two dice-order decompositions land the lone checker on index 17:
      // via index 21 (die 2 then 4) or via index 19 (die 4 then 2). The
      // generator dedupes them to one canonical representative; the OTHER is
      // position-equivalent but NOT sameAs (different intermediate point ->
      // different hop multiset). Submitting that alternate exercises the
      // applied-board fallback.
      final viaA = Move(const [CheckerMove(23, 21), CheckerMove(21, 17)]);
      final viaB = Move(const [CheckerMove(23, 19), CheckerMove(19, 17)]);
      final alternate = canonical.sameAs(viaA) ? viaB : viaA;
      expect(alternate.sameAs(canonical), isFalse,
          reason: 'a different dice-order decomposition is a different multiset');
      expect(before.board.applyMove(Player.white, alternate),
          before.board.applyMove(Player.white, canonical),
          reason: 'sanity: both decompositions reach the same position');

      final engine = FakeEngine(ranked: [_scored(canonical, 0.30)]);
      final tutor = TutorService(engine);
      final a = await tutor.assess(before, alternate);
      // Resolves to the single ranked entry (the top), so loss is 0.
      expect(a.equityLoss, closeTo(0, 1e-12));
      expect(a.mark, MoveMark.best);
      expect(a.best.sameAs(canonical), isTrue);
    });

    test('dance: loss 0, mark best, best = Move.none', () async {
      final engine = FakeEngine(ranked: const []);
      final tutor = TutorService(engine);
      final a = await tutor.assess(_danceState(), Move.none);
      expect(a.equityLoss, 0);
      expect(a.mark, MoveMark.best);
      expect(a.best, same(Move.none));
      expect(engine.rankMovesCalls, 0, reason: 'no ranking query on a dance');
    });
  });

  group('TutorService.assessCube', () {
    const advisor = MatchCubeAdvisor();

    test('advisor says double & player doubled: loss 0, mark best', () async {
      final engine = FakeEngine(evalProbs: _gammonfulProbs);
      final tutor = TutorService(engine);
      final ctx = _ctx(5, 5);
      final a = await tutor.assessCube(_awaitingRollState(), ctx,
          playerDoubled: true);
      expect(a.advice.shouldDouble, isTrue, reason: '5a/5a gammonful doubles');
      expect(a.equityLoss, 0);
      expect(a.mark, MoveMark.best);
    });

    test('advisor says double & player rolled on: positive loss from bands',
        () async {
      final engine = FakeEngine(evalProbs: _gammonfulProbs);
      final tutor = TutorService(engine);
      final ctx = _ctx(5, 5);
      final expected = advisor.advise(
          probs: _gammonfulProbs, moverAway: 5, opponentAway: 5, cubeValue: 1);
      final bestDoubled = expected.equityDoubleTake < expected.equityDoubleDrop
          ? expected.equityDoubleTake
          : expected.equityDoubleDrop;
      final expectedLoss = bestDoubled - expected.equityNoDouble;

      final a = await tutor.assessCube(_awaitingRollState(), ctx,
          playerDoubled: false);
      expect(a.equityLoss, closeTo(expectedLoss, 1e-12));
      // 0.5762685 - 0.534372 = 0.0418965 -> [0.02, 0.05) -> dubious.
      expect(a.equityLoss, closeTo(0.0418965, 1e-6));
      expect(a.mark, MoveMark.dubious);
    });

    test('advisor says no-double & player doubled: positive loss', () async {
      // Gammonless w=0.4 at 2a/2a: not good enough to double.
      final probs = const Probabilities(
        win: 0.4,
        winGammon: 0,
        winBackgammon: 0,
        loseGammon: 0,
        loseBackgammon: 0,
      );
      final engine = FakeEngine(evalProbs: probs);
      final tutor = TutorService(engine);
      final ctx = _ctx(2, 2);
      final expected = advisor.advise(
          probs: probs, moverAway: 2, opponentAway: 2, cubeValue: 1);
      expect(expected.shouldDouble, isFalse);
      final bestDoubled = expected.equityDoubleTake < expected.equityDoubleDrop
          ? expected.equityDoubleTake
          : expected.equityDoubleDrop;
      final expectedLoss = expected.equityNoDouble - bestDoubled;

      final a = await tutor.assessCube(_awaitingRollState(), ctx,
          playerDoubled: true);
      expect(a.equityLoss, greaterThan(0));
      expect(a.equityLoss, closeTo(expectedLoss, 1e-12));
      expect(a.mark, markFor(expectedLoss));
    });

    test('uses the cube value from the state', () async {
      final engine = FakeEngine(evalProbs: _gammonfulProbs);
      final tutor = TutorService(engine);
      final ctx = _ctx(5, 5);
      final state = _awaitingRollState(
          cube: const CubeState(value: 2, owner: Player.white));
      final expected = advisor.advise(
          probs: _gammonfulProbs, moverAway: 5, opponentAway: 5, cubeValue: 2);
      final a =
          await tutor.assessCube(state, ctx, playerDoubled: true);
      expect(a.advice.equityNoDouble, closeTo(expected.equityNoDouble, 1e-12));
    });
  });

  group('TutorService.assessCubeResponse', () {
    const advisor = MatchCubeAdvisor();

    test('evaluates the DOUBLER and inverts the aways', () async {
      // cubeOffered: turn = black (decider), doubler = white. deciderCtx is
      // anchored to the DECIDER: moverAway = decider (2), opponentAway = doubler
      // (5). The advisor must be fed the DOUBLER's perspective, so the tutor
      // inverts. probs (win 0.61, gammonless, doubler's view) is chosen so the
      // correct orientation (doubler 5-away) says TAKE while the inverted-by-
      // mistake orientation would say DROP — pinning the inversion.
      final probs = _probs(0.61);
      final correct = advisor.advise(
          probs: probs, moverAway: 5, opponentAway: 2, cubeValue: 1);
      final swapped = advisor.advise(
          probs: probs, moverAway: 2, opponentAway: 5, cubeValue: 1);
      expect(correct.shouldTake, isTrue);
      expect(swapped.shouldTake, isFalse,
          reason: 'sanity: the orientation genuinely changes the decision');

      final engine = FakeEngine(evalProbs: probs);
      final tutor = TutorService(engine);
      final state = _cubeOfferedState();
      expect(state.turn, Player.black);

      // deciderCtx: decider (black) 2-away, doubler (white) 5-away.
      final a = await tutor.assessCubeResponse(state, _ctx(2, 5));

      expect(engine.lastEvalMover, Player.white,
          reason: 'must query the doubler (white), not the decider (black)');
      expect(a.advice.shouldTake, isTrue,
          reason: 'doubler is 5-away: taking is correct here');
      expect(a.actionWasDouble, isTrue,
          reason: 'the doubler did offer the cube');
    });

    test('a strong doubler position advises the decider to PASS', () async {
      // Doubler with a big lead in win chance (gammonless 0.80): the decider
      // should pass. Symmetric aways so only the doubler-orientation matters.
      final probs = _probs(0.80);
      final expected = advisor.advise(
          probs: probs, moverAway: 5, opponentAway: 5, cubeValue: 1);
      expect(expected.shouldTake, isFalse, reason: 'sanity: a pass position');

      final engine = FakeEngine(evalProbs: probs);
      final tutor = TutorService(engine);
      final a = await tutor.assessCubeResponse(_cubeOfferedState(), _ctx(5, 5));
      expect(a.advice.shouldTake, isFalse);
    });

    test('uses the cube value from the state', () async {
      final probs = _probs(0.61);
      final engine = FakeEngine(evalProbs: probs);
      final tutor = TutorService(engine);
      final state = _cubeOfferedState(
          cube: const CubeState(value: 2, owner: Player.black));
      // Doubler 5-away, decider 2-away, cube 2.
      final expected = advisor.advise(
          probs: probs, moverAway: 5, opponentAway: 2, cubeValue: 2);
      final a = await tutor.assessCubeResponse(state, _ctx(2, 5));
      expect(a.advice.equityDoubleTake,
          closeTo(expected.equityDoubleTake, 1e-12));
    });
  });

  group('JSON round-trips', () {
    test('MoveAssessment survives toJson/fromJson', () {
      final top = Move([const CheckerMove(23, 21), const CheckerMove(21, 17)]);
      final other = Move([const CheckerMove(12, 9, isHit: true)]);
      final ranked = [
        _scored(top, 0.10),
        _scored(other, 0.04),
      ];
      final original = MoveAssessment(
        played: other,
        best: top,
        equityLoss: 0.06,
        ranked: ranked,
      );
      final round = MoveAssessment.fromJson(original.toJson());

      expect(round.played.sameAs(other), isTrue);
      expect(round.played.checkerMoves.first.isHit, isTrue);
      expect(round.best.sameAs(top), isTrue);
      expect(round.equityLoss, closeTo(0.06, 1e-12));
      expect(round.mark, original.mark);
      expect(round.ranked, hasLength(2));
      expect(round.ranked.first.move.sameAs(top), isTrue);
      expect(round.ranked.first.probabilities.win,
          closeTo(ranked.first.probabilities.win, 1e-12));
      expect(round.ranked[1].probabilities.win,
          closeTo(ranked[1].probabilities.win, 1e-12));
    });

    test('CubeAssessment survives toJson/fromJson', () {
      const advisor = MatchCubeAdvisor();
      final advice = advisor.advise(
          probs: _gammonfulProbs, moverAway: 5, opponentAway: 5, cubeValue: 1);
      final original =
          CubeAssessment(actionWasDouble: false, advice: advice);
      final round = CubeAssessment.fromJson(original.toJson());

      expect(round.actionWasDouble, isFalse);
      expect(round.advice.shouldDouble, advice.shouldDouble);
      expect(round.advice.shouldTake, advice.shouldTake);
      expect(round.advice.equityNoDouble,
          closeTo(advice.equityNoDouble, 1e-12));
      expect(round.advice.equityDoubleTake,
          closeTo(advice.equityDoubleTake, 1e-12));
      expect(round.advice.equityDoubleDrop,
          closeTo(advice.equityDoubleDrop, 1e-12));
      expect(round.equityLoss, closeTo(original.equityLoss, 1e-12));
      expect(round.mark, original.mark);
    });
  });
}
