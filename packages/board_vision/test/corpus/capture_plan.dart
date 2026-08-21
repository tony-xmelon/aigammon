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

  /// The eight points a **folding** board is calibrated from, or null when the
  /// board does not fold.
  ///
  /// The second thing the first real board turned out to be, after its widths:
  /// a case whose two leaves tent, which no four corners can describe. Present
  /// means the harness takes `BoardVision.calibrateFolding` and the board's
  /// widths are DERIVED from these eight — so [proportions] plays no part on
  /// such a shot and there is nothing for a person to measure twice.
  ///
  /// Absent means the board is flat, which is every sidecar written before
  /// this field existed. Additive exactly like [proportions], and pinned so by
  /// the same tests.
  final FoldingCorners? foldingCorners;

  /// How wide this session's dice are, as a fraction of the board's width, or
  /// null when nobody measured them.
  ///
  /// The third thing the first real footage turned out to be, after the widths
  /// and the tenting: its dice are **0.021** of the board across where the
  /// synthetic bed's are 0.075, and every size-derived number in the dice
  /// reader had been written for the latter. Absent means the bed's own size,
  /// which is what every sidecar written before this field carried by
  /// implication — additive exactly like [proportions], and pinned so by the
  /// same tests.
  ///
  /// Measured by a person off a frame with a settled roll in it, the same way
  /// the widths are. See `BoardCalibration.dieSide` for why the product will
  /// not ask its users to do this.
  final double? dieSide;

  /// The position the board is in. Authoritative for scoring.
  final BoardState board;

  /// The moves that produced [board], when it came from a playout. Replaying
  /// them through `Game.replay` must reproduce [board] exactly — which is both
  /// the proof that the position is legal and the guard against a sidecar that
  /// has been edited by hand.
  final List<GameEvent>? events;

  /// The roll this corpus is prepared to stand behind, or null when it will
  /// not claim one.
  ///
  /// ~~The roll showing on the felt, or null when there are no dice in the
  /// shot.~~ Both halves of that were wrong, and the real footage is what
  /// separated them.
  ///
  /// **Null does not mean "no dice in the picture".** That is [diceInFrame],
  /// and the two came apart the moment the corpus met a camera at table
  /// height: **nine** of the ten filmed windows have dice somewhere in them
  /// and only four carry a value here. Null means the corpus will not claim a
  /// roll — usually a settled, perfectly visible pair whose TOP faces this
  /// camera cannot resolve.
  ///
  /// **And a value here is not always something read off the pips.** See
  /// [diceDerived]: 010's 6-4 is derived from the play it made possible, which
  /// is the same ground-truth-by-construction the boards get, applied to the
  /// felt.
  final Dice? dice;

  /// Whether physical dice are visible in the frame at all — however
  /// unreadable, whoever they belong to — or null when the shot does not say.
  ///
  /// **Absent means "dice are in the frame exactly when [dice] claims a
  /// roll"**, which is true of every generated shot by construction (the
  /// renderer draws dice if and only if the plan gave it some) and is why this
  /// field is additive: no synthetic sidecar has to be rewritten, and none is.
  /// The filmed session writes it explicitly on all ten of its shots, because
  /// that is precisely where the assumption fails.
  ///
  /// It exists because a metric was quietly rewarding the wrong thing.
  /// `CorpusMetric.diceAbsence` asks "did the reader invent a roll?", and its
  /// denominator was every shot with no certified value — six of the ten real
  /// windows, five of which have dice lying in them. A reader that started
  /// seeing this board's dice would have *lost* marks on that row. With this
  /// field the denominator is what the row's sentence says: frames with no
  /// dice in them. See `_scoreDice`.
  final bool? diceInFrame;

  /// Whether [dice] was DERIVED from the play rather than read off the pips,
  /// or null when it was read (or when there is no roll at all).
  ///
  /// One shot carries it: 010, whose pair is fixed by arithmetic — a ten-pip
  /// one-man play out of the 1-point with the 6-point blocked four deep cannot
  /// have been thrown any other way. That is as sound as a reading and it is
  /// not the same *kind* of evidence, so a machine-readable mark says which,
  /// rather than leaving the distinction in a sentence only a person reads.
  final bool? diceDerived;

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
    this.foldingCorners,
    this.dieSide,
    this.diceInFrame,
    this.diceDerived,
  }) : instructions = List<String>.unmodifiable(instructions);

  bool get expectsRefusal => expectRefusal != null;

  /// Whether there are dice in this picture at all. See [diceInFrame] for what
  /// an absent field means and why the derivation is safe.
  bool get hasDiceInFrame => diceInFrame ?? (dice != null);

  /// Whether [dice], if there is one, was derived rather than read.
  bool get hasDerivedDice => diceDerived ?? false;

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

  /// The same shot with some fields replaced.
  ///
  /// Null means "leave this one alone", as it does in every `copyWith` — so
  /// [clearProportions] is how a caller says the other thing. A folding case
  /// has no widths to record (its eight points derive them), and passing null
  /// for [proportions] would quietly keep whatever the shot already carried.
  CorpusShot copyWith({
    BoardQuad? corners,
    SyntheticRecipe? synthetic,
    BoardProportions? proportions,
    bool clearProportions = false,
    FoldingCorners? foldingCorners,
    double? dieSide,
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
        proportions:
            clearProportions ? null : (proportions ?? this.proportions),
        foldingCorners: foldingCorners ?? this.foldingCorners,
        dieSide: dieSide ?? this.dieSide,
        diceInFrame: diceInFrame,
        diceDerived: diceDerived,
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
        // No key at all when unmeasured — an explicit null would be byte
        // drift against every committed sidecar, of exactly the class the
        // fromJson->toJson drift guards cannot see.
        if (proportions != null) 'proportions': proportions!.toJson(),
        // Same rule, same reason: no key at all on a board that does not fold.
        if (foldingCorners != null)
          'foldingCorners': _foldingToJson(foldingCorners!),
        // And again: no key at all when nobody measured the dice.
        if (dieSide != null) 'dieSide': dieSide,
        // Same rule again, and here the absent case carries a meaning rather
        // than an absence — see [diceInFrame]. Every generated sidecar leaves
        // both of these out, which is what makes them additive.
        if (diceInFrame != null) 'diceInFrame': diceInFrame,
        if (diceDerived != null) 'diceDerived': diceDerived,
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
      // Likewise absent on every sidecar written before boards that fold
      // turned up, and absent means the board is flat.
      foldingCorners: json['foldingCorners'] == null
          ? null
          : _foldingFromJson(json['foldingCorners'] as Map<String, dynamic>),
      // Absent on every sidecar written before dice had a measured size, and
      // absent means the synthetic bed's — see [dieSide].
      dieSide: (json['dieSide'] as num?)?.toDouble(),
      // Absent on every generated sidecar, where "dice in frame" and "a roll
      // is claimed" cannot come apart. See [diceInFrame] and [diceDerived].
      diceInFrame: json['diceInFrame'] as bool?,
      diceDerived: json['diceDerived'] as bool?,
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

// --- the session that was actually filmed -----------------------------------

/// The name of the one real session in the corpus.
const String kRealSessionName = 'living-room-daylight';

/// The footage every real shot was cut from.
const String kRealFootage = 'VID20260820105037';

/// How wide this board's dice are, as a fraction of the playing field.
///
/// Measured off a settled roll in the footage — about a third of the synthetic
/// bed's 0.075, which is why `BoardCalibration.dieSide` had to become an input
/// at all. Resolution-independent, which is why it lives here rather than in
/// `corners.json`: the eight corner points are pixels in a particular prepared
/// image and would be wrong the moment the corpus were prepared at another
/// size, and this number would not.
const double kRealDieSide = 0.021;

/// The real corpus: ten frames out of one filmed game.
///
/// The mirror image of [buildCapturePlan], and the pair of them is the point.
/// That one says what to go and shoot; this one says what was shot — the
/// `FILMING.md` route, one continuous video of a game played out, with stable
/// windows cut from it afterwards. The corpus's contract does not change: a
/// sidecar is still generated from a plan rather than typed, and the ground
/// truth is still something other than a person's opinion of a photograph.
///
/// ## Where the ground truth comes from, per shot
///
/// * the **calibration** frame is the starting position, which needs no
///   evidence at all;
/// * seven **positions** come from [_filmedTurns], the move ledger recovered
///   from the footage, replayed here through `backgammon_core`. The board in
///   the sidecar is the replay's output and nothing else, so a transcription
///   error that produces an illegal play throws out of this function rather
///   than becoming a corpus that scores perception against a board no game can
///   reach;
/// * two **keyframes** carry a board and no log. They come from the end of the
///   video, which was not transcribable move by move — hands in shot, a hit
///   nobody could pin to a turn — and were read off zoomed frames by a person.
///   They are the weakest ground truth in the corpus, ~~and hold the only
///   board with men borne off~~ — and the 2026-08-23 audit is what that
///   weakness looks like when it is finally measured. The zooms lost two White
///   men in each frame behind the case's near rim, and the difference was
///   written down as `whiteOff: 2`. Both men are on the board. The
///   `checkerCount` check in `capture_plan_test.dart` is the only arithmetic
///   that can be held over these two, and it is worth knowing what it cannot
///   see: fifteen a side counts a man written off as a man, so it passed on
///   the wrong boards exactly as it passes on the right ones.
///
/// The middle of the game (turns 9 to 15) is **not** in the corpus. Its
/// windows have hands at rest in them and a hit sequence nobody could
/// attribute, and a sidecar that guessed would be worse than a shorter corpus.
///
/// ## What this does not carry
///
/// The eight corner points. They are pixels in the prepared image, so they
/// come through `corners.json` and `prepare_corpus` like every other board's —
/// see `CorpusShot.corners`. Everything here is true of the session whatever
/// size it is prepared at.
CaptureSession buildRealSession() {
  const conditions = CaptureConditions(
    board: 'folding-case walnut',
    lighting: 'daylight-backlit',
    // Measured off the frame rather than described from memory: the board's
    // far edge spans 825 px in the raw 1920-wide frame against the near
    // edge's 1526.
    angle: 'propped at the end of the table and low — the far edge of the '
        'board measures barely half the near one',
  );

  final afterTurn = replayFilmedLedger(_filmedTurns);
  final shots = <CorpusShot>[];

  CorpusShot filmed({
    required String id,
    required String seconds,
    required ShotKind kind,
    required BoardState board,
    required List<GameEvent>? events,
    required Dice? dice,
    // Required rather than defaulted, on all ten, because the whole point of
    // the field is that this session is where "a roll is claimed" and "there
    // are dice in the picture" stop being the same question. A default would
    // let a new window inherit the wrong one silently.
    required bool diceInFrame,
    required bool diceDerived,
    required String title,
    required List<String> notes,
    FoldingCorners? foldingCorners,
    double? dieSide,
  }) =>
      CorpusShot(
        id: id,
        session: kRealSessionName,
        kind: kind,
        calibrateFrom: kind == ShotKind.calibration ? null : shots.first.id,
        // Read off the prepared image, so they arrive through the prep tool.
        corners: null,
        orientation: BoardOrientation.whiteHomeNear,
        board: board,
        events: events,
        dice: dice,
        capture: conditions,
        synthetic: null,
        expectRefusal: null,
        refusalReason: null,
        title: title,
        // A filmed shot's "instructions" are how to get this exact frame
        // back: the footage, the timestamp, and what was true of the board
        // then. Followed literally, in order, they reproduce it.
        instructions: <String>[
          'Cut $kRealFootage at t=${seconds}s and take the whole frame.',
          ...notes,
        ],
        foldingCorners: foldingCorners,
        dieSide: dieSide,
        diceInFrame: diceInFrame,
        // Written only when it is true, so that "read off the pips" stays the
        // silent default and a derived value has to say so.
        diceDerived: diceDerived ? true : null,
      );

  shots.add(filmed(
    id: '001',
    seconds: '10.5',
    kind: ShotKind.calibration,
    board: BoardState.initial(),
    events: null,
    dice: null,
    // The only frame in the session with no dice anywhere in it, and it has to
    // be: a die present at calibration is learned as part of the board.
    diceInFrame: false,
    diceDerived: false,
    title: 'Calibration — the starting position',
    notes: <String>[
      'Act 1 of FILMING.md: the board set for the start of a game, home '
          'boards to the right, held still.',
      'Nothing on the felt but the checkers. No dice anywhere in view — a '
          'die present at calibration is learned as part of the board and is '
          'then invisible for the rest of the session.',
    ],
    dieSide: kRealDieSide,
  ));

  for (final cut in _filmedPositions) {
    final position = afterTurn[cut.afterTurn - 1];
    shots.add(filmed(
      id: cut.id,
      seconds: cut.seconds,
      kind: ShotKind.position,
      board: position.board,
      events: position.log,
      dice: cut.dice,
      diceInFrame: cut.diceInFrame,
      diceDerived: cut.diceDerived,
      title: 'Turn ${cut.afterTurn} played — '
          '${_filmedTurns[cut.afterTurn - 1].notation}',
      notes: <String>[
        'The board as the ledger leaves it after turn ${cut.afterTurn}.',
        cut.diceNote,
      ],
    ));
  }

  for (final cut in _filmedKeyframes) {
    shots.add(filmed(
      id: cut.id,
      seconds: cut.seconds,
      kind: ShotKind.position,
      board: cut.board,
      // No log: see the class doc. A board with no story is still a board.
      events: null,
      dice: null,
      diceInFrame: cut.diceInFrame,
      diceDerived: false,
      title: cut.title,
      notes: <String>[cut.evidence, cut.diceNote],
    ));
  }

  return CaptureSession(
    name: kRealSessionName,
    conditions: conditions,
    orientation: BoardOrientation.whiteHomeNear,
    shots: shots,
  );
}

/// The transcript's stand-in for a checker on the bar, one past White's
/// 24-point in its own 1-based numbering.
const int kFilmedBar = 25;

/// One half-turn of the filmed game, as the transcript recorded it.
///
/// [hops] are `(from, to)` in the numbering the whole transcript uses — White's
/// points 1 to 24 ascending, whoever is moving, with [kFilmedBar] for a checker
/// coming in off the bar. Deliberately the transcript's notation rather than
/// the engine's: the ledger is evidence, and evidence converted on its way into
/// the file can no longer be checked against what it came from. [notation] is
/// the transcript's own line, carried so the title of a shot is quoted rather
/// than retyped.
///
/// Note what is **not** here: whether a hop hits. That is not something the
/// transcript recorded, it is something the position determines — see
/// [replayFilmedLedger].
typedef FilmedTurn = ({
  Player player,
  int die1,
  int die2,
  List<(int from, int to)> hops,
  String notation,
});

/// One position out of the ledger: the board after a turn, and the cumulative
/// log that reaches it.
typedef FilmedPosition = ({BoardState board, List<GameEvent> log});

/// Replays [turns] from the filmed game's opening roll, returning the position
/// after each — index 0 is after turn 1.
///
/// **The net under the whole ledger.** `Game.append` validates every event
/// against the rules engine, so a mis-transcribed turn stops the build here,
/// loudly and naming itself, rather than becoming a sidecar that scores
/// photographs against a board no game can reach. Public so that the net can
/// be tested with a ledger that is deliberately wrong; the real ledger stays
/// private, because there is only one of it.
List<FilmedPosition> replayFilmedLedger(List<FilmedTurn> turns) {
  var game = Game.start(const OpeningRollEvent(whiteDie: 4, blackDie: 2));
  final out = <FilmedPosition>[];
  for (final (index, turn) in turns.indexed) {
    final number = index + 1;
    try {
      // Turn 1 is played on the opening roll itself, which is already on the
      // felt — every turn after it needs its own roll first.
      if (number > 1) {
        game = game.append(RollEvent(turn.player, turn.die1, turn.die2));
      }
      game = game.append(
        MoveEvent(turn.player, _moveOf(game.state.board, turn)),
      );
    } on StateError catch (e) {
      throw StateError(
        'the filmed ledger stops being a legal game at turn $number '
        '(${turn.notation}): ${e.message}',
      );
    }
    out.add((board: game.state.board, log: game.events));
  }
  return out;
}

/// [turn]'s hops as a [Move], each one's hit flag **derived** from the board it
/// lands on.
///
/// A hit is not something a transcript records; it is something the position
/// determines. It matters that the flag is right even though `BoardState`
/// recomputes hits when it applies a move: `CheckerMove.==` compares the flag,
/// and Task 7 matches an observed play against an enumerated set of legal ones.
/// A log that reaches the right board with every flag false would be a trap
/// laid for exactly the corpus that has a real hit in it.
///
/// Hand-annotating them would be a second opinion about something already
/// determined, so the hops are walked in order over a running board and the
/// flag is read off the point each one lands on before it lands.
Move _moveOf(BoardState before, FilmedTurn turn) {
  var board = before;
  final hops = <CheckerMove>[];
  for (final (from, to) in turn.hops) {
    final destination = to - 1;
    final occupant =
        destination >= 0 && destination < 24 ? board.points[destination] : 0;
    final hop = CheckerMove(
      from == kFilmedBar ? CheckerMove.bar : from - 1,
      destination,
      // Exactly one man of the other colour standing there — two is a made
      // point and no move lands on it at all.
      isHit: turn.player == Player.white ? occupant == -1 : occupant == 1,
    );
    hops.add(hop);
    board = board.applyMove(turn.player, Move(<CheckerMove>[hop]));
  }
  return Move(hops);
}

/// The move ledger, turn by turn, exactly as the transcript settled it.
///
/// Every entry was pinned twice over in the footage — a machine delta between
/// two stable windows, filtered by what the rules allowed, then adjudicated on
/// a zoom of the leaf it happened on. What makes it safe to commit is that it
/// is replayed rather than believed: see [buildRealSession].
///
/// ## Corrected 2026-08-21, and how the error was found
///
/// Two turns were transcribed wrongly and the corpus itself is what caught it.
/// Task 8's placement query reported the 6-point reading four men for five in
/// every window from 008 on, which was written down as "the photograph and the
/// ledger disagree" — a limit on the corpus rather than a bug. It was the
/// ledger.
///
/// ~~turn 3 was `W 3-2: 13/8`~~, ~~turn 8 was `B 5-3: 12/17 17/20*`~~, ~~a
/// White checker left the board during turn 7~~. Superseded the next day; kept
/// here because a number that is quietly replaced is a number nobody can
/// re-check. See below.
///
/// ## Corrected again 2026-08-22, and this time by measurement
///
/// The 2026-08-21 audit was a person looking at zooms, and it was wrong about
/// five of the eight turns. An independent reviewer re-measured the committed
/// JPEGs — cream/dark pixel mass and stack-top row per point column, through
/// this session's own calibration, with 001 as the control — and overturned its
/// central claim; re-measuring every cell the same way then overturned most of
/// the rest. What the instruments say, each cross-checked against a disc count
/// on the 1920-wide source frames and against fifteen men a side:
///
/// * **the 8-point holds TWO from turn 1 onwards, never three.** 001 measures
///   5527 cream px with its stack top at board y 0.783; every later window
///   measures 3227–3468 px at 0.87, which is the two-checker signature. The
///   pipeline's own reader agrees on all seven (reach ≈0.113, white x2). The
///   "genuine 8-point undercount" the 2026-08-21 floors were re-measured
///   against never existed: **perception was right and the ledger was wrong**;
/// * **nothing ever left the board.** The cream shape that appears at the near
///   rim from 008 is a White checker standing at the **10-point's base** —
///   the wide end, against the near edge, where `StackAxis.forRegion` puts the
///   stack's origin and the harness prints "reach 0.000" — three quarters
///   hidden behind the case's raised rim. (~~The 10-point's tip~~: the tip is
///   the midline end and nothing happens there. The wording was wrong in every
///   note this batch wrote, and is corrected throughout on 2026-08-23.) It is
///   the same signature the 7-point's lone blot shows at 013 and the 1-point's
///   last Black man shows at 010. Its blob centroid inverts to board x
///   **0.166 at 008 and 0.178 at 010**, against the 10-point's centre of
///   0.194 — one systematic top-face displacement away in both; by 013 it is a
///   clean two-checker stack (3852 px, top 0.867). All fifteen White men are on
///   points in every window;
/// * **turn 3 was `W 2-1: 13/10`**, one man. The 13-point drops 5→4 (disc
///   count, both instruments) and the 10-point gains its first man. Three pips
///   with the 12-point blocked can only be the 2 then the 1, and every other
///   die value was playable from that position, so no die was left unused;
/// * **turn 4 was `B 6-4: 1/11`**, one man — not `6-5: 1/12`. The 12-point's
///   stack top does not move until 018 (0.592 through 013, 0.500 after), and a
///   separate Black crescent appears at the **11-point's base** at 010 and is
///   gone at 020. Ten pips with the 6-point blocked cannot be 5-5, so 6-4 is
///   the only roll that reaches it;
/// * **turn 5 was `W 6-3: 13/7 13/10`**, two men — not `5-1: 13/8 8/7`. The
///   13-point drops 4→2, the 10-point rises 1→2 and the 7-point gains the blot
///   turn 6 then hits. This is the roll lying on the felt in 013, which the
///   ledger had been reading as the next turn's;
/// * **turn 7 was `W 5-2: bar/20 6/4`** — not `5-4: bar/20 8/4`. The 4-point
///   grows 2→3 (3150→5138 px, top 0.892→0.808, and the pipeline itself reads
///   white x3), the 6-point falls 4→3, the 8-point does not move, and the
///   2-point is empty in every window. A two-pip hop off the 6 is the whole
///   difference, and it makes the turn legal;
/// * **turn 8 was `B 6-3: 11/14 14/20*`** (~~`11/17 17/20*`~~, a slip: the
///   committed hops go via the 14) — the destination and the hit stand, and
///   the origin is the 11-point rather than the 12. **The ROLL is inferred,
///   not forced**, which the note claimed on 2026-08-22 and did not earn:
///   11→20 is nine pips, and at 018 the 15- and 16-points are both open, so
///   **5-4 reaches the same board by the same road with the same hit** and no
///   photograph can separate them. 6-3 is chosen for the 6 lying beside the
///   man on the hinge — and even that is weaker than it sounds, since the 6 in
///   question is on the face that die presents **to the camera** rather than
///   on its top (see 020's own note, and the partner die there, whose top does
///   read and reads 1). The pips are what is certain; the pair is a choice
///   between two positionally identical rolls.
///
/// The ledger below therefore replays as **eight legal turns**, every play in
/// `MoveGenerator.legalMoves`'s own list, reproducing all seven photographed
/// positions exactly. There is no anomaly, nothing off the board, and no shot
/// that needs a hand-read position — which is the strongest claim this corpus
/// has ever been able to make about its own ground truth, and it is made by
/// arithmetic rather than by eye. What it does **not** claim is that every
/// roll behind it is pinned: turn 8's is one of two that reach the same board,
/// and the ledger says which one it took only because a `FilmedTurn` has to
/// carry a pair to be replayed at all.
const List<FilmedTurn> _filmedTurns = <FilmedTurn>[
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
    hops: <(int, int)>[(17, 23), (19, 23)],
    notation: "B 6-4: 17/23 19/23 (Black's own 8/2 6/2)",
  ),
  (
    player: Player.white,
    die1: 2,
    die2: 1,
    // One man, and the intermediate point is forced rather than chosen: a
    // one-man 13/10 on a 2-1 cannot go via the 12, which Black owns five deep,
    // so it is the 2 first and then the 1. `GameState.canonicalPlay` folds both
    // orders to this one anyway.
    hops: <(int, int)>[(13, 11), (11, 10)],
    notation: 'W 2-1: 13/10 (one man, via the 11)',
  ),
  (
    player: Player.black,
    die1: 6,
    die2: 4,
    // Again one man and again the transit is the engine's: 1/5 5/11 and
    // 1/7 7/11 are the same play by two roads, no photograph can say which was
    // taken, and `MoveGenerator.legalMoves` lists the first.
    hops: <(int, int)>[(1, 5), (5, 11)],
    notation: 'B 6-4: 1/11 (one man, via the 5)',
  ),
  (
    player: Player.white,
    die1: 6,
    die2: 3,
    hops: <(int, int)>[(13, 7), (13, 10)],
    notation: 'W 6-3: 13/7 13/10',
  ),
  (
    player: Player.black,
    die1: 6,
    die2: 5,
    hops: <(int, int)>[(1, 7), (7, 12)],
    notation: "B 6-5: 1/7* 7/12 (hits White's blot on the 7)",
  ),
  (
    player: Player.white,
    die1: 5,
    die2: 2,
    hops: <(int, int)>[(kFilmedBar, 20), (6, 4)],
    notation: 'W 5-2: bar/20 6/4',
  ),
  (
    player: Player.black,
    die1: 6,
    die2: 3,
    // One man again, and again the road is the generator's: via the 14 or via
    // Black's own 17, indistinguishable once the man has arrived.
    hops: <(int, int)>[(11, 14), (14, 20)],
    notation: "B 6-3: 11/20* (one man, via the 14 — hits White's man on the "
        '20)',
  ),
];

/// A window cut from the footage, and which turn's board it shows.
///
/// [dice] is what the corpus will stand behind and [diceInFrame] is what is
/// physically in the picture; they are different questions on this footage and
/// conflating them is what `CorpusMetric.diceAbsence` was doing until
/// 2026-08-23. [diceDerived] marks a value fixed by arithmetic rather than
/// read off the pips.
typedef _FilmedCut = ({
  String id,
  String seconds,
  int afterTurn,
  Dice? dice,
  bool diceInFrame,
  bool diceDerived,
  String diceNote,
});

/// The seven windows the turn ledger covers.
///
/// Not one per turn: a window is only usable when the hands are out of it and
/// the checkers have settled, and turn 6's did not come. The log is cumulative
/// either way, so the gap costs a shot rather than a position — 018 is the
/// board after turn 7, and 013→018 is the one adjacent pair in this session
/// that spans two plays.
///
/// **018 and 020 came back here on 2026-08-22.** They were replayed positions,
/// then hand-read keyframes for a day, and are replayed again: the checker the
/// 2026-08-21 audit believed had left the board is on the 10-point, and turns 7
/// and 8 are legal once their rolls are read off the board instead of off a
/// zoom. See [_filmedTurns] for the measurements.
final List<_FilmedCut> _filmedPositions = <_FilmedCut>[
  (
    id: '003',
    seconds: '33.5',
    afterTurn: 1,
    dice: Dice(4, 2),
    diceInFrame: true,
    diceDerived: false,
    diceNote: 'The opening roll is still lying where it fell — a settled pair '
        'a person read off a zoom.',
  ),
  (
    id: '005',
    seconds: '49.5',
    afterTurn: 2,
    dice: Dice(6, 4),
    diceInFrame: true,
    diceDerived: false,
    diceNote: "Black's roll still on the left leaf, read off a zoom.",
  ),
  (
    id: '008',
    seconds: '76.5',
    afterTurn: 3,
    dice: null,
    diceInFrame: true,
    diceDerived: false,
    diceNote: '~~No dice on the felt: the next roll is mid-throw.~~ Wrong on '
        'both counts, and corrected 2026-08-23. TWO SETTLED DICE are lying in '
        'the far half, at board (0.218, 0.234) and (0.251, 0.279): absent at '
        't=66.5, in these exact positions at t=76.5 and t=84.5, gone by '
        't=94.5 — so they are this turn\'s own roll, left where they fell '
        'until Black picked them up. No roll is claimed all the same, because '
        'the faces a roll is read from are the ones this camera cannot see. '
        'Measured at full resolution: each die is about 21 px across and '
        'presents a top face 7-8 px deep, in which no pip pattern can be '
        'counted. What IS legible is the near-facing side of each — a clean '
        'diagonal pair on the left die, five blobs on the right that read as a '
        '3 and a 2 across two faces — and a side face is not a roll. The turn '
        'itself is 2-1 by arithmetic (one man, 13/10, three pips with the '
        '12-point blocked), and that is where the ledger gets it.',
  ),
  (
    id: '010',
    seconds: '94.5',
    afterTurn: 4,
    dice: Dice(6, 4),
    diceInFrame: true,
    diceDerived: true,
    diceNote: "Turn 4's own pair, lying where it fell in the far half. DERIVED "
        'rather than read, which is what the sidecar\'s `diceDerived` says in '
        'a form a machine can check: a die this deep into the far half shows '
        'this camera a front face and a sliver of top, and neither up face is '
        'legible — a zoom was read as 6-5 on 2026-08-21 and that is what the '
        'correction replaces. A ten-pip one-man play out of the 1-point, with '
        'the 6-point blocked four deep, can only have been thrown 6-4. The '
        'front faces are consistent with it and do not settle it: a clean 5 on '
        'the left die, so its top is neither 2 nor 5; a diagonal run of three '
        'pips (possibly four) on the right, which excludes 3 and 4 from its '
        'top either way.',
  ),
  (
    id: '013',
    seconds: '117.5',
    afterTurn: 5,
    dice: Dice(6, 3),
    diceInFrame: true,
    diceDerived: false,
    diceNote: "Turn 5's own pair, still lying where it fell — the 6 and the 3 "
        'the two men off the 13-point were played with. The ledger read this '
        "as the NEXT turn's roll until 2026-08-22, when the board said "
        'otherwise.',
  ),
  (
    id: '018',
    seconds: '162.5',
    afterTurn: 7,
    dice: null,
    diceInFrame: true,
    diceDerived: false,
    diceNote: '~~Dice in view but not settled enough for a person to call.~~ '
        'They are settled, and one of them is the most legible top face in the '
        'session: the die at board (0.398, 0.514) — the middle of the board, '
        'where this camera sees most of a top — shows a clean **5**, with a '
        'single large pip on its near face. Its partner is not readable, and '
        'half a pair is not a roll, so the sidecar still claims none.',
  ),
  (
    id: '020',
    seconds: '185.0',
    afterTurn: 8,
    dice: null,
    diceInFrame: true,
    diceDerived: false,
    diceNote: 'Two dice are in the picture and neither settles a roll. One '
        'lies against the man on the hinge and shows a clear 6 **to the '
        'camera** — a face pointing at the lens, not a top face, which is why '
        'it cannot be a die of the roll on its own. The other, at board '
        '(0.858, 0.405), has the better top face of the two and it carries a '
        'single centred pip: a **1**, measured 2026-08-23, with a diagonal '
        'pair on its near side. A 1 cannot be part of the nine-pip one-man '
        'play the ledger records for turn 8, so this pair is most likely the '
        'next roll rather than that one. Either way it is not a pair this '
        'sidecar claims, and turn 8\'s roll is inferred from the board — see '
        '[_filmedTurns].',
  ),
];

/// A window from the end of the video, with a position and no story.
typedef _FilmedKeyframe = ({
  String id,
  String seconds,
  BoardState board,
  String title,
  String evidence,
  bool diceInFrame,
  String diceNote,
});

/// The two windows that carry a board and no story.
///
/// Both are the end of the footage, which ran on past the ledger and was not
/// transcribable move by move — hands in shot, a hit nobody could pin to a
/// turn. Read cell by cell off zoomed frames, cross-checked against fifteen
/// checkers a side and against the machine's own deltas either side of them.
/// They are here because they hold the thing the ledger's opening never does —
/// a checker on the bar — and because a corpus of nothing but opening
/// positions would teach the pipeline that stacks are always where a game
/// starts. ~~and a board with men off it~~: they were believed to hold that
/// too, until 2026-08-23 found those men standing against the near rim. No
/// board in this corpus has a man off it, and the trayless-bear-off path is
/// covered by the folding-case fixture in `corpus_harness_test.dart` instead.
///
/// **018 and 020 spent a day here and have gone back to [_filmedPositions].**
/// The 2026-08-21 audit read a White checker as having left the board during
/// turn 7 and moved both windows out of the replay; measurement on 2026-08-22
/// found that checker standing on the 10-point, mostly behind the case's rim,
/// and both turns legal. The `off` count those two carried is gone with them.
///
/// **And on 2026-08-23 so is the `off` count these two carried.** ~~The only
/// shots still writing `off` are these two, where the game really has borne men
/// off~~: the same measurement that acquitted turn 7 was never run over the
/// keyframes, and when it was, each of them turned out to be hiding two White
/// men against the near rim rather than to have borne them off — one on the
/// 1-point and one more on the 7-point than the zooms counted. **Nothing in
/// this session ever leaves the board**, and no shot in it writes `off` at all.
/// The numbers are in each keyframe's evidence below.
final List<_FilmedKeyframe> _filmedKeyframes = <_FilmedKeyframe>[
  (
    id: '066',
    seconds: '680.0',
    board: BoardState(
      points: const <int>[
        1, -1, 0, 3, 2, 2, //  1-6   White's home, Black's entered runner on 2
        2, 3, 1, 0, 0, 0, //   7-12
        0, 0, 0, 0, -2, -1, // 13-18
        -3, -2, -2, -1, -2, 1, // 19-24, White's doomed blot on the 24
      ],
      blackBar: 1,
    ),
    title: 'End game — a Black checker on the bar',
    diceInFrame: true,
    evidence: 'Read cell by cell off five zooms (bar, both far quarters, both '
        'near quarters); the Black checker sits ON the worn hinge ridge, '
        'which is the object-versus-surface case this corpus exists to ask '
        'about. Two White men the zooms lost behind the near rim were put '
        'back by pixel measurement on 2026-08-23: the 1-point holds ONE '
        '(1666 cream px against 0-380 in every window before this one, a blob '
        'whose centroid inverts to board x 0.962 against the point centre of '
        '0.961) and the 7-point TWO rather than one (8243 px topping at board '
        'y 0.864 — the two-man signature the 8-point measures 8420-8923 for, '
        'against 12337-14122 for three). Fifteen White men stand on points '
        'here; none is off.',
    diceNote: 'A 3 is visible on the hinge and its partner is not, so the '
        'sidecar claims no roll rather than half of one.',
  ),
  (
    id: '070',
    seconds: '729.0',
    board: BoardState(
      points: const <int>[
        1, -2, 0, 3, 2, 2, //  1-6
        3, 2, 1, 0, 0, 0, //   7-12
        0, 0, 0, 0, -1, -2, // 13-18
        -2, -2, -2, 1, -2, -2, // 19-24, White's straggler trapped on the 22
      ],
    ),
    title: 'End game — the last frame, a White straggler trapped',
    diceInFrame: true,
    evidence: 'Read cell by cell off five zooms and cross-checked against the '
        "machine's deltas either side; the video ends here with the game "
        'unfinished. Two rim-hidden White men were put back by pixel '
        'measurement on 2026-08-23, the same pair 066 was hiding: the 1-point '
        'holds ONE (1512 cream px, a compact blob at board y 0.92-0.97) and '
        'the 7-point THREE rather than two (12771 px topping at 0.765, one '
        'whole pitch above 066\'s two). Fifteen White men on points, none off '
        '— and the correction leaves the pair consistent rather than making '
        'it so, since White\'s cells here still differ from 066\'s by exactly '
        'the three pips of a 2-1 (8/7, 24/22). That is corroboration and not '
        'a claim about the gap: Black\'s cells differ by more than one turn '
        'can account for, which is why both windows carry a board and no log.',
    diceNote: 'Two dice are lying on the felt mid-sequence and neither can be '
        'attributed to a turn, so the sidecar claims no roll.',
  ),
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

/// The eight points, as the four outer ones plus the four hinge seams. Written
/// out under the same names the type uses, so a person editing a sidecar by
/// hand can see which point is which.
Map<String, dynamic> _foldingToJson(FoldingCorners c) => <String, dynamic>{
      ..._quadToJson(c.outer),
      'hingeFarLeft': <double>[c.hingeFarLeft.x, c.hingeFarLeft.y],
      'hingeFarRight': <double>[c.hingeFarRight.x, c.hingeFarRight.y],
      'hingeNearLeft': <double>[c.hingeNearLeft.x, c.hingeNearLeft.y],
      'hingeNearRight': <double>[c.hingeNearRight.x, c.hingeNearRight.y],
    };

FoldingCorners _foldingFromJson(Map<String, dynamic> json) {
  Pt at(String key) {
    final pair = json[key] as List<dynamic>;
    return Pt((pair[0] as num).toDouble(), (pair[1] as num).toDouble());
  }

  return FoldingCorners(
    topLeft: at('topLeft'),
    topRight: at('topRight'),
    bottomRight: at('bottomRight'),
    bottomLeft: at('bottomLeft'),
    hingeFarLeft: at('hingeFarLeft'),
    hingeFarRight: at('hingeFarRight'),
    hingeNearLeft: at('hingeNearLeft'),
    hingeNearRight: at('hingeNearRight'),
  );
}

BoardState _boardFromJson(Map<String, dynamic> json) => BoardState(
      points: <int>[
        for (final p in json['points'] as List<dynamic>) (p as num).toInt(),
      ],
      whiteBar: (json['whiteBar'] as num).toInt(),
      blackBar: (json['blackBar'] as num).toInt(),
      whiteOff: (json['whiteOff'] as num).toInt(),
      blackOff: (json['blackOff'] as num).toInt(),
    );
