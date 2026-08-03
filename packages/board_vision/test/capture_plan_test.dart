import 'dart:convert';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:test/test.dart';

import 'corpus/capture_plan.dart';
import 'corpus/checklist.dart';

/// The corpus's two promises, tested.
///
/// **Deterministic**, because a checklist is handed to a person who then spends
/// an hour photographing what it says, and a plan that shifted between the run
/// that printed the checklist and the run that wrote the sidecars would
/// silently mislabel every shot.
///
/// **Legal by construction**, because a mid-game position that no game can
/// reach is worse than no test at all: it scores the pipeline on boards it will
/// never meet, and a pipeline tuned to read them is tuned wrong. Every
/// position's sidecar carries the event log that produced it, and
/// `Game.replay` — the rules engine itself, with no help from here — has to
/// agree that the log reaches the board.
void main() {
  final plan = buildCapturePlan();
  final shots = flatten(plan);

  group('the plan is a function of its seed', () {
    test('two builds agree, shot for shot', () {
      final again = flatten(buildCapturePlan());
      expect(again.length, shots.length);
      for (var i = 0; i < shots.length; i++) {
        expect(
          jsonEncode(again[i].toJson()),
          jsonEncode(shots[i].toJson()),
          reason: 'shot ${shots[i].id} differs between two builds',
        );
      }
    });

    test('a different seed is a different plan', () {
      final other = flatten(buildCapturePlan(seed: kCorpusSeed + 1));
      expect(
        jsonEncode(other.map((s) => s.toJson()).toList()),
        isNot(jsonEncode(shots.map((s) => s.toJson()).toList())),
      );
    });

    test('the checklist is a function of the plan', () {
      expect(renderChecklist(plan), renderChecklist(buildCapturePlan()));
    });
  });

  group('the plan covers what the spec asks for', () {
    test('two boards and three lighting conditions', () {
      expect(plan.map((s) => s.conditions.board).toSet().length, 2);
      expect(plan.map((s) => s.conditions.lighting).toSet(),
          <String>{'daylight', 'lamp', 'dim'});
    });

    test('both seatings', () {
      expect(plan.map((s) => s.orientation).toSet(),
          BoardOrientation.values.toSet());
    });

    test('a starting position on every board in every light', () {
      final calibrations =
          shots.where((s) => s.kind == ShotKind.calibration).toList();
      expect(calibrations.length, 6);
      for (final shot in calibrations) {
        expect(shot.board, BoardState.initial());
        expect(shot.dice, isNull,
            reason: 'a board calibrated with dice on it can never see dice '
                'again — see dice_reader_test.dart');
      }
      expect(
        calibrations
            .map((s) => '${s.capture.board}/${s.capture.lighting}')
            .toSet()
            .length,
        6,
      );
    });

    test('twelve mid-game positions and twelve rolls', () {
      expect(shots.where((s) => s.kind == ShotKind.position).length, 12);
      expect(shots.where((s) => s.kind == ShotKind.dice).length, 12);
    });

    test('the rolls between them show every pip value', () {
      final seen = <int>{
        for (final shot in shots)
          if (shot.dice != null) ...<int>[shot.dice!.die1, shot.dice!.die2],
      };
      expect(seen, <int>{1, 2, 3, 4, 5, 6});
    });

    test('three shots that are meant to fail, and both ways of failing', () {
      final degraded =
          shots.where((s) => s.kind == ShotKind.degraded).toList();
      expect(degraded.length, 3);
      for (final shot in degraded) {
        expect(shot.expectsRefusal, isTrue);
        expect(shot.refusalReason, isNotNull);
        expect(shot.refusalReason, isNotEmpty);
      }
      expect(degraded.map((s) => s.expectRefusal).toSet(),
          ExpectedRefusal.values.toSet());
    });

    test('the mid-game positions are not all the same shape', () {
      final boards = shots
          .where((s) => s.kind == ShotKind.position)
          .map((s) => s.board.toString())
          .toSet();
      expect(boards.length, 12, reason: 'twelve distinct positions');

      // A corpus of twelve openings would teach nothing about the board states
      // that are actually hard: men on the bar, tall primes, checkers off.
      final interesting = shots
          .where((s) => s.kind == ShotKind.position)
          .where((s) =>
              s.board.whiteBar > 0 ||
              s.board.blackBar > 0 ||
              s.board.whiteOff > 0 ||
              s.board.blackOff > 0)
          .length;
      expect(interesting, greaterThanOrEqualTo(3),
          reason: 'some positions must have men on the bar or off the board');
    });
  });

  group('every position is one a real game reaches', () {
    for (final shot in flatten(buildCapturePlan())
        .where((s) => s.events != null)) {
      test('${shot.id} replays to the board its sidecar claims', () {
        // The rules engine is the judge. If the log is not a legal sequence,
        // Game.replay throws; if it is legal but reaches a different board,
        // the sidecar is lying and the harness would score against fiction.
        expect(shot.replayedBoard, shot.board);
      });
    }

    test('and the positions really did come from playouts', () {
      final withLogs = shots.where((s) => s.events != null).toList();
      expect(withLogs, isNotEmpty);
      for (final shot in withLogs) {
        expect(shot.events!.first, isA<OpeningRollEvent>());
        expect(shot.events!.length, greaterThan(4));
      }
    });
  });

  group('sessions', () {
    test('each begins with its own calibration shot and nothing else does',
        () {
      for (final session in plan) {
        expect(session.shots.first.kind, ShotKind.calibration);
        expect(session.shots.first.calibrateFrom, isNull);
        for (final shot in session.shots.skip(1)) {
          expect(shot.kind, isNot(ShotKind.calibration));
        }
      }
    });

    test('every non-calibration shot names the shot it is read through', () {
      for (final session in plan) {
        final calibration = session.calibrationShot.id;
        for (final shot in session.shots.skip(1)) {
          if (shot.expectRefusal == ExpectedRefusal.calibration) {
            // A calibration that must be refused is its own attempt; it has
            // nothing to be read through.
            expect(shot.calibrateFrom, isNull);
            continue;
          }
          expect(shot.calibrateFrom, calibration, reason: shot.id);
        }
      }
    });

    test('a shot that spoils the camera position comes last', () {
      for (final session in plan) {
        for (final (index, shot) in session.shots.indexed) {
          if (!shot.expectsRefusal) continue;
          expect(index, session.shots.length - 1,
              reason: '${shot.id} moves the phone, so nothing may follow it '
                  'in the same session');
        }
      }
    });

    test('ids are unique, three digits, and run in capture order', () {
      expect(shots.map((s) => s.id).toSet().length, shots.length);
      for (final (index, shot) in shots.indexed) {
        expect(shot.id, (index + 1).toString().padLeft(3, '0'));
      }
    });
  });

  group('the sidecar round-trips', () {
    test('every shot survives JSON', () {
      for (final shot in shots) {
        final decoded = CorpusShot.fromJson(
          jsonDecode(jsonEncode(shot.toJson())) as Map<String, dynamic>,
        );
        expect(decoded.id, shot.id);
        expect(decoded.kind, shot.kind);
        expect(decoded.calibrateFrom, shot.calibrateFrom);
        expect(decoded.board, shot.board);
        expect(decoded.dice, shot.dice);
        expect(decoded.orientation, shot.orientation);
        expect(decoded.expectRefusal, shot.expectRefusal);
        expect(decoded.replayedBoard, shot.replayedBoard);
        expect(jsonEncode(decoded.toJson()), jsonEncode(shot.toJson()));
      }
    });

    test('corners survive, when a shot has them', () {
      const corners = BoardQuad(
        topLeft: Pt(12.5, 34.25),
        topRight: Pt(1200.75, 30),
        bottomRight: Pt(1250, 900.5),
        bottomLeft: Pt(4, 910),
      );
      final decoded = CorpusShot.fromJson(
        jsonDecode(jsonEncode(shots.first.copyWith(corners: corners).toJson()))
            as Map<String, dynamic>,
      );
      expect(decoded.corners, corners);
    });

    test('a sidecar from another schema is refused, not misread', () {
      final json = shots.first.toJson()..['schema'] = kSidecarSchema + 1;
      expect(() => CorpusShot.fromJson(json), throwsFormatException);
    });
  });

  group('the checklist is something a person can follow', () {
    final text = renderChecklist(plan);

    test('every shot appears, by number and title', () {
      for (final shot in shots) {
        expect(text, contains('### ${shot.id} — ${shot.title}'));
      }
    });

    test('it says the thing that ruins a session', () {
      expect(text, contains('do not move the phone'));
    });

    test('it tells the user to keep the dice clear of the stacks', () {
      // readDice returns null when a die touches a stack, by design. A corpus
      // that scored those as failures would be measuring the wrong thing.
      final diceShots = shots.where((s) => s.kind == ShotKind.dice);
      for (final shot in diceShots) {
        expect(shot.instructions.join(' ').toLowerCase(),
            contains('clear of'), reason: shot.id);
      }
    });

    test('every mid-game position is drawn out', () {
      for (final shot in shots.where((s) => s.kind == ShotKind.position)) {
        expect(text, contains(describeBoard(shot.board)),
            reason: 'shot ${shot.id} has no diagram to copy');
      }
    });

    test('a board diagram says what is where', () {
      final start = describeBoard(BoardState.initial());
      // The starting position, read off the standard diagram: five White on
      // 13 and on 6, three White on 8, two White on 24, and Black's mirror.
      expect(start, contains(' 13'));
      expect(start, contains(' 5W'));
      expect(start, contains(' 5B'));
      expect(start, contains('bar and trays empty'));

      final withBar = describeBoard(BoardState(
        points: BoardState.initial().points,
        whiteBar: 2,
        blackOff: 3,
      ));
      expect(withBar, contains('2 White on the bar'));
      expect(withBar, contains('3 Black borne off'));
    });
  });
}
