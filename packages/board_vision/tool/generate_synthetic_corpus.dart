/// Renders the capture plan's positions as photographs a camera might have
/// taken, and commits them as the synthetic half of the corpus.
///
/// ```
/// dart run tool/generate_synthetic_corpus.dart [--out test/corpus/synthetic]
/// ```
///
/// ## Why a synthetic corpus at all
///
/// Because the real one does not exist until someone has spent an afternoon
/// with two boards and a phone, and everything downstream of Task 5 — the play
/// matcher, the board verifier, the readability checks — needs a corpus to be
/// scored against on every commit. This one runs in CI, is regenerated from a
/// seed, and covers axes a person cannot easily shoot: three boards whose
/// colours have nothing in common, both seatings, three viewpoints, and
/// lighting from 0.65 to 1.05 of nominal.
///
/// ## Why it is deliberately spoiled
///
/// A flat render scores 100% on everything by arithmetic rather than by
/// accuracy — Task 4's reviewer proved it, and `test/degradation_test.dart`
/// holds the line. Each shot therefore gets sub-pixel corner jitter (once per
/// *session*, because a board does not move between two photographs), a
/// gaussian blur, additive grain, and finally JPEG compression, which is a
/// degradation in its own right and the same one every real photograph
/// carries.
///
/// ## What it is not
///
/// It is not evidence that Buddy Mode works. The renderer paints flat discs
/// with no rims, no gloss, no shadows, and dice that are squares rather than
/// cubes seen at an angle. It cannot fail in any of the ways a photograph will.
/// Its job is to keep the harness honest between here and the Task 6 gate, and
/// to make a regression fail CI; the gate is where the numbers start meaning
/// something.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';

import '../test/corpus/capture_plan.dart';
import '../test/corpus/corpus_io.dart';
import '../test/synthetic/board_renderer.dart';

/// What each session is rendered as. One palette per seating pair and one quad
/// per palette pair, so that no two axes are confounded: every palette is seen
/// from both seats and from two different viewpoints, and every viewpoint sees
/// two different palettes.
typedef _SessionLook = ({String palette, BoardQuad quad, double gain});

const Map<String, _SessionLook> _looks = <String, _SessionLook>{
  'A-daylight': (palette: 'classic', quad: kCorpusSteepQuad, gain: 1.05),
  'A-lamp': (palette: 'blue-red', quad: kCorpusLowQuad, gain: 0.85),
  'A-dim': (
    palette: 'low-contrast wood',
    quad: kCorpusOffAxisQuad,
    gain: 0.65,
  ),
  'B-daylight': (palette: 'classic', quad: kCorpusLowQuad, gain: 1.0),
  'B-lamp': (palette: 'blue-red', quad: kCorpusOffAxisQuad, gain: 0.8),
  'B-dim': (
    palette: 'low-contrast wood',
    quad: kCorpusSteepQuad,
    gain: 0.65,
  ),
};

/// How dark "too dark" is. Measured: at this gain, with the corpus's grain,
/// all three palettes fail to calibrate — the board and the men on it have
/// squeezed into the same few sensor values.
const double _tooDarkGain = 0.12;

/// How far the board slides out of the picture for the half-out-of-frame shot,
/// as a fraction of the frame's width.
const double _outOfFrameShift = -0.38;

/// The knock, in pixels. Measured: the fingerprint catches a slide of eight
/// pixels, so this is comfortably past the threshold without being a different
/// photograph altogether.
const double _bumpShiftX = 18;
const double _bumpShiftY = -12;

Future<void> main(List<String> args) async {
  final outPath = _option(args, '--out') ?? 'test/corpus/synthetic';
  final out = Directory(outPath);
  if (out.existsSync()) {
    // A stale image whose sidecar has moved on is worse than no image: the
    // harness would score last week's render against this week's truth.
    out.deleteSync(recursive: true);
  }
  out.createSync(recursive: true);

  final sessions = buildCapturePlan();
  var written = 0;
  final perSession = <String, int>{};

  for (final session in sessions) {
    final look = _looks[session.name];
    if (look == null) {
      throw StateError('no synthetic look for session ${session.name}');
    }
    // One jitter for the whole session: the board and the phone stay where
    // they were put, and the sub-pixel offset they happen to sit at is a
    // property of the setup rather than of each shutter press.
    final sessionQuad = jitterQuad(
      look.quad,
      kCorpusDegradation.quadJitter,
      _seedOf(session.name),
    );

    for (final shot in session.shots) {
      final rendered = _render(shot, session, look, sessionQuad);
      File('${out.path}/${shot.id}.jpg')
          .writeAsBytesSync(encodeCorpusJpeg(imageOfFrame(rendered.frame)));
      writeSidecar(out, rendered.shot);
      written++;
      perSession[session.name] = (perSession[session.name] ?? 0) + 1;
    }
  }

  final bytes = directoryBytes(out);
  stdout
    ..writeln('Wrote $written shots to ${out.path}.')
    ..writeln();
  for (final session in sessions) {
    final look = _looks[session.name]!;
    stdout.writeln('  ${session.name.padRight(12)} '
        '${perSession[session.name].toString().padLeft(2)} shots  '
        '${look.palette.padRight(18)} gain ${look.gain}  '
        '${session.orientation.name}');
  }
  stdout
    ..writeln()
    ..writeln('  ${megabytes(bytes)} committed '
        '(budget ${megabytes(kCorpusByteBudget)}, '
        '${(100 * bytes / kCorpusByteBudget).round()}% of it)');
  if (bytes > kCorpusByteBudget) {
    stdout.writeln('  WARNING: over the spec\'s corpus budget.');
  }
}

/// One shot, rendered, with the sidecar filled in to match what was drawn.
({Frame frame, CorpusShot shot}) _render(
  CorpusShot shot,
  CaptureSession session,
  _SessionLook look,
  BoardQuad sessionQuad,
) {
  final palette = BoardPalette.all.firstWhere((p) => p.name == look.palette);
  final seed = _seedOf(shot.id);

  var gain = look.gain;
  var quad = sessionQuad;
  var board = shot.board;
  var carriesCorners = shot.kind == ShotKind.calibration;

  if (shot.expectRefusal == ExpectedRefusal.calibration) {
    // Its own calibration attempt, so it carries its own corners — and they
    // are honest ones: they say where the board really is, which is the point.
    // A refusal earned by lying about the corners would prove nothing.
    carriesCorners = true;
    board = BoardState.initial();
    if (shot.refusalReason!.contains('outside the frame')) {
      quad = _translated(sessionQuad, _outOfFrameShift * kFrameWidth, 0);
    } else {
      gain = _tooDarkGain;
    }
  } else if (shot.expectRefusal == ExpectedRefusal.geometry) {
    // Read through the session's calibration, which is exactly what makes it
    // a drift shot rather than a bad-calibration shot: the corners the session
    // learned no longer describe where the board is.
    carriesCorners = false;
    board = BoardState.initial();
    quad = _translated(sessionQuad, _bumpShiftX, _bumpShiftY);
  }

  final placements = shot.dice == null
      ? const <DicePlacement>[]
      : _placeDice(shot.dice!, board, seed);

  final rendered = renderShot(
    board: board,
    palette: palette,
    lightingGain: gain,
    orientation: session.orientation,
    dicePlacements: placements.isEmpty ? null : placements,
    quad: quad,
    degradation: ShotDegradation(
      noise: kCorpusDegradation.noise,
      blurSigma: kCorpusDegradation.blurSigma,
      seed: seed,
    ),
  );

  return (
    frame: rendered.frame,
    shot: shot.copyWith(
      corners: carriesCorners ? rendered.groundTruthQuad : null,
      synthetic: SyntheticRecipe(
        palette: palette.name,
        lightingGain: gain,
        noise: kCorpusDegradation.noise,
        blurSigma: kCorpusDegradation.blurSigma,
        seed: seed,
        jpegQuality: kCorpusJpegQuality,
        dice: <DiceSpotRecipe>[
          for (final p in placements)
            (face: p.face, x: p.center.x, y: p.center.y, angle: p.angle),
        ],
      ),
    ),
  );
}

/// Two dice in the middle band, clear of everything standing in it.
///
/// The checklist asks a person for exactly this, and for the same reason: the
/// reader returns null when a die touches a stack, by design, so a corpus that
/// dropped dice against checkers would be scoring the refusal path while
/// claiming to score the reading one. That is a real case and it has its own
/// test; it is not this corpus's question.
///
/// What has to be kept clear, and why each one is on the list:
///
/// * **any point holding five or more checkers** — a stack compresses toward
///   the midline and the fifth checker reaches it, so those columns have
///   checkers standing in the band;
/// * **the bar, always.** Two reasons. Its checkers grow *outward from the
///   middle*, so even one of them is in the band. And, found while building
///   this corpus: **a die overlapping the bar's edge can read one pip too
///   many.** The bar is wood where the rest of the band is felt, and the blur
///   along the die's edge over that boundary leaves a dark patch that survives
///   the pip erosion and is counted as a pip. At the corpus's own sharpness it
///   costs one of the three boards a reading; blurrier frames lose more.
///   Pinned in `test/dice_reader_test.dart`; the checklist tells a person the
///   same thing in the same words, because a real roll lands on felt anyway.
///
/// The pair is placed **side by side**, which is what a pair thrown from a cup
/// looks like, and not at opposite ends of the board — the arrangement this
/// generator produced first, which cost the corpus a reading and which no
/// player has ever produced on purpose.
///
/// Coordinates are the renderer's, i.e. before the half-turn that produces the
/// far seating. The checker columns are compared in the same frame, so the two
/// agree whichever seat the session is shot from.
List<DicePlacement> _placeDice(Dice dice, BoardState board, int seed) {
  final rng = math.Random(seed);
  final blocked = <(double, double)>[
    for (var i = 0; i < 24; i++)
      if (board.points[i].abs() >= 5) BoardLayout.pointSpan(i),
    (BoardLayout.barStart, BoardLayout.barEnd),
  ];

  // How far a die reaches along x once it has been turned as far as the corpus
  // turns them. A third of a radian: past about half, a corner of the die
  // leaves the band the atlas reserves, which is a different question — one
  // the session answers by asking for another roll — and not one to confuse
  // with reading a settled pair.
  const maxAngle = 0.35;
  final halfSpan = BoardLayout.dieSide /
      2 *
      (math.cos(maxAngle).abs() + math.sin(maxAngle).abs());
  // Two dice all but touching, which is what a pair out of a cup looks like.
  final separation = 2 * halfSpan + 0.003;

  bool clearAt(double x) => blocked.every(
        (span) => x + halfSpan < span.$1 || x - halfSpan > span.$2,
      );

  final clear = <double>[
    for (var x = BoardLayout.leftHalfStart + halfSpan;
        x <= BoardLayout.rightHalfEnd - halfSpan;
        x += 0.004)
      if (clearAt(x)) x,
  ];

  // The starting position leaves each half of the band about a fifth of the
  // board wide — the five-stacks on the 6- and 12-points, and their mirrors,
  // eat the rest — so the pair has to fit inside that. Preference order:
  // touching, then merely close, and a throw only if the felt has genuinely
  // run out, which would be a corpus bug rather than a photograph nobody could
  // take.
  for (final reach in <double>[0.03, 0.15, 0.40]) {
    final pairs = <(double, double)>[
      for (final a in clear)
        for (final b in clear)
          if (b - a >= separation && b - a <= separation + reach) (a, b),
    ];
    if (pairs.isEmpty) continue;
    final pair = pairs[rng.nextInt(pairs.length)];
    double angle() => (rng.nextDouble() * 2 - 1) * maxAngle;
    return <DicePlacement>[
      DicePlacement(face: dice.die1, center: Pt(pair.$1, 0.5), angle: angle()),
      DicePlacement(face: dice.die2, center: Pt(pair.$2, 0.5), angle: angle()),
    ];
  }
  throw StateError('nowhere on this board to lay two dice clear of the '
      'stacks and the bar: $board');
}

BoardQuad _translated(BoardQuad quad, double dx, double dy) =>
    BoardQuad.fromCorners(<Pt>[
      for (final c in quad.corners) Pt(c.x + dx, c.y + dy),
    ]);

/// A stable seed per name, so a shot's grain depends on which shot it is and
/// nothing else — insert a session and the shots after it keep their own.
int _seedOf(String name) {
  var hash = kCorpusSeed;
  for (final unit in name.codeUnits) {
    hash = (hash * 33 + unit) & 0x3FFFFFFF;
  }
  return hash;
}

String? _option(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}
