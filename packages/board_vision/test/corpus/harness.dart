/// Running the pipeline over a corpus and writing down what it said.
///
/// The harness answers, per shot, exactly the questions a live session would
/// ask at that moment — and in the same order, through the same calibration.
/// That is the design's central bet made testable: perception is never asked an
/// open question, so a corpus that asked open ones would be scoring something
/// the app never does.
///
/// ## One calibration per session
///
/// A session's first shot is a bare starting position, and every later shot is
/// read through the calibration learned from it. If that calibration fails, the
/// rest of the session is **not scored** — recorded as skipped, with the
/// reason, and printed. Scoring later shots through a calibration that was
/// refused would be measuring the pipeline's behaviour on an input it already
/// declined.
///
/// ## What a shot is scored on
///
/// * a calibration shot — did calibration complete, and does the board confirm
///   as the starting position on the very frame it was learned from;
/// * a position shot — every region's colour and count against the sidecar,
///   plus the raw stack length behind each count;
/// * a dice shot — the pair, exactly, and nothing else;
/// * any shot with no dice — that no dice were invented;
/// * a degraded shot — that it was refused, by whichever instrument the
///   sidecar names.
///
/// ## Signals, not judgements
///
/// Alongside the scores it records numbers nothing is promised about: how far
/// each measured stack length sat from a whole checker before rounding, what
/// share of each frame was clipped, whether each frame's exposure still matched
/// its session's calibration. Task 4's reviewers exposed the first for this
/// purpose, and Task 9 will formalise the rest into the readability light. They
/// are printed so that a number can be watched drifting long before it becomes
/// a failure.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';

import 'capture_plan.dart';
import 'corpus_io.dart';
import 'scoreboard.dart';

/// Whether a pair was FOUND on a shot the sidecar says has dice, right or
/// wrong: 1 when the reader returned a reading, 0 when it declined.
///
/// The denominator is `CorpusMetric.dicePair`'s attempts, so between them the
/// two say found, right and refused. See [_scoreDice].
const String kDiceFoundSignal = 'dice found when a roll was there';

/// Whether the play identified correctly was written with DIFFERENT hops from
/// the one the sidecar records — the same position by another transit.
///
/// One in six on the filmed game, and none at all on generated plays, because a
/// generated play is drawn from the generator's own canonical list while a
/// filmed one is what a person's hand did. See [_PlayChain] for why that still
/// counts as right.
const String kTransitDifferedSignal = 'the transit was not the listed one';

/// Whether ONE region agreed with the game and a blind count of the same region
/// on the same frame did not.
///
/// The state-primed query's whole claim, as a number rather than an argument:
/// verification is handed K and only has to decide whether the picture
/// contradicts it, so it agrees on every region a blind count gets right plus
/// the band a blind count rounds away. This counts that band. Zero here and the
/// prior is buying nothing — see `CorpusMetric.regionVerified`.
const String kPriorRescuedSignal = 'the prior rescued a region';

/// The other direction: a region a blind count got RIGHT and verification
/// called wrong.
///
/// Should be zero by construction on the count axis, and is recorded because
/// "by construction" is how a claim survives its own refutation — colour and
/// presence are asked differently by the two instruments, so this is not a
/// theorem, it is a measurement.
const String kPriorLostSignal = 'the prior lost a region';

/// Scores every shot in [directory], grouped into its sessions.
///
/// [name] is what the report calls this corpus. An absent or empty directory
/// yields an empty scoreboard carrying a note — never a failure, because "no
/// photographs yet" is a legitimate state of the real corpus and a red build
/// for it would only teach everyone to ignore red builds.
Scoreboard scoreCorpus(Directory directory, {required String name}) {
  final board = Scoreboard(name);
  final shots = loadSidecars(directory);
  if (shots.isEmpty) {
    board.notes.add(
      'no sidecars in ${directory.path} — nothing was scored. This is the '
      'expected state of the real corpus until the capture checklist has been '
      'shot (the plan\'s Task 6).',
    );
    return board;
  }

  board
    ..shots = shots.length
    ..bytes = directoryBytes(directory);

  final sessions = <String, List<CorpusShot>>{};
  for (final shot in shots) {
    (sessions[shot.session] ??= <CorpusShot>[]).add(shot);
  }
  board.sessions = sessions.length;

  for (final entry in sessions.entries) {
    _scoreSession(board, directory, entry.key, entry.value);
  }
  return board;
}

void _scoreSession(
  Scoreboard board,
  Directory directory,
  String name,
  List<CorpusShot> shots,
) {
  final calibrationShot = shots.firstWhere(
    (s) => s.kind == ShotKind.calibration,
    orElse: () => throw StateError('session $name has no calibration shot'),
  );

  final calibrationFrame = _frameOf(board, directory, calibrationShot);
  if (calibrationFrame == null) return;
  if (calibrationShot.corners == null &&
      calibrationShot.foldingCorners == null) {
    for (final shot in shots) {
      board.skip(
        shot.id,
        'session $name has no corners yet — see corners.json',
      );
    }
    return;
  }

  final result = _calibrateShot(calibrationFrame, calibrationShot);
  board.record(
    CorpusMetric.calibration,
    ok: result.ok,
    slices: _slicesOf(calibrationShot),
    detail: '${calibrationShot.id} ($name): ${result.message}',
  );

  if (!result.ok) {
    for (final shot in shots.where((s) => s.id != calibrationShot.id)) {
      board.skip(
        shot.id,
        'session $name did not calibrate (${result.problem!.name}), so '
        'nothing downstream of it means anything',
      );
    }
    return;
  }

  final calibration = result.calibration!;
  final vision = BoardVision(calibration);
  board
    ..signal('clipped fraction', calibration.fingerprint.clippedFraction)
    ..signal('board luma at calibration', calibration.fingerprint.meanLuma)
    ..signal('board luma spread', calibration.fingerprint.lumaSpread);

  final confirmed = vision.confirmStartingPosition(calibrationFrame);
  board.record(
    CorpusMetric.startConfirmed,
    ok: confirmed.agrees,
    slices: _slicesOf(calibrationShot),
    detail: '${calibrationShot.id} ($name): ${confirmed.message}',
  );
  _scoreOccupancy(board, vision, calibrationFrame, calibrationShot);
  _scoreResync(board, vision, calibrationFrame, calibrationShot);
  _scoreDice(board, vision, calibrationFrame, calibrationShot);

  // Play identification walks the same pass, keeping the previous shot's frame,
  // so no image is decoded twice.
  final plays = _PlayChain(board, vision, name);

  for (final shot in shots) {
    final isCalibration = shot.id == calibrationShot.id;
    final frame =
        isCalibration ? calibrationFrame : _frameOf(board, directory, shot);
    if (frame == null) {
      plays.breakChain();
      continue;
    }

    if (shot.expectsRefusal) {
      _scoreRefusal(board, calibration, frame, shot);
      // A deliberately-spoiled shot is not a position: it pairs with neither
      // neighbour, and the two on either side of it are not consecutive.
      plays.breakChain();
      continue;
    }

    if (!isCalibration) {
      // The two readability signals the Task 4 reviewers asked to see side by
      // side: a frame lit 40% over its calibration passes `exposureMatches`
      // while `clippedFraction` catches it, and Task 9 needs both to decide
      // what the light means. Recorded per shot, judged by nothing yet.
      final fingerprint =
          CalibrationFingerprint.fromFrame(frame, calibration.geometry);
      board
        ..signal('clipped fraction', fingerprint.clippedFraction)
        ..signal(
          'exposure still matched',
          calibration.fingerprint.exposureMatches(fingerprint) ? 1 : 0,
        )
        ..signal(
          'geometry still matched',
          calibration.fingerprint.geometryMatches(fingerprint) ? 1 : 0,
        );

      _scoreOccupancy(board, vision, frame, shot);
      _scoreResync(board, vision, frame, shot);
      _scoreDice(board, vision, frame, shot);
    }

    plays.offer(shot, frame);
  }

  plays.finish();
}

/// The query the whole mode turns on, over every pair of a session's shots that
/// is genuinely **one turn apart**.
///
/// ## Which pairs those are, and why the sidecars decide it
///
/// Not "two shots next to each other on disk". A corpus of independent
/// positions has plenty of those and none of them is a play: the seeded
/// synthetic sessions photograph two positions from two different playouts, and
/// the real session's windows skip turns wherever a hand was still in shot.
/// Scoring those pairs would be asking the matcher which of seven legal plays
/// produced three turns of backgammon.
///
/// So the pairing is derived from the event logs the sidecars already carry: a
/// pair qualifies when the later shot's log is the earlier shot's log plus
/// **exactly one** move, and replaying the earlier prefix reproduces the earlier
/// shot's committed board. That is ground truth by construction for all three
/// things the matcher needs — the mover, the legal-play list the app would have
/// handed it at that moment, and the play that was actually made — and it is
/// checked rather than asserted, so a pair that does not qualify is named in
/// the notes rather than dropped.
///
/// The session's shots are offered to one of these in capture order, each with
/// the frame the pass already decoded, so no image is read twice.
class _PlayChain {
  final Scoreboard board;
  final BoardVision vision;
  final String session;

  /// The pairs that were adjacent but not one turn apart, by id.
  final List<String> notPairs = <String>[];

  int scored = 0;
  CorpusShot? _previous;
  Frame? _previousFrame;

  _PlayChain(this.board, this.vision, this.session);

  /// Nothing after this can be paired with anything before it — a missing
  /// photograph, or a shot the corpus deliberately spoiled.
  void breakChain() {
    _previous = null;
    _previousFrame = null;
  }

  void offer(CorpusShot shot, Frame frame) {
    final earlier = _previous;
    final earlierFrame = _previousFrame;
    _previous = shot;
    _previousFrame = frame;
    if (earlier == null || earlierFrame == null) return;

    final turn = _oneTurnApart(earlier, shot);
    if (turn == null) {
      notPairs.add('${earlier.id}->${shot.id}');
      return;
    }
    _score(earlier, earlierFrame, shot, frame, turn);
  }

  void finish() {
    if (scored == 0) {
      board.notes.add(
        '$session: no two shots in it are one turn apart, so no play could be '
        'identified. '
        '(${notPairs.isEmpty ? 'nothing to pair' : notPairs.join(', ')})',
      );
    } else if (notPairs.isNotEmpty) {
      board.notes.add(
        '$session: $scored consecutive pairs are one turn apart and were '
        'scored; ${notPairs.length} are not and were not '
        '(${notPairs.join(', ')}).',
      );
    }
  }

  void _score(
    CorpusShot earlier,
    Frame earlierFrame,
    CorpusShot shot,
    Frame frame,
    ({Player mover, List<Move> legal, Move played}) turn,
  ) {
    final matches = vision.matchLegalPlay(
      frame,
      earlier.board,
      turn.mover,
      turn.legal,
      beforeFrame: earlierFrame,
    );
    final top = matches.first;
    // **Right means the right POSITION, not the right hops**, and the real
    // corpus is what settled that.
    //
    // Turn 3 of the filmed game is `W 5-2: 13/8 8/6`, which is what the
    // transcript recorded because it is what the player's hand did. That exact
    // hop multiset is not in `state.legalMoves` at all: the generator dedupes
    // by RESULTING POSITION and lists `13/11 11/6` as the representative of
    // that position, the two being the same play by a different transit. So
    // comparing hops would score the matcher against an answer it was never
    // offered, and would call a correct identification a miss.
    //
    // It is also what the game itself means. `GameState.play` runs any
    // decomposition through `canonicalPlay` before folding it, so `13/8 8/6`
    // and `13/11 11/6` enter the authoritative state as the same move. And it
    // is the only thing two settled frames can possibly say: an intermediate
    // transit leaves no trace in either of them.
    final target = earlier.board.applyMove(turn.mover, turn.played);
    final right = top.after == target;
    final rank = matches.indexWhere((m) => m.after == target);
    scored++;
    board
      ..record(
        CorpusMetric.legalPlay,
        ok: right,
        slices: _slicesOf(shot)..['mover'] = turn.mover.name,
        detail: '${earlier.id}->${shot.id}: played ${turn.played}, ranked '
            '${rank + 1} of ${matches.length}; top was ${top.play} at '
            '${top.confidence.toStringAsFixed(3)} '
            '(cost ${top.cost.toStringAsFixed(2)}, instability '
            '${top.instability.toStringAsFixed(2)})',
      )
      // The same attempt, asked the other question: would the session have
      // acted on this, or put the candidate list in front of the user? A rate
      // of its own rather than a signal, because it is floored — see
      // `kRealCorpusFloors`.
      ..record(
        CorpusMetric.legalPlayActed,
        ok: top.plausible,
        slices: _slicesOf(shot)..['mover'] = turn.mover.name,
        detail: '${earlier.id}->${shot.id}: ${top.play} came back at '
            '${top.confidence.toStringAsFixed(3)}, under the threshold, so '
            'the session would have prompted rather than acted',
      )
      // How often the transit the player's hand actually used is NOT the one
      // the generator lists. Zero on a corpus of generated plays and one in
      // six on the filmed game, which is the ambiguity-honesty case turning
      // up in the wild rather than in a fixture — see the comment above.
      ..signal(
        kTransitDifferedSignal,
        right && !top.play.sameAs(turn.played) ? 1 : 0,
      )
      ..signal('legal-play candidates', turn.legal.length.toDouble())
      ..signal('legal-play top confidence', top.confidence)
      ..signal('legal-play top cost', top.cost)
      ..signal('legal-play instability', top.instability);

    // The same pair, asked the OTHER state-primed question. A session that has
    // just dictated a move holds exactly this: the position the play should
    // have left behind, and a settled frame of the board somebody placed it on.
    // `target` is that position by construction — it is the earlier shot's
    // committed board with the logged move applied — so an attempt here is a
    // CORRECT board being asked to verify, which is what the spec's ≥95%
    // promises.
    final verified = vision.verifyExpectedBoard(frame, target);
    board.record(
      CorpusMetric.placementVerified,
      ok: verified.agrees,
      slices: _slicesOf(shot)..['mover'] = turn.mover.name,
      detail: '${earlier.id}->${shot.id}: after ${turn.played}, '
          '${verified.message}',
    );
  }
}

/// What [after] is to [before] when exactly one turn separates them, or null.
///
/// Returns the three things the matcher has to be handed: whose turn it was,
/// the legal plays the rules engine would have offered at that moment, and the
/// play that was actually made. All three come out of replaying the later
/// shot's own log, so none of them is a second opinion about the corpus.
({Player mover, List<Move> legal, Move played})? _oneTurnApart(
  CorpusShot before,
  CorpusShot after,
) {
  final log = after.events;
  // A shot with no log carries a board and no story — the two end-game
  // keyframes of the real corpus. Nothing can be paired with it.
  if (log == null) return null;
  final prefix = before.events?.length ?? 0;
  if (log.length <= prefix) return null;

  // The earlier shot must really be the position the later shot's log passes
  // through at that point — otherwise the two are from different games.
  final at = prefix == 0
      ? BoardState.initial()
      : Game.replay(log.sublist(0, prefix)).state.board;
  if (at != before.board) return null;

  // Exactly one move in between, and it is the last thing that happened.
  final between = log.sublist(prefix);
  if (between.whereType<MoveEvent>().length != 1) return null;
  final last = between.last;
  if (last is! MoveEvent) return null;

  final state = Game.replay(log.sublist(0, log.length - 1)).state;
  if (state.phase != GamePhase.moving) return null;
  // A dance has no candidates and nothing to identify; the session announces
  // it and passes the turn.
  final legal = state.legalMoves;
  if (legal.isEmpty) return null;
  return (mover: state.turn, legal: legal, played: last.move);
}

/// Calibrates [frame] the way [shot]'s own sidecar says its board is shaped.
///
/// Two doors, and which one a shot goes through is a property of the board it
/// was photographed on:
///
/// * eight points in the sidecar means a **folding case** — two leaf planes
///   and a raised hinge. Its widths are derived from those eight, so nothing
///   else is consulted;
/// * otherwise one plane through the four corners, at the widths the sidecar
///   measured. Absent means the usual shape.
///
/// One board per session, so one of these per session, taken from the shot the
/// session calibrates through. Reading a folding case as one plane — or a
/// folding case's shots through the standard widths — scores every region out
/// of true, which is the whole reason both fields exist.
CalibrationResult _calibrateShot(Frame frame, CorpusShot shot) {
  final folding = shot.foldingCorners;
  if (folding != null) {
    return BoardVision.calibrateFolding(
      frame: frame,
      corners: folding,
      orientation: shot.orientation,
      dieSide: shot.dieSide ?? BoardCalibration.defaultDieSide,
    );
  }
  return BoardVision.calibrate(
    frame: frame,
    corners: shot.corners!,
    orientation: shot.orientation,
    proportions: shot.proportions ?? BoardProportions.standard,
    dieSide: shot.dieSide ?? BoardCalibration.defaultDieSide,
  );
}

/// A shot the corpus says perception must decline.
void _scoreRefusal(
  Scoreboard board,
  BoardCalibration calibration,
  Frame frame,
  CorpusShot shot,
) {
  final slices = _slicesOf(shot)..['refusal'] = shot.expectRefusal!.name;
  switch (shot.expectRefusal!) {
    case ExpectedRefusal.calibration:
      if (shot.corners == null && shot.foldingCorners == null) {
        board.skip(shot.id, 'a calibration-refusal shot needs its own corners');
        return;
      }
      final attempt = _calibrateShot(frame, shot);
      board.record(
        CorpusMetric.expectedRefusal,
        ok: !attempt.ok,
        slices: slices,
        detail: '${shot.id}: calibration succeeded on a shot the corpus '
            'calls unreadable (${shot.refusalReason})',
      );
    case ExpectedRefusal.geometry:
      // The board is no longer where the session left it. Nothing here reads
      // the position at all — the question is only whether the pipeline
      // notices that its own calibration has stopped being true, which is the
      // session-long contract the spec makes of calibration.
      final now =
          CalibrationFingerprint.fromFrame(frame, calibration.geometry);
      board.record(
        CorpusMetric.expectedRefusal,
        ok: !calibration.fingerprint.geometryMatches(now),
        slices: slices,
        detail: '${shot.id}: the board moved and the fingerprint still '
            'matched, so the session would have gone on reading regions in '
            'the wrong place',
      );
  }
}

/// Every region of the board, against what the sidecar says is on it.
void _scoreOccupancy(
  Scoreboard board,
  BoardVision vision,
  Frame frame,
  CorpusShot shot,
) {
  final occupancy = vision.occupancyIn(frame);
  final stacks = vision.calibration.stacks;
  final expected = shot.board;

  void score(RoiId region, int count, CheckerColor colour, String kind) {
    final reading = region == RoiId.bar && colour != CheckerColor.none
        ? occupancy.readFor(region, colour)
        : occupancy.read(region);
    final slices = _slicesOf(shot)
      ..['region'] = kind
      ..['half'] = region.pointIndex < 0
          ? 'not a point'
          : region.pointIndex <= 11
              ? 'near half'
              : 'far half';

    final where = region.pointIndex >= 0
        ? 'the ${region.pointIndex + 1}-point'
        : region.name;
    board
      ..record(
        CorpusMetric.regionColour,
        ok: reading.color == colour,
        slices: slices,
        detail: '${shot.id} $where: expected ${colour.name}, '
            'read ${reading.color.name}',
      )
      ..record(
        CorpusMetric.regionOccupancy,
        ok: reading.color == colour && reading.count == count,
        slices: slices,
        detail: '${shot.id} $where: expected ${colour.name} x$count, read '
            '${reading.color.name} x${reading.count} '
            '(reach ${reading.reach.toStringAsFixed(3)} = '
            '${stacks.heightOf(reading.reach).toStringAsFixed(2)} checkers)',
      );

    if (count > 0 && reading.reach > 0) {
      // The measurement behind the count, before rounding. On a noiseless bed
      // this is exactly zero for every region — which is the identity Task 4's
      // reviewer found and the degraded corpus exists to break.
      final height = stacks.heightOf(reading.reach);
      board
        ..signal('stack height error (checkers)', (height - count).abs())
        // The identity, checked where it is actually scored: how often would
        // `floor()` in place of `round()` change the answer. Zero here and the
        // whole corpus could not fail a wrong line of arithmetic, which is the
        // failure mode this corpus was built to escape.
        ..signal(
          'rounding decided the count',
          math.max(1, height.floor()) == reading.count ? 0 : 1,
        )
        ..signal('occupied region mass', reading.mass)
        ..signal('occupied region confidence', reading.confidence);
    } else if (count == 0) {
      board.signal('empty region confidence', reading.confidence);
    }
  }

  for (var i = 0; i < 24; i++) {
    final signed = expected.points[i];
    score(
      RoiId.point(i),
      signed.abs(),
      signed == 0
          ? CheckerColor.none
          : signed > 0
              ? CheckerColor.white
              : CheckerColor.black,
      'point',
    );
  }
  for (final (region, count, colour) in <(RoiId, int, CheckerColor)>[
    (RoiId.bar, expected.whiteBar, CheckerColor.white),
    (RoiId.bar, expected.blackBar, CheckerColor.black),
  ]) {
    if (count == 0) continue;
    score(region, count, colour, 'bar');
  }
  // The trays, on a board that has any. A folding case has no wells at all —
  // borne-off checkers leave it altogether — so there is nothing in the
  // picture to score, and asking would be scoring a region that does not
  // exist. Said out loud when the position actually has checkers off, because
  // a denominator that quietly shrank is how a corpus stops testing something.
  if (vision.calibration.atlas.hasTrays) {
    for (final (region, count, colour) in <(RoiId, int, CheckerColor)>[
      (RoiId.offWhite, expected.whiteOff, CheckerColor.white),
      (RoiId.offBlack, expected.blackOff, CheckerColor.black),
    ]) {
      score(region, count, count == 0 ? CheckerColor.none : colour, 'tray');
    }
  } else if (expected.whiteOff + expected.blackOff > 0) {
    board.notes.add(
      '${shot.id}: ${expected.whiteOff + expected.blackOff} checkers borne '
      'off a board with no bear-off wells. They leave the board altogether on '
      'a folding case, so nothing in the picture can be scored for them.',
    );
  }
}

/// The whole board, re-read against the position the sidecar says is on it.
///
/// The drift-recovery query: the game holds an authoritative state, something
/// has stopped adding up, and the session asks a single frame whether the board
/// in front of it is still that state. Every shot gets one attempt, the
/// calibration frame included — a session's very first belief check is this
/// same read.
///
/// Scored two ways over the same call, and the pair is the point:
///
/// * **per board**, which is what the spec's table promises and what a session
///   actually acts on — one contradicted region and the attempt has failed;
/// * **per region**, so that the state-primed read can be set against the blind
///   one. Regions that disagree are recorded either way, so the report names
///   them rather than reporting a rate to argue about.
///
/// ## The two per-region rows do NOT share a denominator
///
/// [CorpusMetric.regionVerified] and [CorpusMetric.regionOccupancy] count
/// different things and their totals must not be compared as if they did. This
/// row asks **both ends of the bar on every shot**, because a man left on the
/// bar is exactly the drift the query exists to find; `_scoreOccupancy` scores
/// a bar side only when the game puts men on it. On the real corpus that is
/// 260 reads against 241, and the nineteen extra are bare-bar agreements — free
/// marks that flatter this row by about a point.
///
/// So there are two honest comparisons and the harness carries both:
///
/// * the **point** slice of each row, which is the same 240 reads on both
///   sides — the like-for-like rate, printed under every run;
/// * [kPriorRescuedSignal] and [kPriorLostSignal], computed below on identical
///   `(region, side)` pairs one at a time, which is the same question asked
///   without any denominator at all.
void _scoreResync(
  Scoreboard board,
  BoardVision vision,
  Frame frame,
  CorpusShot shot,
) {
  final verified =
      BoardVerifier(vision.calibration, frame).verify(shot.board);
  board.record(
    CorpusMetric.boardResynced,
    ok: verified.agrees,
    slices: _slicesOf(shot),
    detail: '${shot.id}: ${verified.message}',
  );

  // The blind reading of the same frame, for the comparison. Built once here
  // rather than per region — it is the same reader `_scoreOccupancy` uses.
  final occupancy = vision.occupancyIn(frame);

  for (final region in verified.regions) {
    if (region.verdict == RegionVerdict.unobservable) continue;
    final slices = _slicesOf(shot)
      ..['region'] = region.pointNumber != null
          ? 'point'
          : region.region == RoiId.bar
              ? 'bar'
              : 'tray'
      ..['half'] = region.region.pointIndex < 0
          ? 'not a point'
          : region.region.pointIndex <= 11
              ? 'near half'
              : 'far half';
    board.record(
      CorpusMetric.regionVerified,
      ok: !region.disagrees,
      slices: slices,
      detail: '${shot.id} ${region.message} '
          '(${region.kind?.name ?? 'agreed'}, height '
          '${region.observedHeight.toStringAsFixed(2)}, reach '
          '${region.reach.toStringAsFixed(4)})',
    );

    // What a blind count says about the very same region, so the two claims
    // can be compared one region at a time.
    final expectedColour = region.expected == 0
        ? CheckerColor.none
        : region.side;
    final blind = region.side == CheckerColor.none
        ? occupancy.read(region.region)
        : occupancy.readFor(region.region, region.side);
    final blindRight =
        blind.color == expectedColour && blind.count == region.expected;
    board
      ..signal(kPriorRescuedSignal, !region.disagrees && !blindRight ? 1 : 0)
      ..signal(kPriorLostSignal, region.disagrees && blindRight ? 1 : 0);
  }
}

/// The roll, or the absence of one.
void _scoreDice(
  Scoreboard board,
  BoardVision vision,
  Frame frame,
  CorpusShot shot,
) {
  final reading = vision.readDice(frame);
  final slices = _slicesOf(shot);

  if (shot.dice == null) {
    board.record(
      CorpusMetric.diceAbsence,
      ok: reading == null,
      slices: slices,
      detail: '${shot.id}: read $reading on a board with no dice on it',
    );
    return;
  }

  final expected = <int>[shot.dice!.die1, shot.dice!.die2]..sort();
  final got = reading == null
      ? null
      : (<int>[reading.first.face, reading.second.face]..sort());
  board.record(
    CorpusMetric.dicePair,
    ok: got != null && got[0] == expected[0] && got[1] == expected[1],
    slices: slices,
    detail: '${shot.id}: expected ${expected.join('-')}, '
        '${got == null ? 'found no pair' : 'read ${got.join('-')}'}',
  );
  // A pair that was not read is one of two completely different events, and
  // the rate alone cannot tell them apart: the reader found two dice and read
  // the wrong faces, or it found nothing and declined. The first is a misread
  // entering the authoritative game state; the second is the refusal the
  // design asks for, and a session recovers from it by asking for another
  // roll. Recorded as a signal so both corpora carry the split and the report
  // can say found / right / refused instead of one number.
  board.signal(kDiceFoundSignal, reading == null ? 0 : 1);
  if (reading != null) {
    // Confidence has no ceiling by design — it is how much signal the frame
    // carried, not a probability — so it is watched, never thresholded here.
    board.signal('dice confidence', reading.confidence);
    board.signal(
      'dice size disagreement',
      1 -
          math.min(reading.first.span, reading.second.span) /
              math.max(reading.first.span, reading.second.span),
    );
  }
}

Frame? _frameOf(Scoreboard board, Directory directory, CorpusShot shot) {
  final file = imageFileFor(directory, shot);
  if (file == null) {
    board.skip(shot.id, 'no image beside the sidecar');
    return null;
  }
  return decodeCorpusImage(file);
}

/// The dimensions every record is filed under. The spec asks for accuracy per
/// board, per lighting condition and per half; palette and seating are the
/// synthetic corpus's own axes and cost nothing to carry.
Map<String, String> _slicesOf(CorpusShot shot) => <String, String>{
      'board': shot.capture.board,
      'lighting': shot.capture.lighting,
      'seating': shot.orientation.name,
      if (shot.synthetic != null) 'palette': shot.synthetic!.palette,
      'session': shot.session,
    };
