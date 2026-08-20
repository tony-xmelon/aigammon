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

import 'package:board_vision/board_vision.dart';

import 'capture_plan.dart';
import 'corpus_io.dart';
import 'scoreboard.dart';

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
  if (calibrationShot.corners == null) {
    for (final shot in shots) {
      board.skip(
        shot.id,
        'session $name has no corners yet — see corners.json',
      );
    }
    return;
  }

  // One board per session, so one set of proportions per session, taken from
  // the shot the session calibrates through. Absent means the usual shape;
  // present means somebody measured a folding case off this very frame, and
  // reading its shots through the standard widths would score every region a
  // column out of true.
  final proportions =
      calibrationShot.proportions ?? BoardProportions.standard;
  final result = BoardVision.calibrate(
    frame: calibrationFrame,
    corners: calibrationShot.corners!,
    orientation: calibrationShot.orientation,
    proportions: proportions,
  );
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
  _scoreDice(board, vision, calibrationFrame, calibrationShot);

  for (final shot in shots) {
    if (shot.id == calibrationShot.id) continue;
    final frame = _frameOf(board, directory, shot);
    if (frame == null) continue;

    if (shot.expectsRefusal) {
      _scoreRefusal(board, calibration, frame, shot);
      continue;
    }

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
    _scoreDice(board, vision, frame, shot);
  }
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
      if (shot.corners == null) {
        board.skip(shot.id, 'a calibration-refusal shot needs its own corners');
        return;
      }
      final attempt = BoardVision.calibrate(
        frame: frame,
        corners: shot.corners!,
        orientation: shot.orientation,
        proportions: shot.proportions ?? BoardProportions.standard,
      );
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
