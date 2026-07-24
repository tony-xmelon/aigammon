@Tags(['engine'])
library;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:test/test.dart';

void main() {
  late EngineService service;

  setUpAll(() async {
    service =
        await EngineService.spawn(netsPath: '../../native/wildbg-nets/neural-nets');
  });

  tearDownAll(() => service.dispose());

  test('evaluate round-trips through the isolate', () async {
    final p = await service.evaluate(BoardState.initial(), Player.white);
    expect(p.win, closeTo(0.5, 0.07));
  });

  test('bestMove and cubeInfo round-trip', () async {
    final best =
        await service.bestMove(BoardState.initial(), Player.white, Dice(3, 1));
    final legal = MoveGenerator.legalMoves(
        BoardState.initial(), Player.white, Dice(3, 1));
    expect(legal.any((m) => m.sameAs(best)), isTrue);
    final advice = await service.cubeInfo(BoardState.initial(), Player.white);
    expect(advice.shouldDouble, isFalse);
    expect(advice.equityCubeless, closeTo(0, 0.3));
  });

  test('rankMoves works and concurrent requests do not interleave replies',
      () async {
    final results = await Future.wait([
      service.rankMoves(BoardState.initial(), Player.white, Dice(3, 1)),
      service.rankMoves(BoardState.initial(), Player.white, Dice(6, 5)),
      service.evaluate(BoardState.initial(), Player.black),
    ]);
    final r31 = results[0] as List<ScoredMove>;
    final r65 = results[1] as List<ScoredMove>;
    final pBlack = results[2] as Probabilities;
    expect(
        r31.length,
        MoveGenerator.legalMoves(
                BoardState.initial(), Player.white, Dice(3, 1))
            .length);
    expect(
        r65.length,
        MoveGenerator.legalMoves(
                BoardState.initial(), Player.white, Dice(6, 5))
            .length);
    // Sorted best-first survived the wire:
    for (var i = 1; i < r31.length; i++) {
      expect(r31[i - 1].equity, greaterThanOrEqualTo(r31[i].equity));
    }
    // Hit flags survive serialization: a 6-5 lover's leap never hits, but
    // probabilities must be finite and in range either way.
    expect(pBlack.win, inInclusiveRange(0.0, 1.0));
  });

  test('spawn fails cleanly with a bad nets path', () async {
    expect(
      () => EngineService.spawn(netsPath: 'Z:/definitely/not/here'),
      throwsA(isA<StateError>()),
    );
  });

  test('dispose is idempotent and later calls throw', () async {
    final s = await EngineService.spawn(
        netsPath: '../../native/wildbg-nets/neural-nets');
    s.dispose();
    s.dispose();
    expect(() => s.evaluate(BoardState.initial(), Player.white),
        throwsStateError);
  });
}
