/// The corpus: what gets shot, in what order, and what each shot means.
///
/// **The schema and the plan share a file, on purpose.** A sidecar is generated
/// from the plan and read by the harness, so the two have to agree exactly, and
/// the cheapest way to keep them agreeing is to give them nowhere separate to
/// drift to. The checklist generator, the synthetic corpus generator, the prep
/// tool and the harness all build on this file; `checklist.dart` turns a plan
/// into the markdown a person reads, and knows nothing the plan has not said.
///
/// ## Ground truth by construction
///
/// Nothing in a sidecar is hand-labelled. The checklist tells a person which
/// position to set up and which faces to show, and the sidecar is generated
/// from the same plan — so the truth is what was *asked for*, not what someone
/// squinted at afterwards. Mid-game positions come from seeded random playouts
/// through `backgammon_core`, and their sidecars carry the event log that
/// produced them, so `Game.replay` re-derives the position and proves it is one
/// a real game can reach. A hand-invented pile of checkers cannot make that
/// claim, and a corpus scored against an illegal position teaches the pipeline
/// to read boards that will never exist.
///
/// ## Sessions, and why the corpus has them
///
/// Perception is not asked a question in isolation. A Buddy session calibrates
/// **once**, from a bare starting position, and reads every later frame through
/// that calibration. The corpus is built the same way: a [CaptureSession] is
/// one board, one light, one camera position, and one calibration, and its
/// first shot is the only one that carries corners.
///
/// This is not tidiness. It is forced, and the way it was found is worth
/// recording: calibrate from a frame that has dice sitting on it and the dice
/// reader can never see dice again, because calibration learned them as one of
/// the board's own surfaces (pinned in `test/dice_reader_test.dart`). A corpus
/// of independent shots, each calibrated from itself, would score zero on the
/// spec's highest target and the reason would look like an algorithm failure.
///
/// It also makes the real capture tractable: four corners are tapped once per
/// session rather than once per photograph, and the instruction to the person
/// holding the phone is a simple one — *do not move it until the session ends*.
library;

import 'dart:math' as math;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';

import '../synthetic/board_renderer.dart';

/// The schema version written into every sidecar.
///
/// Bumped when a field changes meaning rather than when one is added: readers
/// tolerate unknown keys, so a purely additive change does not invalidate a
/// corpus that took a person an afternoon to shoot.
const int kSidecarSchema = 1;

/// The seed the whole plan derives from. Fixed by the plan document; changing
/// it changes every position and every roll, and therefore invalidates a
/// captured corpus.
const int kCorpusSeed = 4242;

/// How big a committed corpus may get. The spec's number, in bytes.
const int kCorpusByteBudget = 25 * 1024 * 1024;

/// What a shot is for.
enum ShotKind {
  /// The board in the starting position with nothing else on the felt. Every
  /// session begins with one, and it is the only shot that carries corners.
  calibration,

  /// A mid-game position, no dice. Scored for occupancy — and, from Task 7,
  /// for play identification against the previous position.
  position,

  /// A settled pair of dice on top of whatever the board already holds.
  dice,

  /// Deliberately spoiled. Scored as a refusal, never as an answer.
  degraded,
}

/// What "refused correctly" means for a [ShotKind.degraded] shot.
///
/// Two different instruments, because two different things have gone wrong and
/// the session routes them differently: one is a calibration that must not be
/// handed over, the other is a calibration that was fine a moment ago and is
/// not any more.
enum ExpectedRefusal {
  /// `BoardVision.calibrate` must fail, with a sentence for the user.
  calibration,

  /// The board is no longer where the session's calibration says it is, and
  /// `CalibrationFingerprint.geometryMatches` must say so.
  geometry,
}

/// Which physical board, under which light, from where.
///
/// The three axes the spec asks the corpus to span. They are recorded per
/// session rather than per shot because they are properties of the setup, and
/// the harness slices its scoreboard by them.
class CaptureConditions {
  /// A name a person can act on: "board A", "board B".
  final String board;

  /// "daylight", "lamp", "dim" — the spec's three.
  final String lighting;

  /// How the phone stands, in words. Shot in the checklist, sliced in the
  /// scoreboard.
  final String angle;

  const CaptureConditions({
    required this.board,
    required this.lighting,
    required this.angle,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'board': board,
        'lighting': lighting,
        'angle': angle,
      };

  factory CaptureConditions.fromJson(Map<String, dynamic> json) =>
      CaptureConditions(
        board: json['board'] as String,
        lighting: json['lighting'] as String,
        angle: json['angle'] as String,
      );

  @override
  String toString() => '$board, $lighting, $angle';
}

/// Where one die goes, in board space, for a synthetic render.
typedef DiceSpotRecipe = ({int face, double x, double y, double angle});

/// Everything the synthetic generator needs to redraw a shot exactly.
///
/// Carried in the sidecar so that a committed synthetic image can always be
/// traced back to what produced it — and so that a reviewer can regenerate the
/// corpus and get the same bytes.
class SyntheticRecipe {
  final String palette;
  final double lightingGain;
  final double noise;
  final double blurSigma;
  final int seed;
  final int jpegQuality;
  final List<DiceSpotRecipe> dice;

  const SyntheticRecipe({
    required this.palette,
    required this.lightingGain,
    required this.noise,
    required this.blurSigma,
    required this.seed,
    required this.jpegQuality,
    this.dice = const <DiceSpotRecipe>[],
  });

  BoardPalette get boardPalette =>
      BoardPalette.all.firstWhere((p) => p.name == palette);

  List<DicePlacement> get placements => <DicePlacement>[
        for (final d in dice)
          DicePlacement(face: d.face, center: Pt(d.x, d.y), angle: d.angle),
      ];

  // `quadJitter` is deliberately left at its default of zero, and the zero is
  // the point: a session's quad is jittered ONCE, by the generator, and every
  // shot in that session is warped onto the result. A board does not move
  // between two photographs taken seconds apart, so a per-shot wobble would
  // model something that does not happen.
  ShotDegradation get degradation => ShotDegradation(
        noise: noise,
        blurSigma: blurSigma,
        seed: seed,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'palette': palette,
        'lightingGain': lightingGain,
        'noise': noise,
        'blurSigma': blurSigma,
        'seed': seed,
        'jpegQuality': jpegQuality,
        'dice': <Map<String, dynamic>>[
          for (final d in dice)
            <String, dynamic>{
              'face': d.face,
              'x': d.x,
              'y': d.y,
              'angle': d.angle,
            },
        ],
      };

  factory SyntheticRecipe.fromJson(Map<String, dynamic> json) =>
      SyntheticRecipe(
        palette: json['palette'] as String,
        lightingGain: (json['lightingGain'] as num).toDouble(),
        noise: (json['noise'] as num).toDouble(),
        blurSigma: (json['blurSigma'] as num).toDouble(),
        seed: (json['seed'] as num).toInt(),
        jpegQuality: (json['jpegQuality'] as num).toInt(),
        dice: <DiceSpotRecipe>[
          for (final d in (json['dice'] as List<dynamic>? ?? <dynamic>[]))
            (
              face: ((d as Map<String, dynamic>)['face'] as num).toInt(),
              x: (d['x'] as num).toDouble(),
              y: (d['y'] as num).toDouble(),
              angle: (d['angle'] as num).toDouble(),
            ),
        ],
      );
}

/// One shot, and everything known about it — the sidecar.
///
/// ## The corners field, and the one manual step in the whole pipeline
///
/// [corners] is the playing field's four corners **in the prepared image**. For
/// a synthetic shot the generator knows them exactly and writes them. For a
/// real photograph nobody does: a corner detector is Task 12's problem and the
/// spec has the user drag four handles anyway, so the corpus takes the same
/// honest route. `tool/prepare_corpus.dart` writes `corners: null` and prints
/// what to do — read the four corner pixels off the prepared JPEG in any image
/// viewer, put them in `corners.json` beside the photographs, and run the tool
/// again. The harness skips a shot whose corners are still null, and says so
/// out loud rather than passing quietly.
///
/// Only [ShotKind.calibration] and [ShotKind.degraded] shots carry corners.
/// Everything else is read through its session's calibration, which is what a
/// live session does and is why the manual step is four taps per session
/// rather than four per photograph.
class CorpusShot {
  /// Three digits, unique across the corpus, and the photograph's file name.
  final String id;

  /// The session this belongs to. Shots of one session share a board, a light,
  /// a camera position and a calibration.
  final String session;

  final ShotKind kind;

  /// The id of the shot this one is read through, or null when this shot is
  /// itself the calibration.
  final String? calibrateFrom;

  /// The playing field's corners in the image. Null on a real shot until the
  /// manual step above has been done; always present on a synthetic one.
  final BoardQuad? corners;

  /// Which seat the board is being read from.
  final BoardOrientation orientation;

  /// How wide this board's trays and bar are, or **null for a board of the
  /// usual shape** — which is every shot the plan generates, so the field is
  /// absent from every sidecar written before it existed and none of them has
  /// to be regenerated.
  ///
  /// The real corpus is shot on a folding-case board: no bear-off wells, a
  /// hinge for a bar. Its columns are wider than an ordinary board's and its
  /// outermost points sit most of a column away from where the standard atlas
  /// looks, so the session that reads it has to be told. Measured by a person
  /// off the calibration frame — see [BoardProportions] for why there is no
  /// auto-detection — and carried per shot because the sidecar is the only
  /// thing the harness reads; the harness takes a session's from the shot it
  /// calibrates through, since one session is one board.
  final BoardProportions? proportions;

  /// The position the board is in. Authoritative for scoring.
  final BoardState board;

  /// The moves that produced [board], when it came from a playout. Replaying
  /// them through `Game.replay` must reproduce [board] exactly — which is both
  /// the proof that the position is legal and the guard against a sidecar that
  /// has been edited by hand.
  final List<GameEvent>? events;

  /// The roll showing on the felt, or null when there are no dice in the shot.
  final Dice? dice;

  final CaptureConditions capture;

  /// Null for a real photograph; the recipe for a synthetic one.
  final SyntheticRecipe? synthetic;

  /// Set when this shot is one perception must decline to answer.
  final ExpectedRefusal? expectRefusal;

  /// Why, in words, for the checklist and the scoreboard.
  final String? refusalReason;

  /// One line naming the shot, for the checklist's headings.
  final String title;

  /// What the person holding the phone has to do. Written to be followed
  /// literally, in order.
  final List<String> instructions;

  CorpusShot({
    required this.id,
    required this.session,
    required this.kind,
    required this.calibrateFrom,
    required this.corners,
    required this.orientation,
    required this.board,
    required this.events,
    required this.dice,
    required this.capture,
    required this.synthetic,
    required this.expectRefusal,
    required this.refusalReason,
    required this.title,
    required List<String> instructions,
    this.proportions,
  }) : instructions = List<String>.unmodifiable(instructions);

  bool get expectsRefusal => expectRefusal != null;

  /// Whether somebody has to tap this shot's four corners.
  ///
  /// True for the shot a session calibrates from, and for a shot that is its
  /// own calibration attempt because the corpus expects that attempt to be
  /// refused — those carry honest corners saying where the board really is,
  /// since a refusal earned by lying about the corners would prove nothing.
  ///
  /// **One definition, used by everything.** The prep tool decides what to put
  /// in `corners.json` with this, the checklist counts and names the shots with
  /// this, and a test pins the answer. They disagreed once — the checklist said
  /// six where the tool meant eight, and a person following it would have found
  /// two shots in the template that the instructions did not account for.
  bool get needsCorners =>
      kind == ShotKind.calibration ||
      expectRefusal == ExpectedRefusal.calibration;

  /// Whether this shot's board is partly outside the picture, as opposed to
  /// being merely unlit.
  ///
  /// The two deliberately-unreadable calibration attempts are handled
  /// differently everywhere — where the generator puts the quad, and what a
  /// person is told about tapping corners on them — so something has to tell
  /// them apart. It is a text test rather than a field because the sidecar
  /// schema is committed alongside photographs: adding a field means bumping
  /// the version and invalidating every corpus already shot, which is a steep
  /// price for a distinction one string already carries.
  bool get isPartlyOutOfFrame =>
      refusalReason?.contains(_outOfFrameMark) ?? false;

  /// The sidecar's file name.
  String get sidecarName => '$id.expected.json';

  CorpusShot copyWith({
    BoardQuad? corners,
    SyntheticRecipe? synthetic,
    BoardProportions? proportions,
  }) =>
      CorpusShot(
        id: id,
        session: session,
        kind: kind,
        calibrateFrom: calibrateFrom,
        corners: corners ?? this.corners,
        orientation: orientation,
        board: board,
        events: events,
        dice: dice,
        capture: capture,
        synthetic: synthetic ?? this.synthetic,
        expectRefusal: expectRefusal,
        refusalReason: refusalReason,
        title: title,
        instructions: instructions,
        proportions: proportions ?? this.proportions,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schema': kSidecarSchema,
        'id': id,
        'session': session,
        'kind': kind.name,
        'calibrateFrom': calibrateFrom,
        'corners': corners == null ? null : _quadToJson(corners!),
        'orientation': orientation.name,
        'board': _boardToJson(board),
        'events': events?.map((e) => e.toJson()).toList(),
        'dice': dice == null
            ? null
            : <String, dynamic>{'die1': dice!.die1, 'die2': dice!.die2},
        'capture': capture.toJson(),
        'synthetic': synthetic?.toJson(),
        'expectRefusal': expectRefusal?.name,
        'refusalReason': refusalReason,
        'title': title,
        'instructions': instructions,
        'proportions': proportions?.toJson(),
      };

  factory CorpusShot.fromJson(Map<String, dynamic> json) {
    final schema = (json['schema'] as num).toInt();
    if (schema != kSidecarSchema) {
      throw FormatException('sidecar schema $schema, expected '
          '$kSidecarSchema — regenerate the corpus');
    }
    return CorpusShot(
      id: json['id'] as String,
      session: json['session'] as String,
      kind: ShotKind.values.byName(json['kind'] as String),
      calibrateFrom: json['calibrateFrom'] as String?,
      corners: json['corners'] == null
          ? null
          : _quadFromJson(json['corners'] as Map<String, dynamic>),
      orientation:
          BoardOrientation.values.byName(json['orientation'] as String),
      board: _boardFromJson(json['board'] as Map<String, dynamic>),
      events: json['events'] == null
          ? null
          : <GameEvent>[
              for (final e in json['events'] as List<dynamic>)
                GameEvent.fromJson(e as Map<String, dynamic>),
            ],
      dice: json['dice'] == null
          ? null
          : Dice(
              ((json['dice'] as Map<String, dynamic>)['die1'] as num).toInt(),
              ((json['dice'] as Map<String, dynamic>)['die2'] as num).toInt(),
            ),
      capture:
          CaptureConditions.fromJson(json['capture'] as Map<String, dynamic>),
      synthetic: json['synthetic'] == null
          ? null
          : SyntheticRecipe.fromJson(
              json['synthetic'] as Map<String, dynamic>),
      expectRefusal: json['expectRefusal'] == null
          ? null
          : ExpectedRefusal.values.byName(json['expectRefusal'] as String),
      refusalReason: json['refusalReason'] as String?,
      title: json['title'] as String,
      instructions: <String>[
        for (final line in json['instructions'] as List<dynamic>)
          line as String,
      ],
      // Absent on every sidecar written before folding-case boards turned up,
      // and absent means "the usual shape" — which is what makes this field
      // additive and a corpus already shot still readable.
      proportions: json['proportions'] == null
          ? null
          : BoardProportions.fromJson(
              json['proportions'] as Map<String, dynamic>),
    );
  }

  /// The position this sidecar's event log produces, for the guard that the
  /// two agree. Null when the shot carries no log.
  BoardState? get replayedBoard =>
      events == null ? null : Game.replay(events!).state.board;

  @override
  String toString() => 'CorpusShot($id ${kind.name}, $session)';
}

/// One board, one light, one camera position, one calibration.
class CaptureSession {
  /// Short and speakable: "A-daylight".
  final String name;

  final CaptureConditions conditions;
  final BoardOrientation orientation;

  /// The shots, in the order they are taken. The first is always a
  /// [ShotKind.calibration].
  final List<CorpusShot> shots;

  CaptureSession({
    required this.name,
    required this.conditions,
    required this.orientation,
    required List<CorpusShot> shots,
  }) : shots = List<CorpusShot>.unmodifiable(shots);

  CorpusShot get calibrationShot => shots.first;

  @override
  String toString() => 'CaptureSession($name, ${shots.length} shots)';
}

/// The whole plan: what to shoot, in order.
///
/// Deterministic in [seed] down to the last pip. Two runs produce identical
/// sidecars, which is what makes the checklist safe to hand out and the corpus
/// safe to regenerate.
List<CaptureSession> buildCapturePlan({int seed = kCorpusSeed}) {
  final rng = math.Random(seed);
  final positions = _seededPositions(rng, count: _sessions.length * 2);
  final rolls = _seededRolls(rng, count: _sessions.length * 2);

  final sessions = <CaptureSession>[];
  var nextId = 1;
  String takeId() => (nextId++).toString().padLeft(3, '0');

  for (final (index, plan) in _sessions.indexed) {
    final conditions = CaptureConditions(
      board: plan.board,
      lighting: plan.lighting,
      angle: plan.angle,
    );
    final shots = <CorpusShot>[];

    final calibrationId = takeId();
    shots.add(CorpusShot(
      id: calibrationId,
      session: plan.name,
      kind: ShotKind.calibration,
      calibrateFrom: null,
      corners: null,
      orientation: plan.orientation,
      board: BoardState.initial(),
      events: null,
      dice: null,
      capture: conditions,
      synthetic: null,
      expectRefusal: null,
      refusalReason: null,
      title: 'Calibration — the starting position',
      instructions: <String>[
        'Set ${plan.board} up for the start of a game, home boards to the '
            'RIGHT for both players.',
        'Sit where the checklist says (${_seatWords(plan.orientation)}) and '
            'prop the phone so the whole playing field, both bear-off trays '
            'included, is inside the picture: ${plan.angle}.',
        'Nothing on the felt but the checkers — no dice, no cube, no hands.',
        'Take the photo. DO NOT MOVE THE PHONE OR THE BOARD until this '
            "session's shots are all taken.",
      ],
    ));

    final firstRoll = rolls[index * 2];
    shots.add(CorpusShot(
      id: takeId(),
      session: plan.name,
      kind: ShotKind.dice,
      calibrateFrom: calibrationId,
      corners: null,
      orientation: plan.orientation,
      board: BoardState.initial(),
      events: null,
      dice: firstRoll,
      capture: conditions,
      synthetic: null,
      expectRefusal: null,
      refusalReason: null,
      title: 'Dice ${firstRoll.die1}-${firstRoll.die2} on the starting '
          'position',
      instructions: <String>[
        'Leave the board exactly as it is.',
        'Put two dice showing ${firstRoll.die1} and ${firstRoll.die2} in the '
            'empty band across the middle of the board.',
        'Both dice must be CLEAR OF EVERY STACK and OFF THE BAR, flat on the '
            'felt — a die touching checkers is a different question, one '
            'Buddy answers by asking for another roll, and a die lying across '
            'the bar reads a pip too many.',
        'Take the photo.',
      ],
    ));

    for (final (half, position) in <(int, _SeededPosition)>[
      (0, positions[index * 2]),
      (1, positions[index * 2 + 1]),
    ]) {
      shots.add(CorpusShot(
        id: takeId(),
        session: plan.name,
        kind: ShotKind.position,
        calibrateFrom: calibrationId,
        corners: null,
        orientation: plan.orientation,
        board: position.board,
        events: position.events,
        dice: null,
        capture: conditions,
        synthetic: null,
        expectRefusal: null,
        refusalReason: null,
        title: 'Mid-game position after ${position.ply} half-turns',
        instructions: <String>[
          'Set the board to the position in the diagram below. Take your time '
              'and count twice; this is the ground truth.',
          'Clear the dice off the board.',
          'Take the photo.',
        ],
      ));

      if (half == 0) {
        final roll = rolls[index * 2 + 1];
        shots.add(CorpusShot(
          id: takeId(),
          session: plan.name,
          kind: ShotKind.dice,
          calibrateFrom: calibrationId,
          corners: null,
          orientation: plan.orientation,
          board: position.board,
          events: position.events,
          dice: roll,
          capture: conditions,
          synthetic: null,
          expectRefusal: null,
          refusalReason: null,
          title: 'Dice ${roll.die1}-${roll.die2} on that position',
          instructions: <String>[
            'Leave the checkers where they are.',
            'Put two dice showing ${roll.die1} and ${roll.die2} in the middle '
                'band, again clear of every stack.',
            'Take the photo.',
          ],
        ));
      }
    }

    final spoiled = _degradations[plan.name];
    if (spoiled != null) {
      shots.add(CorpusShot(
        id: takeId(),
        session: plan.name,
        kind: ShotKind.degraded,
        calibrateFrom:
            spoiled.refusal == ExpectedRefusal.geometry ? calibrationId : null,
        corners: null,
        orientation: plan.orientation,
        board: BoardState.initial(),
        events: null,
        dice: null,
        capture: conditions,
        synthetic: null,
        expectRefusal: spoiled.refusal,
        refusalReason: spoiled.reason,
        title: 'Deliberately unreadable — ${spoiled.label}',
        instructions: <String>[
          'This one is meant to fail, and it is the most valuable shot in the '
              'session: it is how the corpus checks that Buddy says "I cannot '
              'read this" instead of guessing.',
          'Set the board back to the STARTING position.',
          ...spoiled.instructions,
          'Take the photo. This is the LAST shot of the session — the phone '
              'may be moved freely afterwards.',
        ],
      ));
    }

    sessions.add(CaptureSession(
      name: plan.name,
      conditions: conditions,
      orientation: plan.orientation,
      shots: shots,
    ));
  }
  return sessions;
}

/// Every shot in the plan, flattened, in capture order.
List<CorpusShot> flatten(List<CaptureSession> sessions) => <CorpusShot>[
      for (final session in sessions) ...session.shots,
    ];

// --- the plan's fixed skeleton ----------------------------------------------

/// One session's setup. Six of them: two boards times the spec's three
/// lighting conditions, with the seat alternating so both orientations are
/// covered on both boards.
typedef _SessionPlan = ({
  String name,
  String board,
  String lighting,
  String angle,
  BoardOrientation orientation,
});

const List<_SessionPlan> _sessions = <_SessionPlan>[
  (
    name: 'A-daylight',
    board: 'board A',
    lighting: 'daylight',
    angle: 'propped at the end of the table, roughly a hand span above it',
    orientation: BoardOrientation.whiteHomeNear,
  ),
  (
    name: 'A-lamp',
    board: 'board A',
    lighting: 'lamp',
    angle: 'leaning against something at the end of the table, lower — the '
        'far edge of the board should look clearly shorter than the near one',
    orientation: BoardOrientation.whiteHomeFar,
  ),
  (
    name: 'A-dim',
    board: 'board A',
    lighting: 'dim',
    angle: 'off to one side of the table rather than at the end of it',
    orientation: BoardOrientation.whiteHomeNear,
  ),
  (
    name: 'B-daylight',
    board: 'board B',
    lighting: 'daylight',
    angle: 'propped at the end of the table, roughly a hand span above it',
    orientation: BoardOrientation.whiteHomeFar,
  ),
  (
    name: 'B-lamp',
    board: 'board B',
    lighting: 'lamp',
    angle: 'leaning against something at the end of the table, lower — the '
        'far edge of the board should look clearly shorter than the near one',
    orientation: BoardOrientation.whiteHomeNear,
  ),
  (
    name: 'B-dim',
    board: 'board B',
    lighting: 'dim',
    angle: 'off to one side of the table rather than at the end of it',
    orientation: BoardOrientation.whiteHomeFar,
  ),
];

/// The phrase in a degraded shot's reason that means "part of the playing
/// field is not in the picture". See [CorpusShot.isPartlyOutOfFrame].
const String _outOfFrameMark = 'outside the frame';

typedef _Degradation = ({
  String label,
  String reason,
  ExpectedRefusal refusal,
  List<String> instructions,
});

/// The three shots the corpus expects perception to decline.
///
/// One per failure the readability indicator has to name (the spec's list:
/// "I can't see the left edge", "too dark", "the phone moved"), and between
/// them they cover both refusal instruments: a calibration that must not be
/// handed over, and a calibration that has stopped being true.
const Map<String, _Degradation> _degradations = <String, _Degradation>{
  'A-lamp': (
    label: 'half the board out of the picture',
    reason: 'part of the playing field is outside the frame, so the regions '
        'that fall off the edge cannot be measured at all',
    refusal: ExpectedRefusal.calibration,
    instructions: <String>[
      'Move the phone in close, or off to the side, until roughly a third of '
          'the playing field is outside the picture — one bear-off tray and '
          'the points beside it should be missing entirely.',
    ],
  ),
  'B-daylight': (
    label: 'too dark to read',
    reason: 'the board and the men on it have squeezed into the same few '
        'sensor values, so no colour model can separate them',
    refusal: ExpectedRefusal.calibration,
    instructions: <String>[
      'Turn the lights off, or close the curtains, until the board is barely '
          'visible to you — a room where you would not sit down to play.',
      'Do not use the phone\'s flash or night mode.',
    ],
  ),
  'B-dim': (
    label: 'the phone was knocked',
    reason: 'the board is no longer where the session calibrated it, so every '
        'region is being measured in the wrong place',
    refusal: ExpectedRefusal.geometry,
    instructions: <String>[
      'Knock the phone — a real nudge, a centimetre or two, the kind that '
          'happens when someone leans on the table. Do not re-aim it.',
    ],
  ),
};

// --- seeded ground truth ----------------------------------------------------

typedef _SeededPosition = ({
  BoardState board,
  List<GameEvent> events,
  int ply,
});

/// [count] mid-game positions, each from its own seeded playout.
///
/// Real games, not invented piles: every position is reached by rolling and
/// playing legal moves through `backgammon_core`, so the event log in the
/// sidecar replays to exactly the board the checklist asks a person to set up.
/// The plies are spread from the opening to well into the middle game, so the
/// corpus holds boards with bars, blots, primes and borne-off checkers rather
/// than six variations on the same shape.
List<_SeededPosition> _seededPositions(math.Random rng, {required int count}) {
  const plies = <int>[6, 10, 14, 18, 22, 26, 30, 34, 38, 42, 46, 50];
  final out = <_SeededPosition>[];
  for (var i = 0; i < count; i++) {
    final target = plies[i % plies.length];
    out.add(_playout(rng, halfTurns: target));
  }
  return out;
}

/// One playout, stopped after [halfTurns] half-turns (or at game over).
_SeededPosition _playout(math.Random rng, {required int halfTurns}) {
  int die() => rng.nextInt(6) + 1;
  var whiteDie = die(), blackDie = die();
  while (whiteDie == blackDie) {
    whiteDie = die();
    blackDie = die();
  }
  var game = Game.start(
    OpeningRollEvent(whiteDie: whiteDie, blackDie: blackDie),
  );
  // The opening roll is itself the first roll: the state arrives in the moving
  // phase with those two dice already on the felt.
  var played = 0;
  while (played < halfTurns && game.state.phase != GamePhase.gameOver) {
    if (game.state.phase == GamePhase.awaitingRoll) {
      game = game.append(RollEvent(game.state.turn, die(), die()));
      continue;
    }
    final legal = game.state.legalMoves;
    final move = legal.isEmpty ? Move.none : legal[rng.nextInt(legal.length)];
    game = game.append(MoveEvent(game.state.turn, move));
    played++;
  }
  return (board: game.state.board, events: game.events, ply: played);
}

/// [count] rolls that between them show every pip value.
///
/// Drawn from the same generator as everything else and then checked: if the
/// draw missed a value the whole set is redrawn, which keeps the result a
/// function of the seed alone rather than of a repair rule.
List<Dice> _seededRolls(math.Random rng, {required int count}) {
  for (var attempt = 0; attempt < 200; attempt++) {
    final rolls = <Dice>[
      for (var i = 0; i < count; i++) Dice(rng.nextInt(6) + 1, rng.nextInt(6) + 1),
    ];
    final seen = <int>{
      for (final roll in rolls) ...<int>[roll.die1, roll.die2],
    };
    if (seen.length == 6) return rolls;
  }
  throw StateError('no set of $count rolls covered all six pip values');
}

String _seatWords(BoardOrientation orientation) =>
    orientation == BoardOrientation.whiteHomeNear
        ? 'the side where WHITE bears off into the tray on your right'
        : 'the side where BLACK bears off into the tray on your right';

// --- JSON for the types that have none --------------------------------------

Map<String, dynamic> _quadToJson(BoardQuad quad) => <String, dynamic>{
      'topLeft': <double>[quad.topLeft.x, quad.topLeft.y],
      'topRight': <double>[quad.topRight.x, quad.topRight.y],
      'bottomRight': <double>[quad.bottomRight.x, quad.bottomRight.y],
      'bottomLeft': <double>[quad.bottomLeft.x, quad.bottomLeft.y],
    };

BoardQuad _quadFromJson(Map<String, dynamic> json) {
  Pt at(String key) {
    final pair = json[key] as List<dynamic>;
    return Pt((pair[0] as num).toDouble(), (pair[1] as num).toDouble());
  }

  return BoardQuad(
    topLeft: at('topLeft'),
    topRight: at('topRight'),
    bottomRight: at('bottomRight'),
    bottomLeft: at('bottomLeft'),
  );
}

Map<String, dynamic> _boardToJson(BoardState board) => <String, dynamic>{
      'points': board.points,
      'whiteBar': board.whiteBar,
      'blackBar': board.blackBar,
      'whiteOff': board.whiteOff,
      'blackOff': board.blackOff,
    };

BoardState _boardFromJson(Map<String, dynamic> json) => BoardState(
      points: <int>[
        for (final p in json['points'] as List<dynamic>) (p as num).toInt(),
      ],
      whiteBar: (json['whiteBar'] as num).toInt(),
      blackBar: (json['blackBar'] as num).toInt(),
      whiteOff: (json['whiteOff'] as num).toInt(),
      blackOff: (json['blackOff'] as num).toInt(),
    );
