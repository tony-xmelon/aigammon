import 'dart:convert';
import 'dart:io';

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

    test('and the hit flags on those logs have not moved', () {
      // The counterweight to the filmed session's own hit test below. These
      // logs get their flags from the move generator, and this pins that
      // nothing done for the real corpus reached them: the synthetic corpus is
      // committed, so a flag that moved here is thirty-three sidecars on disk
      // that no longer match the plan that claims to produce them.
      expect(_hopFlags(shots), (181, 1050));
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

    test('a shot with no measured proportions emits NO proportions key', () {
      // Review found `'proportions': proportions?.toJson()` writing an
      // explicit null. The committed sidecars carry no such key, and both
      // drift guards compare fromJson->toJson on BOTH sides, so a null key
      // is exactly the class of byte drift they cannot see — "committed
      // equals what the generator writes" must hold at the byte level.
      final unmeasured = shots.firstWhere((s) => s.proportions == null);
      expect(jsonEncode(unmeasured.toJson()), isNot(contains('proportions')));
    });

    test('a shot on a board that does not fold emits NO foldingCorners key',
        () {
      // The same lesson as the line above, applied the moment a second
      // additive field arrived rather than after it broke something.
      final flat = shots.firstWhere((s) => s.foldingCorners == null);
      expect(jsonEncode(flat.toJson()), isNot(contains('foldingCorners')));
    });
  });

  group('the board\'s own shape, which a session may have to say', () {
    // The real corpus is shot on a folding-case board — no bear-off wells, a
    // hinge for a bar — so a sidecar has to be able to say what shape its
    // board is. The field is purely additive, and these are the tests that
    // keep it that way: every sidecar already committed was written before it
    // existed, and none of them has to be regenerated.

    test('a shot on an ordinary board carries no proportions at all', () {
      for (final shot in shots) {
        expect(shot.proportions, isNull, reason: shot.id);
        expect(shot.toJson()['proportions'], isNull, reason: shot.id);
      }
      expect(kSidecarSchema, 1,
          reason: 'adding a field does not bump the schema — readers tolerate '
              'a key they have never seen, and bumping would invalidate a '
              'corpus that took a person an afternoon to shoot');
    });

    test('a sidecar written before the field existed still loads', () {
      final json = shots.first.toJson()
        ..remove('proportions')
        ..remove('foldingCorners');
      final decoded = CorpusShot.fromJson(json);
      expect(decoded.proportions, isNull,
          reason: 'absent means the board is the usual shape');
      expect(decoded.foldingCorners, isNull,
          reason: 'and absent here means it does not fold');
    });

    test('a session on a board that FOLDS carries its eight points', () {
      // The other thing a real board turned out to be. A folding case is not
      // one plane — its two leaves tent — so four corners cannot describe it
      // and the sidecar carries eight points instead. Additive exactly like
      // the widths above, and with no widths of its own: those are derived
      // from the eight.
      const eight = FoldingCorners(
        topLeft: Pt(120.5, 88),
        topRight: Pt(1150, 80.25),
        bottomRight: Pt(1210, 860),
        bottomLeft: Pt(60, 880.75),
        hingeFarLeft: Pt(600, 84),
        hingeFarRight: Pt(645.5, 83.5),
        hingeNearLeft: Pt(615, 870),
        hingeNearRight: Pt(672, 869),
      );
      final shot = shots.first.copyWith(foldingCorners: eight);
      final decoded = CorpusShot.fromJson(
        jsonDecode(jsonEncode(shot.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.foldingCorners, eight);
      expect(jsonEncode(decoded.toJson()), jsonEncode(shot.toJson()));
    });

    test('a session on a folding-case board carries its measurements', () {
      const measured = BoardProportions(trayWidth: 0, barWidth: 0.031);
      final shot = shots.first.copyWith(proportions: measured);
      final decoded = CorpusShot.fromJson(
        jsonDecode(jsonEncode(shot.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.proportions, measured);
      expect(jsonEncode(decoded.toJson()), jsonEncode(shot.toJson()));
    });

    test('numbers that do not describe a board are refused by the reader', () {
      // A sidecar is data from outside the program and these are measured by
      // hand, so the reader checks them rather than letting a homography full
      // of infinities be the error message.
      for (final bad in <Map<String, dynamic>>[
        <String, dynamic>{'trayWidth': -0.01, 'barWidth': 0.08},
        <String, dynamic>{'trayWidth': 0.08, 'barWidth': 0.0},
        <String, dynamic>{'trayWidth': 0.45, 'barWidth': 0.2},
      ]) {
        final json = shots.first.toJson()..['proportions'] = bad;
        expect(() => CorpusShot.fromJson(json), throwsFormatException,
            reason: '$bad');
      }
    });
  });

  group('the committed capture kit is the plan\'s', () {
    // The kit in `corpus/` is what a person actually shoots from, and it is
    // generated and committed like the synthetic corpus — so it goes stale the
    // same way, and the consequence is worse. `prepare_corpus` writes sidecars
    // from the LIVE plan: if the committed checklist has drifted, someone sets
    // up the position the stale document asked for and the tool labels the
    // photograph with the position the plan means now. Every shot in the real
    // corpus would carry wrong ground truth, silently, and the harness would
    // score a pipeline that is working as though it were broken.
    final kit = Directory('corpus');

    test('the kit is committed at all', () {
      expect(kit.existsSync(), isTrue,
          reason: 'run `dart run tool/generate_capture_checklist.dart`');
    });

    test('CHECKLIST.md is what the plan renders today', () {
      expect(
        File('${kit.path}/CHECKLIST.md').readAsStringSync().replaceAll(
              '\r\n',
              '\n',
            ),
        renderChecklist(plan),
        reason: 'the committed checklist has drifted from the plan — '
            'regenerate with tool/generate_capture_checklist.dart',
      );
    });

    test('every kit sidecar is what the plan produces today', () {
      final committed = <String, CorpusShot>{
        for (final file in kit
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.expected.json')))
          (jsonDecode(file.readAsStringSync())
              as Map<String, dynamic>)['id'] as String: CorpusShot.fromJson(
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
          ),
      };
      expect(committed.keys.toSet(), shots.map((s) => s.id).toSet());
      for (final shot in shots) {
        expect(
          jsonEncode(committed[shot.id]!.toJson()),
          jsonEncode(shot.toJson()),
          reason: 'kit sidecar ${shot.id} has drifted from the plan',
        );
      }
    });
  });

  group('the corners, which are the only thing a person has to work out', () {
    test('the plan needs exactly eight sets of them, and these eight', () {
      // The count the checklist prints and the count the prep tool means have
      // to be the same number, and once were not: the checklist said six where
      // the tool meant eight, so a person following it would have found two
      // shots in `corners.json` that the instructions did not mention — and
      // one of those two is the shot with a third of the board deliberately
      // out of frame. Both now read [CorpusShot.needsCorners]; this pins what
      // it answers.
      final needing = shots.where((s) => s.needsCorners).map((s) => s.id);
      expect(needing, <String>[
        '001', '006', '011', '012', '017', '022', '023', '028', //
      ]);
    });

    test('they are the six calibration shots plus the two own-attempt '
        'refusals', () {
      final needing = shots.where((s) => s.needsCorners).toList();
      expect(
        needing.where((s) => s.kind == ShotKind.calibration).length,
        6,
        reason: 'one per session',
      );
      final awkward =
          needing.where((s) => s.kind != ShotKind.calibration).toList();
      expect(awkward.length, 2);
      for (final shot in awkward) {
        expect(shot.expectRefusal, ExpectedRefusal.calibration,
            reason: '${shot.id} carries corners only because it is its own '
                'calibration attempt');
      }
      // The knocked-phone shot is read through its session and must NOT be in
      // the list: its whole point is that the session's corners no longer
      // describe where the board is.
      final bumped = shots.firstWhere(
        (s) => s.expectRefusal == ExpectedRefusal.geometry,
      );
      expect(bumped.needsCorners, isFalse);
    });

    test('the two awkward ones are one of each kind, and the checklist rules '
        'on both', () {
      final awkward = shots
          .where((s) => s.needsCorners && s.kind != ShotKind.calibration)
          .toList();
      expect(awkward.where((s) => s.isPartlyOutOfFrame).length, 1);
      expect(awkward.where((s) => !s.isPartlyOutOfFrame).length, 1);

      final text = renderChecklist(plan);
      final outOfFrame = awkward.firstWhere((s) => s.isPartlyOutOfFrame);
      final dark = awkward.firstWhere((s) => !s.isPartlyOutOfFrame);

      // Two corners of the out-of-frame shot are not in the picture, and a
      // person told nothing would either stop or clamp them to the edge.
      expect(text, contains('`${outOfFrame.id}` needs a word of its own'));
      expect(text, contains('outside the picture'));
      expect(text, contains('**negative**'));

      // The dark shot's phone never moved, so its corners are its session's.
      expect(text, contains('`${dark.id}` needs a word of its own'));
      expect(text, contains('four corners across unchanged'));
    });

    test('the checklist counts them rather than asserting a number', () {
      expect(renderChecklist(plan), contains('**8 shots**'));
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

  group('the filmed session, which is the real corpus', () {
    // The other plan in this file, and the opposite kind of thing: the
    // checklist above says what to go and shoot, this one says what was
    // already shot. It exists in code for the same reason the checklist does —
    // a sidecar is generated from a plan, never typed — and it earns its keep
    // twice over, because a real game's positions can be replayed and a
    // hand-written pile of checkers cannot.
    final session = buildRealSession();
    final filmed = session.shots;

    test('is one board, one light, one camera position', () {
      expect(session.name, kRealSessionName);
      expect(session.conditions.board, 'folding-case walnut');
      expect(session.conditions.lighting, 'daylight-backlit');
      expect(session.orientation, BoardOrientation.whiteHomeNear);
      expect(filmed.length, 10);
      for (final shot in filmed) {
        expect(shot.session, kRealSessionName, reason: shot.id);
        expect(shot.orientation, session.orientation, reason: shot.id);
        expect(shot.synthetic, isNull,
            reason: '${shot.id} is a photograph — nothing drew it');
      }
    });

    test('one calibration, and every other shot is read through it', () {
      expect(filmed.first.kind, ShotKind.calibration);
      expect(filmed.first.calibrateFrom, isNull);
      expect(filmed.first.board, BoardState.initial());
      for (final shot in filmed.skip(1)) {
        expect(shot.kind, ShotKind.position, reason: shot.id);
        expect(shot.calibrateFrom, filmed.first.id, reason: shot.id);
        expect(shot.expectsRefusal, isFalse, reason: shot.id);
        expect(shot.needsCorners, isFalse, reason: shot.id);
      }
    });

    test('the ledger is replayed through the rules engine, never typed in',
        () {
      // The whole reason the ledger is here rather than in ten sidecars. The
      // transcript recovered a move list from the footage; a move list can be
      // wrong in ways a position cannot be checked for by eye, and
      // `Game.replay` is the only judge that has no opinion about what was
      // filmed. Building the session at all runs it — an illegal turn throws
      // out of `buildRealSession` — and this pins that the boards written into
      // the sidecars are that replay's own output.
      final withLogs = filmed.where((s) => s.events != null).toList();
      expect(withLogs.length, 7,
          reason: 'seven positions come off the turn ledger. Turns 7 and 8 '
              'spent a day out of it — the 2026-08-21 audit read a checker as '
              'having left the board — and the 2026-08-22 measurement put that '
              'man on the 10-point and both turns back in');
      for (final shot in withLogs) {
        expect(shot.replayedBoard, shot.board, reason: shot.id);
        expect(shot.events!.first, isA<OpeningRollEvent>(), reason: shot.id);
      }
    });

    test('and each log is the one before it plus one turn', () {
      // Cumulative by construction, which is what makes the corpus a session
      // rather than seven unrelated positions — and what Task 7's play
      // matching will read: shot N's board differs from shot N-1's by exactly
      // the play the ledger names.
      final withLogs = filmed.where((s) => s.events != null).toList();
      for (var i = 1; i < withLogs.length; i++) {
        final earlier = withLogs[i - 1].events!;
        final later = withLogs[i].events!;
        expect(later.length, greaterThan(earlier.length),
            reason: withLogs[i].id);
        expect(later.take(earlier.length).map((e) => e.toJson()).toList(),
            earlier.map((e) => e.toJson()).toList(),
            reason: '${withLogs[i].id} is not ${withLogs[i - 1].id} continued');
      }
    });

    test('every position has thirty checkers on it, wherever they are', () {
      // The one arithmetic a replay cannot get wrong and a hand-read keyframe
      // can. The two end-game keyframes were counted off zoomed frames by a
      // person, so this is the check that the counting closed — and it is the
      // check that caught the 2026-08-21 audit's "a checker left the board"
      // reading being an accounting claim as well as an optical one: fifteen
      // men a side are on points in every window of this session.
      for (final shot in filmed) {
        expect(shot.board.checkerCount(Player.white), 15, reason: shot.id);
        expect(shot.board.checkerCount(Player.black), 15, reason: shot.id);
      }
    });

    test('the two board-only shots carry a board and no log at all', () {
      // Both are the end of the footage, which ran on past the ledger and was
      // not transcribable move by move — hands in shot, a hit nobody could pin
      // to a turn. What survived is a board read off zoomed frames. The schema
      // takes that as it stands: `events` is nullable, a null one emits as null
      // and reads back as null, and the harness scores occupancy off `board`
      // without ever asking how the board got there.
      //
      // **018 and 020 were here for exactly one day** and are replayed
      // positions again; see the ledger's 2026-08-22 note. The mechanism is
      // what this test is for, so it is pinned on the two shots that still need
      // it rather than on the four that briefly did.
      final keyframes =
          filmed.where((s) => s.events == null && s.kind != ShotKind.calibration)
              .toList();
      expect(keyframes.map((s) => s.id), <String>['066', '070']);
      for (final shot in keyframes) {
        expect(shot.replayedBoard, isNull, reason: shot.id);
        expect(shot.toJson()['events'], isNull, reason: shot.id);
        final decoded = CorpusShot.fromJson(
          jsonDecode(jsonEncode(shot.toJson())) as Map<String, dynamic>,
        );
        expect(decoded.events, isNull, reason: shot.id);
        expect(decoded.board, shot.board, reason: shot.id);
        expect(jsonEncode(decoded.toJson()), jsonEncode(shot.toJson()),
            reason: shot.id);
      }
    });

    test('the committed logs carry the two hits the game had', () {
      // A `CheckerMove` carries a hit FLAG as well as two points,
      // `CheckerMove.==` compares it, and Task 7's play matching compares
      // moves against an enumerated set of legal ones — so a log that reaches
      // the right board with every flag false is a trap laid for exactly the
      // corpus that has a real hit in it.
      //
      // The filmed game hits twice: turn 6's `1/7*` and turn 8's `11/20*`. The
      // logs are cumulative and turn 6's own window never came, so its flag
      // rides in two of them (018 and 020) and turn 8's in one — three flagged
      // hops over sixty. Pinned as a count so that a flag going missing means
      // something changed. Derived rather than annotated: the hit is read off
      // the point each hop lands on, as the replay walks the turn.
      expect(_hopFlags(filmed), (3, 60),
          reason: 'sixty hops across the seven cumulative logs, three of them '
              'carrying a hit flag');

      // The derivation itself is what the trap is about, so it stays tested on
      // a ledger written here as well — the filmed one is private, and a
      // fixture can put the hit on the FIRST hop of a turn, which is the case
      // the real one does not have. Not hand-annotated in either case: the flag
      // is read off the point each hop lands on, from the board as it stands
      // before that hop.
      final replayed = replayFilmedLedger(const <FilmedTurn>[
        (
          player: Player.white,
          die1: 4,
          die2: 2,
          hops: <(int, int)>[(13, 9), (24, 22)],
          notation: 'W 4-2: 13/9 24/22 (two blots left out)',
        ),
        (
          player: Player.black,
          die1: 6,
          die2: 3,
          hops: <(int, int)>[(19, 22), (17, 23)],
          notation: 'B 6-3: 19/22* 17/23',
        ),
      ]);
      final hit = <MoveEvent>[
        for (final event in replayed.last.log)
          if (event is MoveEvent) event,
      ].last;
      expect(hit.player, Player.black);
      expect(hit.move.checkerMoves.first.isHit, isTrue);
      expect(hit.move.checkerMoves.first.to, 21,
          reason: "White's blot stood on the 22-point, which is index 21");
      expect(hit.move.checkerMoves.last.isHit, isFalse,
          reason: 'the second hop of that turn lands on an empty point');
      expect(replayed.last.board.whiteBar, 1);
    });

    test('a ledger that stops being legal throws, naming the turn', () {
      // The net under the whole ledger, tested — otherwise it is a comment.
      // Turn 2 here asks Black to move a checker that is not on the board.
      expect(
        () => replayFilmedLedger(const <FilmedTurn>[
          (
            player: Player.white,
            die1: 4,
            die2: 2,
            hops: <(int, int)>[(8, 4), (6, 4)],
            notation: 'W 4-2: 8/4 6/4',
          ),
          (
            player: Player.black,
            die1: 6,
            die2: 4,
            hops: <(int, int)>[(3, 9), (9, 13)],
            notation: 'B 6-4: 3/9 9/13',
          ),
        ]),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('turn 2'), contains('B 6-4: 3/9 9/13')),
        )),
      );
    });

    test('066 is the bar shot — a Black checker sitting on the worn hinge',
        () {
      // The flagship of the whole corpus, and the reason it was kept. Every
      // other question about that hinge strip has been asked of an EMPTY one;
      // this is the object-versus-surface case in the wild, on the one board
      // whose bar is a rubbed ridge that already reads like checkers.
      final bar = filmed.firstWhere((s) => s.id == '066');
      expect(bar.board.blackBar, 1);
      expect(bar.board.whiteBar, 0);
    });

    test('nothing in this session is off the board, and the two keyframes are '
        'why that had to be measured', () {
      // **The 2026-08-23 correction, pinned cell by cell.** Both keyframes
      // were read off zooms, and the zooms lost the man standing at the BASE
      // of a near-half point — the wide end against the case's raised rim,
      // which hides three quarters of him. Two men per frame went missing that
      // way and the difference was written down as `whiteOff: 2`, which is the
      // one thing a hand-read board can get wrong that fifteen-a-side cannot
      // catch: a man counted off is still a man counted.
      //
      // Re-measured in cream pixel mass per point column on the full-res
      // frames, against the same columns in the eight windows before them:
      //
      // * 066's 1-point measures 1666 px where every earlier window measures
      //   0-380, and the blob's centroid inverts to board x 0.962 against the
      //   point's own centre of 0.961;
      // * 066's 7-point measures 8243 px topping at board y 0.864 — the
      //   two-man signature (the 8-point reads 8420-8923 for two and
      //   12337-14122 for three), not the one-man 1696 it shows at 013;
      // * 070's 1-point measures 1512 px in the same place;
      // * 070's 7-point measures 12771 px topping at 0.765, one whole pitch
      //   above 066's — three men.
      //
      // The pipeline's own reader is the independent witness on the 7-points:
      // it read *white x2* at 066 and *white x3* at 070 while the sidecars
      // said one and two, and those two contradictions disappear here. See
      // `kRealCorpusFloors` in `corpus_harness_test.dart` for what that did to
      // the scoreboard.
      for (final shot in filmed) {
        expect(shot.board.whiteOff, 0, reason: '${shot.id}: nothing in this '
            'session ever leaves the board');
        expect(shot.board.blackOff, 0, reason: shot.id);
      }

      final keyframes = <String, BoardState>{
        for (final id in <String>['066', '070'])
          id: filmed.firstWhere((s) => s.id == id).board,
      };
      // 1-based points to White's count on them, which is the whole claim.
      expect(<int, int>{
        for (var i = 0; i < 24; i++)
          if (keyframes['066']!.points[i] > 0) i + 1: keyframes['066']!.points[i],
      }, <int, int>{1: 1, 4: 3, 5: 2, 6: 2, 7: 2, 8: 3, 9: 1, 24: 1});
      expect(<int, int>{
        for (var i = 0; i < 24; i++)
          if (keyframes['070']!.points[i] > 0) i + 1: keyframes['070']!.points[i],
      }, <int, int>{1: 1, 4: 3, 5: 2, 6: 2, 7: 3, 8: 2, 9: 1, 22: 1});

      // And the corrected pair still differs by one legal turn's worth of
      // White pips — 8/7 and 24/22, a 2-1 — because the correction adds the
      // same two men to both frames rather than one to either. Corroboration,
      // not a claim about the gap: Black's cells differ by more than a single
      // turn can account for, which is why neither keyframe carries a log.
      int whiteOn(BoardState board, int index) =>
          board.points[index] > 0 ? board.points[index] : 0;
      var pips = 0;
      for (var i = 0; i < 24; i++) {
        pips += (whiteOn(keyframes['070']!, i) - whiteOn(keyframes['066']!, i)) *
            (i + 1);
      }
      expect(pips, -3, reason: "White's men moved three pips down the board "
          'between the two keyframes, which is a 2-1 and nothing else');
    });

    test('the four rolls the corpus can stand behind are the only dice claimed',
        () {
      // Dice values are ground truth and stay in the sidecars whatever the
      // reader currently manages. Four of the ten frames carry a pair this
      // session can stand behind; the other six carry no value, and — as of
      // 2026-08-23 — five of those six have dice sitting in them all the same.
      // See the `diceInFrame` test below for that distinction, which used to
      // be lost.
      //
      // **Three of the four were read off zooms and one is derived**, which is
      // a distinction worth keeping and now carries a machine-readable mark
      // (`diceDerived`) rather than only a sentence. 010's pair was misread as
      // 6-5 on 2026-08-21; it is 6-4, because a ten-pip one-man play out of
      // the 1-point with the 6-point blocked cannot have been thrown any other
      // way — the same "ground truth by construction" the boards get, applied
      // to the felt.
      //
      // **How much of a die's top this camera sees depends on where the die
      // lands**, and the batch's own wording was too broad about it.
      // ~~"This camera sits low enough that a die shows its front face and not
      // its top"~~ is true of the FAR half and false near the middle: measured
      // 2026-08-23, a die deep in the far half (010's pair at board v 0.23 to
      // 0.26, 008's at 0.23 to 0.28) presents a front face and a top 7-8 px
      // deep on a 21 px die, in which no pip pattern can be counted — while
      // 018's die at v 0.51, in the middle band, shows a clean **5** on its
      // top face. The scoped claim is the one that survives: this camera loses
      // a die's top in proportion to how far up the board it lies.
      final withDice = <String, String>{
        for (final shot in filmed.where((s) => s.dice != null))
          shot.id: '${shot.dice!.die1}-${shot.dice!.die2}',
      };
      expect(withDice, <String, String>{
        '003': '4-2',
        '005': '6-4',
        '010': '6-4',
        '013': '6-3',
      });
      // And each of them is the roll its own turn was played on, which is what
      // makes them checkable at all: a pair on the felt that contradicted the
      // ledger beside it would be two answers to one question.
      for (final shot in filmed.where((s) => s.dice != null)) {
        final roll = <int>[shot.dice!.die1, shot.dice!.die2]..sort();
        final rolls = <RollEvent>[
          for (final event in shot.events!)
            if (event is RollEvent) event,
        ];
        final played = rolls.isEmpty
            // Turn 1 is played on the opening roll, which is not a RollEvent.
            ? <int>[4, 2]
            : <int>[rolls.last.die1, rolls.last.die2];
        expect(roll, (played..sort()), reason: shot.id);
      }
    });

    test('"no roll claimed" and "no dice in the picture" are different '
        'questions, and only one frame answers yes to the second', () {
      // **The conflation `CorpusMetric.diceAbsence` was scoring**, fixed
      // 2026-08-23. Nine of these ten frames have dice somewhere in them and
      // four carry a value, so a metric whose denominator was "shots with no
      // certified roll" was asking "did the reader invent a roll?" of five
      // frames with real dice lying in them — paying it for missing them, and
      // set to go red the day it stopped.
      //
      // Only 001 is genuinely dice-free, and that is not luck: it is the
      // calibration hold, and a die present at calibration is learned as one
      // of the board's own surfaces and then invisible for the whole session.
      expect(<String, bool>{
        for (final shot in filmed) shot.id: shot.hasDiceInFrame,
      }, <String, bool>{
        '001': false,
        '003': true,
        '005': true,
        '008': true,
        '010': true,
        '013': true,
        '018': true,
        '020': true,
        '066': true,
        '070': true,
      });

      // Exactly one shot's value was DERIVED rather than read, and it says so
      // where a machine can see it.
      expect(filmed.where((s) => s.hasDerivedDice).map((s) => s.id),
          <String>['010']);
      expect(filmed.firstWhere((s) => s.id == '010').dice, Dice(6, 4));
      for (final shot in filmed.where((s) => s.dice == null)) {
        expect(shot.hasDerivedDice, isFalse,
            reason: '${shot.id} has no roll to have derived');
      }

      // Both fields are additive: they are written when the session sets them
      // and read back identically, and a sidecar that never heard of them
      // still answers both questions the old way.
      for (final shot in filmed) {
        final decoded = CorpusShot.fromJson(
          jsonDecode(jsonEncode(shot.toJson())) as Map<String, dynamic>,
        );
        expect(decoded.hasDiceInFrame, shot.hasDiceInFrame, reason: shot.id);
        expect(decoded.hasDerivedDice, shot.hasDerivedDice, reason: shot.id);
        expect(shot.toJson().containsKey('diceDerived'), shot.hasDerivedDice,
            reason: '${shot.id}: read-off-the-pips is the silent default');
      }
      final generated = flatten(buildCapturePlan()).first;
      expect(generated.toJson().containsKey('diceInFrame'), isFalse,
          reason: 'no generated sidecar has to be rewritten for this');
      expect(generated.hasDiceInFrame, generated.dice != null,
          reason: 'and absent has to mean the thing that is true of them');
    });

    test('only the calibration shot carries the board\'s measurements', () {
      final calibration = filmed.first;
      expect(calibration.dieSide, closeTo(0.021, 1e-9),
          reason: 'measured off a settled roll — this board\'s dice are a '
              'third of the synthetic bed\'s across');
      expect(calibration.proportions, isNull,
          reason: 'a folding case derives its widths from its eight points, '
              'so writing them as well would be two answers to one question');
      for (final shot in filmed.skip(1)) {
        expect(shot.dieSide, isNull, reason: shot.id);
        expect(shot.proportions, isNull, reason: shot.id);
        expect(shot.foldingCorners, isNull, reason: shot.id);
      }
    });

    test('the ids are the video windows the frames were cut from', () {
      // Provenance, and it is worth the oddity of a corpus whose ids have gaps
      // in them: 066 is frame 066 of the stable-window sweep, and anyone
      // holding the footage can go back to it.
      expect(filmed.map((s) => s.id).toList(),
          <String>['001', '003', '005', '008', '010', '013', '018', '020',
              '066', '070']);
      expect(filmed.map((s) => s.id).toSet().length, filmed.length);
      for (final shot in filmed) {
        expect(shot.id, matches(RegExp(r'^\d{3}$')), reason: shot.id);
        expect(shot.instructions.join(' '), contains('VID20260820105037'),
            reason: '${shot.id} does not say which footage it came from');
      }
    });

    test('every filmed sidecar survives JSON exactly', () {
      for (final shot in filmed) {
        final decoded = CorpusShot.fromJson(
          jsonDecode(jsonEncode(shot.toJson())) as Map<String, dynamic>,
        );
        expect(jsonEncode(decoded.toJson()), jsonEncode(shot.toJson()),
            reason: shot.id);
      }
    });
  });
}

/// How many of [shots]' hops carry a hit flag, and how many hops there are.
///
/// One helper for both corpora on purpose: the number that matters is the
/// comparison between them, and a hit flag is the sort of thing that goes
/// quietly missing on the corpus that was not generated.
(int hits, int hops) _hopFlags(Iterable<CorpusShot> shots) {
  var hops = 0, hits = 0;
  for (final shot in shots) {
    for (final event in shot.events ?? const <GameEvent>[]) {
      if (event is! MoveEvent) continue;
      for (final hop in event.move.checkerMoves) {
        hops++;
        if (hop.isHit) hits++;
      }
    }
  }
  return (hits, hops);
}
