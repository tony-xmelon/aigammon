import 'dart:async';
import 'dart:math' as math;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../buddy/buddy_session.dart';
import '../../buddy/camera_frame_source.dart';
import '../game/tap_when_disabled.dart';

// -----------------------------------------------------------------------------
// The seams.
//
// Two of them, and both exist for the same reason the QR scanner has one: the
// camera and the calibrator are the two things a widget test cannot have, and
// everything else on this screen — which stage we are in, where the handles
// are, what the derived columns look like, what happens when board_vision says
// no — is decidable on a desktop with no camera at all.
// -----------------------------------------------------------------------------

/// The camera, behind four methods.
///
/// This screen never touches `package:camera` directly. It asks for a preview
/// widget and a frame stream and deals with the two ways opening can end; a
/// widget test overrides [buddyCameraProvider] with a scripted camera and
/// drives the whole flow from "the user dragged a handle" to "a calibration
/// came out".
abstract interface class BuddyCamera {
  /// Starts the camera. Never throws: a camera that cannot be opened comes
  /// back as [CameraUnavailable].
  Future<CameraOpening> open();

  /// Every frame the gate published, stable or not. The unstable ones are what
  /// "hold the phone still" is said about.
  Stream<ObservedFrame> get frames;

  /// What to draw under the corner handles.
  Widget preview(BuildContext context);

  /// Releases the camera. Safe to call more than once.
  Future<void> close();
}

/// How opening the camera ended.
sealed class CameraOpening {
  const CameraOpening();
}

/// There is a preview and there will be frames.
final class CameraReady extends CameraOpening {
  const CameraReady();
}

/// There is not — permission refused, no camera, or the platform said no.
/// [message] is user-facing and is shown as it stands.
final class CameraUnavailable extends CameraOpening {
  const CameraUnavailable(this.message);

  final String message;
}

/// Learning a board, behind one call.
///
/// `BoardVision.calibrate` and `BoardVision.calibrateFolding` are statics over
/// a photograph, so a widget test cannot script them. This is the door they go
/// through, and [visionFor] is here rather than at the call site for the same
/// reason: the confirmation step asks the new vision a question, and a test
/// needs that answer to be its own.
abstract interface class BoardLearner {
  CalibrationResult learn({
    required Frame frame,
    required BoardHandles handles,
    required BoardOrientation orientation,
    required double dieSide,
  });

  BoardVision visionFor(BoardCalibration calibration);
}

/// The real one: `board_vision`'s two entry points, chosen by the board type.
class RealBoardLearner implements BoardLearner {
  const RealBoardLearner();

  @override
  CalibrationResult learn({
    required Frame frame,
    required BoardHandles handles,
    required BoardOrientation orientation,
    required double dieSide,
  }) {
    final size = Size(frame.width.toDouble(), frame.height.toDouble());
    return handles.isFolding
        ? BoardVision.calibrateFolding(
            frame: frame,
            corners: handles.foldingIn(size),
            orientation: orientation,
            dieSide: dieSide,
          )
        : BoardVision.calibrate(
            frame: frame,
            corners: handles.quadIn(size),
            orientation: orientation,
            dieSide: dieSide,
          );
  }

  @override
  BoardVision visionFor(BoardCalibration calibration) =>
      BoardVision(calibration);
}

final boardLearnerProvider =
    Provider<BoardLearner>((ref) => const RealBoardLearner());

/// The camera this screen uses. Overridden in widget tests with a scripted one.
final buddyCameraProvider = Provider<BuddyCamera>((ref) {
  final camera = PhoneBuddyCamera();
  ref.onDispose(camera.shutDown);
  return camera;
});

// -----------------------------------------------------------------------------
// The handles.
// -----------------------------------------------------------------------------

/// Where a hinge seam is seeded along its edge, either side of the middle.
///
/// The first real folding board's strip measured 6.7% of the width at the far
/// edge and 7.5% at the near one, so a seed of 7% centred on each edge puts
/// both handles within a few pixels of where they belong on a board like that
/// one — close enough that the user is nudging rather than hunting.
const double _kSeedBarWidth = 0.07;

/// The outline of the playing field as the user has dragged it, in coordinates
/// NORMALIZED to the camera frame: 0..1 across and 0..1 down.
///
/// **Normalized, and that is load-bearing rather than tidy.** The preview a
/// finger drags on and the [Frame] perception reads are two different pictures
/// of one scene at two different sizes — a preview is laid out in logical
/// pixels and a frame arrives at whatever the camera negotiated — and the
/// corpus work measured what happens when corner points are carried between
/// sizes: the set of corner placements a calibration accepts does not merely
/// shrink, it MOVES. So nothing here is ever a pixel. The handles are fractions
/// of the picture, and they become pixels exactly once, in [quadIn] or
/// [foldingIn], against the very frame that is about to be calibrated.
@immutable
class BoardHandles {
  const BoardHandles({required this.outer, this.hinge = const <Offset>[]});

  /// The playing field's four corners, clockwise from the top left as the
  /// frame shows them — [BoardQuad]'s own order.
  final List<Offset> outer;

  /// A folding case's four hinge seams, clockwise from the far-left one:
  /// `[farLeft, farRight, nearRight, nearLeft]` — [FoldingCorners]'s ring
  /// order. Empty on a board that does not fold.
  final List<Offset> hinge;

  /// The starting outline: a board-shaped rectangle inset from the edges of the
  /// picture.
  ///
  /// Inset rather than flush, and deliberately in both directions. Handles that
  /// start at the very edge of the frame are half off it — awkward to grab —
  /// and, worse, they start on the ROOM rather than on the board, which invites
  /// exactly the mistake the corner step is about.
  factory BoardHandles.seed({required bool folding}) => const BoardHandles(
        outer: <Offset>[
          Offset(0.10, 0.15),
          Offset(0.90, 0.15),
          Offset(0.90, 0.85),
          Offset(0.10, 0.85),
        ],
      ).asFolding(folding);

  bool get isFolding => hinge.length == 4;

  /// Every handle, outer ones first — the order the on-screen keys use.
  List<Offset> get all => <Offset>[...outer, ...hinge];

  /// This outline with the hinge seams added (seeded on the two edges' middles)
  /// or taken away, keeping whatever the outer corners have become.
  BoardHandles asFolding(bool folding) {
    if (folding == isFolding) return this;
    if (!folding) return BoardHandles(outer: outer);
    Offset along(Offset a, Offset b, double t) =>
        Offset(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t);
    const lo = 0.5 - _kSeedBarWidth / 2;
    const hi = 0.5 + _kSeedBarWidth / 2;
    return BoardHandles(
      outer: outer,
      hinge: <Offset>[
        along(outer[0], outer[1], lo),
        along(outer[0], outer[1], hi),
        along(outer[3], outer[2], hi),
        along(outer[3], outer[2], lo),
      ],
    );
  }

  /// This outline with handle [index] moved to [to], kept inside the picture.
  BoardHandles movedTo(int index, Offset to) {
    final clamped = Offset(to.dx.clamp(0.0, 1.0), to.dy.clamp(0.0, 1.0));
    final points = all..[index] = clamped;
    return BoardHandles(
      outer: points.sublist(0, 4),
      hinge: points.length > 4 ? points.sublist(4) : const <Offset>[],
    );
  }

  /// The four outer corners in the pixels of a [frame]-sized picture.
  BoardQuad quadIn(Size frame) => BoardQuad.fromCorners(<Pt>[
        for (final p in outer) Pt(p.dx * frame.width, p.dy * frame.height),
      ]);

  /// All eight points, in the pixels of a [frame]-sized picture.
  FoldingCorners foldingIn(Size frame) {
    Pt at(Offset p) => Pt(p.dx * frame.width, p.dy * frame.height);
    return FoldingCorners(
      topLeft: at(outer[0]),
      topRight: at(outer[1]),
      bottomRight: at(outer[2]),
      bottomLeft: at(outer[3]),
      hingeFarLeft: at(hinge[0]),
      hingeFarRight: at(hinge[1]),
      hingeNearRight: at(hinge[2]),
      hingeNearLeft: at(hinge[3]),
    );
  }

  /// Board space into the NORMALIZED picture, or null when these points do not
  /// describe a board at all.
  ///
  /// Null is a state the user can reach in one drag — a handle pulled past its
  /// neighbour turns the outline into a bowtie — so it is an answer rather than
  /// an error: the overlay stops being drawn and the step's forward button
  /// explains itself instead of failing later with a sentence about corners.
  BoardGeometry? get geometry {
    try {
      const unit = Size(1, 1);
      return isFolding
          ? FoldingBoardGeometry(foldingIn(unit))
          : PlanarBoardGeometry.fromQuad(quadIn(unit));
    } on ArgumentError {
      return null;
    }
  }

  /// How wide this board's trays and bar are. A folding case says so itself
  /// (no wells, and a bar the width of the strip the hinge handles delimit);
  /// anything else is an ordinary board.
  BoardProportions get proportions {
    if (!isFolding) return BoardProportions.standard;
    try {
      return foldingIn(const Size(1, 1)).proportions;
    } on ArgumentError {
      return BoardProportions.standard;
    }
  }

  /// The twenty-four point columns and the bar — twenty-five rings — as closed
  /// polygons in the normalized picture, or empty when [geometry] is null.
  ///
  /// **This is the feedback the corner step exists to give.** A machine sweep
  /// of one real frame found seventy-nine corner placements that calibrate AND
  /// pass the start-position check — every one of which would show a person a
  /// green light — whose checker counts ran from 13 of 24 to 23 of 24. The
  /// accepting region is not a plateau a careful hand lands in the middle of;
  /// it is scattered, and "accepted" is not the same as "good". What a person
  /// CAN see, instantly and without being told what to look for, is a column
  /// line that misses its own stack. So the lines are drawn.
  List<List<Offset>> outlines(BoardOrientation orientation) {
    final map = geometry;
    if (map == null) return const <List<Offset>>[];
    final atlas = RoiAtlas.forOrientation(orientation, proportions: proportions);
    final rings = <List<Offset>>[];
    for (var i = 0; i < 24; i++) {
      rings.add(_ring(map, atlas.roi(RoiId.point(i))));
    }
    rings.add(_ring(map, atlas.roi(RoiId.bar)));
    return rings;
  }

  static List<Offset> _ring(BoardGeometry map, BoardQuad quad) => <Offset>[
        for (final corner in quad.corners)
          () {
            final p = map.imagePointOf(corner);
            return Offset(p.x, p.y);
          }(),
      ];
}

// -----------------------------------------------------------------------------
// What the screen is asked for, and what it hands back.
// -----------------------------------------------------------------------------

/// What the caller knows before the camera opens.
@immutable
class CalibrationRequest {
  const CalibrationRequest({
    required this.userSide,
    required this.seat,
    this.seededHandles,
    this.dieSide = BoardCalibration.defaultDieSide,
  });

  /// The colour the user is playing — the other half of what fixes the point
  /// numbering.
  final Player userSide;

  /// Where the setup screen was told the user sits. Proposed here rather than
  /// asked again from nothing: the user confirms it against the picture, and
  /// what they confirm comes back on [CalibrationOutcome.seat].
  ///
  /// **There is deliberately no `orientation` here.** This seat is the one the
  /// screen OPENS on, and the screen's whole seat step exists because it can be
  /// wrong; a getter here would hand a caller the pre-confirmation frame under
  /// a name that reads like the answer. The 24-point frame is
  /// `orientationFor(userSide, seat)` computed against the CONFIRMED seat —
  /// once inside the screen, and once by whoever takes
  /// [CalibrationOutcome.seat] away.
  final BuddySeat seat;

  /// The outline a previous calibration used, when this is a RECALIBRATION.
  ///
  /// Its presence is what makes the mid-session path the fast one the spec
  /// asks for: the screen opens on the corners with them already where they
  /// were, so a phone that got nudged is a nudge to fix rather than a setup to
  /// repeat.
  final BoardHandles? seededHandles;

  /// How wide this session's dice are, as a fraction of the board.
  ///
  /// Carried rather than measured. `BoardCalibration.dieSide` cannot be a
  /// constant — the first real board's dice were a third of the synthetic
  /// bed's — and the intended source is the first roll of the session, where
  /// two blobs appearing in a band that was empty a second ago are dice by
  /// construction. That measurement needs a size-agnostic blob finder in
  /// `board_vision` and does not exist yet; until it does this is the default,
  /// and the manual dice pad is what carries a session whose dice cannot be
  /// found.
  final double dieSide;
}

/// A learned board, and the two things the caller has to carry forward.
@immutable
class CalibrationOutcome {
  const CalibrationOutcome({
    required this.vision,
    required this.handles,
    required this.seat,
  });

  /// Ready to be handed to `BuddySession.useCalibration`.
  final BoardVision vision;

  /// What the user dragged, so the next recalibration can pre-seed it.
  final BoardHandles handles;

  /// The seat as CONFIRMED against the picture, which may not be the one the
  /// setup screen proposed — this is the screen where a person looks at their
  /// own board and can see which half is theirs. It is what a session should
  /// be built with, because it is what tells the two opening dice apart.
  final BuddySeat seat;
}

/// Where the guided flow has got to.
enum CalibrationStage {
  /// The three things that have to be true of the board before a picture of it
  /// is worth taking.
  aiming,

  /// The handles, the derived columns, and the loupe.
  corners,

  /// Which half of the picture is the user's own home board.
  seat,

  /// Waiting for a settled frame to learn from.
  capturing,

  /// The belief, drawn over the board it came from, for a person to agree with.
  confirming,
}

// -----------------------------------------------------------------------------

/// The guided calibration flow, and the same screen for recalibration.
///
/// ## Why the confirmation step is not ceremony
///
/// `board_vision` already reads its own calibration frame back before it hands
/// a calibration over, so a calibration that reaches this step is
/// self-consistent. What it is not is necessarily RIGHT: the read-back checks
/// colours and the start-position check checks colours, and the corner sweep
/// on real footage found placements that pass both while counting ten checkers
/// wrong. A mis-calibration caught here costs the seconds it takes to nudge
/// four handles. Caught mid-game, it costs the session.
class CalibrationScreen extends ConsumerStatefulWidget {
  const CalibrationScreen({
    super.key,
    required this.request,
    required this.onCalibrated,
  });

  final CalibrationRequest request;

  /// Called once, with a vision the caller may hand straight to a session.
  final ValueChanged<CalibrationOutcome> onCalibrated;

  @override
  ConsumerState<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends ConsumerState<CalibrationScreen> {
  late final BuddyCamera _camera = ref.read(buddyCameraProvider);
  StreamSubscription<ObservedFrame>? _frames;

  late CalibrationStage _stage;
  late BoardHandles _handles;
  late BuddySeat _seat;
  CameraOpening? _opening;
  ObservedFrame? _latest;

  /// The handle under the finger, or null. Drives the loupe.
  int? _dragging;

  /// The sentence `board_vision` wrote about the last refusal, or null.
  String? _problem;

  BoardVision? _vision;
  ConfirmResult? _confirmation;

  /// The size of the frame the calibration was learned from, which is the
  /// space its geometry maps into.
  Size? _learnedOn;

  @override
  void initState() {
    super.initState();
    final seeded = widget.request.seededHandles;
    _handles = seeded ?? BoardHandles.seed(folding: false);
    _seat = widget.request.seat;
    // A recalibration opens on the corners: the board has already been
    // explained once, and what changed is where it is.
    _stage = seeded == null ? CalibrationStage.aiming : CalibrationStage.corners;
    unawaited(_open());
  }

  Future<void> _open() async {
    final opening = await _camera.open();
    if (!mounted) return;
    setState(() => _opening = opening);
    if (opening is CameraReady) {
      _frames = _camera.frames.listen(_onFrame);
    }
  }

  @override
  void dispose() {
    unawaited(_frames?.cancel());
    unawaited(_camera.close());
    super.dispose();
  }

  void _onFrame(ObservedFrame f) {
    if (!mounted) return;
    setState(() => _latest = f);
    if (!f.isStable) return;
    final vision = _vision;
    switch (_stage) {
      case CalibrationStage.capturing:
        _learn(f);
      case CalibrationStage.confirming:
        // Keep asking. A user who sees the belief disagree with the board will
        // move a checker, and the answer has to follow the board rather than
        // stay frozen on the frame that happened to be learned from.
        if (vision != null) {
          setState(() => _confirmation = vision.confirmStartingPosition(f.frame));
        }
      case CalibrationStage.aiming ||
            CalibrationStage.corners ||
            CalibrationStage.seat:
        break;
    }
  }

  /// One attempt, on one settled frame.
  void _learn(ObservedFrame f) {
    final result = ref.read(boardLearnerProvider).learn(
          frame: f.frame,
          handles: _handles,
          orientation: _orientation,
          dieSide: widget.request.dieSide,
        );
    final calibration = result.calibration;
    if (calibration == null) {
      // Every refusal names something the user can act on, and the sentence is
      // written to be shown as it stands. Back to the handles with them where
      // they were: whatever went wrong, starting the outline again is not the
      // fix.
      setState(() {
        _problem = result.message;
        _stage = CalibrationStage.corners;
      });
      return;
    }
    final vision = ref.read(boardLearnerProvider).visionFor(calibration);
    setState(() {
      _vision = vision;
      _problem = null;
      _learnedOn = Size(f.frame.width.toDouble(), f.frame.height.toDouble());
      // On the very frame it was learned from, so the confirmation step has
      // something to show without waiting for the board to settle twice.
      _confirmation = vision.confirmStartingPosition(f.frame);
      _stage = CalibrationStage.confirming;
    });
  }

  void _goTo(CalibrationStage stage) => setState(() {
        _stage = stage;
        if (stage != CalibrationStage.confirming) {
          _vision = null;
          _confirmation = null;
        }
      });

  void _setFolding(bool folding) => setState(() {
        _handles = _handles.asFolding(folding);
        _problem = null;
      });

  void _accept() {
    final vision = _vision;
    if (vision == null) return;
    widget.onCalibrated(
      CalibrationOutcome(vision: vision, handles: _handles, seat: _seat),
    );
  }

  @override
  Widget build(BuildContext context) {
    final opening = _opening;
    return Scaffold(
      appBar: AppBar(title: const Text('Show Buddy the board')),
      body: SafeArea(
        child: switch (opening) {
          CameraUnavailable(:final message) => _NoCamera(message: message),
          _ => Column(
              children: [
                Expanded(child: _body(context)),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: _footer(context),
                ),
              ],
            ),
        },
      ),
    );
  }

  Widget _body(BuildContext context) => switch (_stage) {
        CalibrationStage.aiming => _AimStep(
            folding: _handles.isFolding,
            onFoldingChanged: _setFolding,
          ),
        _ => Column(
            children: [
              Expanded(child: _preview(context)),
              _caption(context),
            ],
          ),
      };

  /// The live picture, the outline over it, and — on the confirming step — the
  /// position Buddy believes it is looking at.
  ///
  /// ## The assumption this whole screen rests on, stated out loud
  ///
  /// **Every overlay here maps normalized frame coordinates straight onto the
  /// preview box, which is only right if the preview shows the whole sensor
  /// frame, the same way up, unmirrored, and with no letterbox.** The box is
  /// given the FRAME's aspect ratio and the preview is stretched into it with
  /// `Positioned.fill` — which squelches `CameraPreview`'s own `AspectRatio`
  /// rather than fighting it — so under that assumption a handle at (0.3, 0.7)
  /// of the box is at (0.3, 0.7) of the frame, which is exactly what
  /// [BoardHandles.quadIn] then converts. Nothing anywhere in Buddy Mode
  /// handles preview rotation or mirroring.
  ///
  /// If the assumption is false, every handle is in the wrong coordinate frame
  /// and the failure is silent: the outline lands somewhere plausible, the
  /// calibration may even succeed, and the columns are simply wrong. The
  /// consolation is that the loud half is loud — a phone held in portrait shows
  /// a preview turned on its side, which no one can miss — and landscape is the
  /// natural way to aim a phone at a board anyway.
  ///
  /// **This is the FIRST item in Task 15's on-device protocol**, and it needs a
  /// real phone: put a handle on a real corner, in both orientations, and look
  /// at whether it stays there.
  Widget _preview(BuildContext context) {
    final frame = _latest?.frame;
    final aspect = frame == null || frame.height == 0
        ? 4 / 3
        : frame.width / frame.height;
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final box = Size(constraints.maxWidth, constraints.maxHeight);
            final showHandles = _stage == CalibrationStage.corners;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(child: _camera.preview(context)),
                Positioned.fill(
                  child: CustomPaint(
                    key: const Key('buddy-board-outline'),
                    painter: BoardOutlinePainter(
                      handles: _handles,
                      columns: _handles.outlines(_orientation),
                      edge: scheme.primary,
                      column: scheme.primary.withValues(alpha: 0.55),
                    ),
                  ),
                ),
                if (_stage == CalibrationStage.confirming && _vision != null)
                  Positioned.fill(
                    child: CustomPaint(
                      key: const Key('buddy-belief'),
                      painter: BeliefPainter(
                        calibration: _vision!.calibration,
                        frame: _learnedOn ?? box,
                        offending: <RoiId>{
                          for (final d in _confirmation?.discrepancies ??
                              const <PointDiscrepancy>[])
                            d.region,
                        },
                        wrong: scheme.error,
                      ),
                    ),
                  ),
                if (showHandles) ..._handleWidgets(box),
                if (showHandles && _dragging != null) _loupe(box, scheme),
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _handleWidgets(Size box) {
    final points = _handles.all;
    return <Widget>[
      for (var i = 0; i < points.length; i++)
        Positioned(
          left: points[i].dx * box.width - CalibrationHandle.touchSize / 2,
          top: points[i].dy * box.height - CalibrationHandle.touchSize / 2,
          child: CalibrationHandle(
            key: Key('buddy-handle-$i'),
            index: i,
            hinge: i >= 4,
            active: _dragging == i,
            onStart: () => setState(() => _dragging = i),
            onMove: (delta) => _nudge(i, delta, box),
            onEnd: () => setState(() => _dragging = null),
          ),
        ),
    ];
  }

  /// Moves handle [i] by [delta] PIXELS of a [box]-sized preview.
  ///
  /// **Against the current handle, never against the one this frame was built
  /// with.** A touch screen reports moves faster than a phone draws frames, so
  /// several of these arrive between two builds as a matter of course; adding
  /// each to a position captured at build time keeps only the last of them, and
  /// the handle lags the finger by the ratio of the two rates and stops short of
  /// where it was put. On the one screen in the app whose whole purpose is
  /// placing a point to within a few pixels.
  void _nudge(int i, Offset delta, Size box) => setState(() {
        _handles = _handles.movedTo(
          i,
          _handles.all[i] +
              Offset(delta.dx / box.width, delta.dy / box.height),
        );
      });

  /// The loupe over the handle being dragged.
  ///
  /// The measured mistake this is for: a first pass at the four corners of a
  /// real board put two of them 10 to 40 pixels inside the felt, on the wooden
  /// rim — and a fingertip is wider than the error. A magnified view above the
  /// finger is the difference between placing a handle and guessing where it
  /// went.
  Widget _loupe(Size box, ColorScheme scheme) {
    final point = _handles.all[_dragging!];
    final at = Offset(point.dx * box.width, point.dy * box.height);
    // Above the finger, unless the handle is near the top of the picture, in
    // which case the loupe would be off it.
    final below = at.dy < _kLoupeLift + _kLoupeSize / 2;
    final lift = below ? -_kLoupeLift : _kLoupeLift;
    return Positioned(
      left: at.dx - _kLoupeSize / 2,
      top: at.dy - lift - _kLoupeSize / 2,
      child: RawMagnifier(
        decoration: MagnifierDecoration(
          shape: CircleBorder(
            side: BorderSide(color: scheme.primary, width: 2),
          ),
        ),
        size: const Size.square(_kLoupeSize),
        focalPointOffset: Offset(0, lift),
        magnificationScale: 2.4,
      ),
    );
  }

  Widget _caption(BuildContext context) {
    final theme = Theme.of(context);
    final problem = _problem;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (problem != null) ...[
            _Notice(problem, tone: theme.colorScheme.error),
            const SizedBox(height: 12),
          ],
          ...switch (_stage) {
            CalibrationStage.corners => <Widget>[
                Text(
                  _handles.isFolding
                      ? 'Drag the four outer handles onto the corners of the '
                          'felt — not the wooden rim — and the four small ones '
                          'onto the seams where the hinge meets the far and '
                          'near edges.'
                      : 'Drag each handle onto a corner of the felt — the '
                          'playing surface, not the wooden rim around it.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Then check the twelve lines down each half: every one should '
                  'run along a point of your board. A line that misses its '
                  'point is a handle that needs nudging.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            CalibrationStage.seat => <Widget>[
                Text('Which half is your home board?',
                    style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                SegmentedButton<BuddySeat>(
                  showSelectedIcon: false,
                  segments: const <ButtonSegment<BuddySeat>>[
                    ButtonSegment(
                      value: BuddySeat.near,
                      label: Text('The near half'),
                    ),
                    ButtonSegment(
                      value: BuddySeat.far,
                      label: Text('The far half'),
                    ),
                  ],
                  selected: <BuddySeat>{_seat},
                  onSelectionChanged: (s) => setState(() => _seat = s.first),
                ),
                const SizedBox(height: 8),
                Text(
                  'The half nearest the bottom of the picture. This is what '
                  'fixes the point numbers, so the lines above move with it.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            // No spinner here, and that is not an aesthetic choice: an
            // indeterminate progress indicator animates forever, and a widget
            // test that pumps until the tree is idle would never finish. The
            // wait is a fraction of a second anyway — the sentence IS the
            // affordance, because it says what to do with the wait.
            CalibrationStage.capturing => <Widget>[
                Row(
                  children: [
                    const Icon(Icons.back_hand_outlined, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Hold the phone still. Buddy is waiting for the '
                        'picture to settle before it learns this board.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ],
            CalibrationStage.confirming => <Widget>[
                Text('Is this your board?', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  _confirmation?.message ??
                      'Buddy is looking at the board it just learned.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'The men drawn over the picture are what Buddy thinks is on '
                  'the board. If any of them are in the wrong place, start '
                  'over — it costs seconds now and a game later.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            CalibrationStage.aiming => const <Widget>[],
          },
        ],
      ),
    );
  }

  /// The 24-point frame the confirmed seat and the user's colour imply.
  ///
  /// The question on screen is the seat, not this — "which half is your home
  /// board" is something a person can answer by looking at their own board,
  /// and `whiteHomeNear` is not. The two are the same fact.
  BoardOrientation get _orientation =>
      orientationFor(widget.request.userSide, _seat);

  Widget _footer(BuildContext context) {
    final buttons = switch (_stage) {
      CalibrationStage.aiming => <Widget>[
          _forward('Next', () => _goTo(CalibrationStage.corners)),
        ],
      CalibrationStage.corners => <Widget>[
          _back('Back', () => _goTo(CalibrationStage.aiming)),
          _forward(
            'Next',
            _handles.geometry == null
                ? null
                : () => _goTo(CalibrationStage.seat),
            disabledReason: 'Those four handles do not outline a board — one '
                'of them has crossed another. Drag them back to the corners of '
                'the felt.',
          ),
        ],
      CalibrationStage.seat => <Widget>[
          _back('Back', () => _goTo(CalibrationStage.corners)),
          _forward('Capture', () => _goTo(CalibrationStage.capturing)),
        ],
      CalibrationStage.capturing => <Widget>[
          _back('Back', () => _goTo(CalibrationStage.corners)),
        ],
      CalibrationStage.confirming => <Widget>[
          _back('Start over', () => _goTo(CalibrationStage.corners)),
          _forward('Looks right', _vision == null ? null : _accept),
        ],
    };
    return Row(
      children: <Widget>[
        for (final (i, button) in buttons.indexed) ...<Widget>[
          if (i > 0) const SizedBox(width: 12),
          Expanded(child: button),
        ],
      ],
    );
  }

  Widget _back(String label, VoidCallback onPressed) => OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
        child: Text(label),
      );

  Widget _forward(String label, VoidCallback? onPressed,
      {String? disabledReason}) {
    final button = FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
      ),
      child: Text(label),
    );
    if (onPressed != null || disabledReason == null) return button;
    // A dead button cannot say why it is dead.
    return TapWhenDisabled(
      onDisabledTap: () => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(disabledReason)),
      ),
      child: button,
    );
  }
}

const double _kLoupeSize = 108;
const double _kLoupeLift = 84;

// -----------------------------------------------------------------------------
// The steps that are not the preview.
// -----------------------------------------------------------------------------

/// Everything that has to be true of the board before a picture of it is worth
/// taking.
class _AimStep extends StatelessWidget {
  const _AimStep({required this.folding, required this.onFoldingChanged});

  final bool folding;
  final ValueChanged<bool> onFoldingChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Three things first', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                const _Step(
                  icon: Icons.casino_outlined,
                  title: 'Take the dice off the board.',
                  // The one mistake with a permanent cost. A die on the felt
                  // during calibration is learned as part of the board's own
                  // surface, and the dice reader looks for what the board does
                  // not account for — so that die, and every die like it, is
                  // invisible for the rest of the session.
                  detail: 'Buddy learns the bare board now. A die left on the '
                      'felt is learned as part of it, and then Buddy can never '
                      'see the dice again this session.',
                ),
                const _Step(
                  icon: Icons.grid_view_outlined,
                  title: 'Set the men up for the start of a game.',
                  detail: 'Thirty checkers in known places is how Buddy learns '
                      'this board\'s two colours without being told what they '
                      'are.',
                ),
                const _Step(
                  icon: Icons.center_focus_strong_outlined,
                  title: 'Fit the whole playing field in the picture.',
                  detail: 'Then leave the phone where it is. If it moves, '
                      'Buddy will say so and you can nudge the corners back.',
                ),
                const SizedBox(height: 24),
                Text('What kind of board is it?',
                    style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('Flat board')),
                    ButtonSegment(value: true, label: Text('Folding case')),
                  ],
                  selected: {folding},
                  onSelectionChanged: (s) => onFoldingChanged(s.first),
                ),
                const SizedBox(height: 8),
                Text(
                  'A case that folds in half sits slightly tented, so its two '
                  'leaves are not in one plane and no four corners describe it. '
                  'Pick it and you will place four extra points on the hinge.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.title, required this.detail});

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(detail),
        isThreeLine: true,
      );
}

class _NoCamera extends StatelessWidget {
  const _NoCamera({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, size: 40),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              Text(
                'Buddy Mode watches a real board, so it cannot start without '
                'the camera. Everything else in the app is unaffected.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
}

class _Notice extends StatelessWidget {
  const _Notice(this.message, {required this.tone});

  final String message;
  final Color tone;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: tone),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: tone),
            ),
          ),
        ],
      );
}

/// One corner, draggable — and nudgeable without a finger.
///
/// **A drag was the only way to place one of these, and a drag is not a thing
/// everyone has.** The accepting corner region is narrow enough that this
/// screen carries a magnifier to help a fingertip land in it; someone driving
/// the phone with a switch, a keyboard or a screen reader had no way to land in
/// it at all. So the four arrow keys move a focused handle by
/// [nudgeStep], and the same four moves are custom semantic actions, which is
/// how TalkBack and VoiceOver offer them.
///
/// The loupe stays a drag affordance: it exists because a finger covers the
/// handle it is placing, and nothing covers a handle being nudged.
class CalibrationHandle extends StatefulWidget {
  const CalibrationHandle({
    super.key,
    required this.index,
    required this.hinge,
    required this.active,
    required this.onStart,
    required this.onMove,
    required this.onEnd,
  });

  /// The touch target, which is a great deal larger than the mark drawn in it.
  static const double touchSize = 48;

  /// How far one arrow key or one semantic nudge moves a handle, in the
  /// preview's own logical pixels.
  ///
  /// One, because this is the *last* pixel rather than the first: a drag does
  /// the coarse placement and this is what corrects it. The measured first-pass
  /// error on a real board was 10 to 40 FRAME pixels onto the wooden rim, and a
  /// preview is laid out at rather fewer logical pixels than the frame has, so
  /// a handful of taps covers it.
  static const double nudgeStep = 1;

  final int index;

  /// Whether this is one of a folding case's four hinge seams, which are drawn
  /// smaller: they sit on a line down the middle of the picture with board on
  /// both sides, and a large mark would hide the seam it is being placed on.
  final bool hinge;

  final bool active;
  final VoidCallback onStart;
  final ValueChanged<Offset> onMove;
  final VoidCallback onEnd;

  @override
  State<CalibrationHandle> createState() => _CalibrationHandleState();
}

class _CalibrationHandleState extends State<CalibrationHandle> {
  late final FocusNode _focus = FocusNode(
    debugLabel: 'calibration handle ${widget.index}',
  );
  bool _focused = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    const step = CalibrationHandle.nudgeStep;
    final by = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => const Offset(-step, 0),
      LogicalKeyboardKey.arrowRight => const Offset(step, 0),
      LogicalKeyboardKey.arrowUp => const Offset(0, -step),
      LogicalKeyboardKey.arrowDown => const Offset(0, step),
      _ => null,
    };
    if (by == null) return KeyEventResult.ignored;
    widget.onMove(by);
    // Handled, so the arrow key does not also move focus to the next handle —
    // which is what `WidgetsApp`'s own shortcuts would do with it.
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ring = widget.hinge ? 16.0 : 26.0;
    // Focused counts as active: a keyboard user needs to see which of the eight
    // marks the arrow keys are about, for the same reason a dragging finger
    // needs to see which one it caught.
    final lit = widget.active || _focused;
    const step = CalibrationHandle.nudgeStep;
    return Semantics(
      label: widget.hinge
          ? 'Hinge seam ${widget.index - 3} of 4'
          : 'Board corner ${widget.index + 1} of 4',
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        const CustomSemanticsAction(label: 'Nudge left'): () =>
            widget.onMove(const Offset(-step, 0)),
        const CustomSemanticsAction(label: 'Nudge right'): () =>
            widget.onMove(const Offset(step, 0)),
        const CustomSemanticsAction(label: 'Nudge up'): () =>
            widget.onMove(const Offset(0, -step)),
        const CustomSemanticsAction(label: 'Nudge down'): () =>
            widget.onMove(const Offset(0, step)),
      },
      child: Focus(
        focusNode: _focus,
        onFocusChange: (has) => setState(() => _focused = has),
        onKeyEvent: _onKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // A tap is how a handle becomes the one the arrow keys are about.
          onTap: _focus.requestFocus,
          onPanStart: (_) {
            _focus.requestFocus();
            widget.onStart();
          },
          onPanUpdate: (d) => widget.onMove(d.delta),
          onPanEnd: (_) => widget.onEnd(),
          onPanCancel: widget.onEnd,
          child: SizedBox(
            width: CalibrationHandle.touchSize,
            height: CalibrationHandle.touchSize,
            child: Center(
              child: Container(
                width: ring,
                height: ring,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(alpha: lit ? 0.35 : 0.15),
                  border: Border.all(
                    color: scheme.primary,
                    width: lit ? 3 : 2,
                  ),
                ),
                // The mark is a ring around a one-pixel dot rather than a
                // filled blob: what is being placed is a POINT, and a handle
                // that hides the corner it is on is the reason the first pass
                // at a real board landed on the rim.
                child: Center(
                  child: Container(
                    width: 3,
                    height: 3,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// The two overlays.
// -----------------------------------------------------------------------------

/// The outline the handles describe, and the columns it implies.
class BoardOutlinePainter extends CustomPainter {
  BoardOutlinePainter({
    required this.handles,
    required this.columns,
    required this.edge,
    required this.column,
  });

  final BoardHandles handles;

  /// The twenty-four point columns and the bar, as closed rings in normalized
  /// coordinates. Empty when the handles do not describe a board.
  final List<List<Offset>> columns;

  final Color edge;
  final Color column;

  @override
  void paint(Canvas canvas, Size size) {
    Offset at(Offset p) => Offset(p.dx * size.width, p.dy * size.height);

    final thin = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = column;
    for (final ring in columns) {
      final path = Path()..addPolygon(<Offset>[for (final p in ring) at(p)], true);
      canvas.drawPath(path, thin);
    }

    final thick = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = edge;
    canvas.drawPath(
      Path()..addPolygon(<Offset>[for (final p in handles.outer) at(p)], true),
      thick,
    );
    if (handles.isFolding) {
      canvas.drawPath(
        Path()..addPolygon(<Offset>[for (final p in handles.hinge) at(p)], true),
        thick,
      );
    }
  }

  @override
  bool shouldRepaint(BoardOutlinePainter old) =>
      old.edge != edge ||
      old.column != column ||
      !listEquals(old.handles.all, handles.all) ||
      !_sameRings(old.columns, columns);

  /// Deliberately deep, and both halves of it earn their keep.
  ///
  /// [columns] is re-derived on every build from the handles AND the
  /// orientation, and the seat step changes the orientation without moving a
  /// handle — so comparing the handles alone, or the ring COUNT (always 25 or
  /// always 0), would hold the old lines under a new seating. A hundred point
  /// comparisons is nothing next to drawing them.
  static bool _sameRings(List<List<Offset>> a, List<List<Offset>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!listEquals(a[i], b[i])) return false;
    }
    return true;
  }
}

/// The position Buddy believes it is looking at, drawn where it believes it is.
///
/// The check `confirmStartingPosition` runs is a colour check and says so in
/// its own documentation; what a person adds is everything a colour check
/// cannot see — a board read half a column across still holds the right colours
/// on most of its points, and looks obviously wrong the moment thirty men are
/// drawn on it.
class BeliefPainter extends CustomPainter {
  BeliefPainter({
    required this.calibration,
    required this.frame,
    required this.offending,
    required this.wrong,
  });

  final BoardCalibration calibration;

  /// The size of the picture [calibration]'s geometry maps into.
  final Size frame;

  /// The regions `confirmStartingPosition` disagreed about.
  final Set<RoiId> offending;

  final Color wrong;

  @override
  void paint(Canvas canvas, Size size) {
    final atlas = calibration.atlas;
    final start = BoardState.initial();
    final white = Paint()..color = const Color(0xFFF2F2F2);
    final black = Paint()..color = const Color(0xFF1A1A1A);
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x99000000);
    final flagged = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = wrong;

    Offset at(Pt board) {
      final p = calibration.geometry.imagePointOf(board);
      return Offset(p.x / frame.width * size.width,
          p.y / frame.height * size.height);
    }

    // The stack fit this board was calibrated with, which is the same
    // arithmetic occupancy counts backwards with: a stack of `k` reaches
    // `origin + k * pitch` from its own edge, so the k-th man's middle is half
    // a pitch inside that. Drawing through a nominal pitch instead would put
    // the men where a nominal board's men would be — right on any board that
    // happens to agree with it, and wrong on the one board this overlay is ever
    // laid over.
    //
    // Not clamped at the midline, deliberately: a stack drawn spilling into the
    // far half is a pitch that cannot be right, and this is the step where a
    // person is being asked to spot exactly that.
    final stacks = calibration.stacks;
    final fitted = stacks.pitch >= StackMetrics.minPitch &&
        stacks.pitch <= StackMetrics.maxPitch;
    final pitch = fitted ? stacks.pitch : _kNominalPitch;
    final origin = fitted ? stacks.origin : 0.0;

    for (var i = 0; i < 24; i++) {
      final men = start.points[i];
      if (men == 0) continue;
      final id = RoiId.point(i);
      final quad = atlas.roi(id);
      final left = quad.topLeft.x;
      final right = quad.topRight.x;
      final midX = (left + right) / 2;
      // Stacks grow inward from the board's own outer edge.
      final near = quad.topLeft.y >= RoiAtlas.midline;
      final count = men.abs();
      // One checker's radius on screen, from what a column measures there.
      final span = (at(Pt(right, near ? 1 : 0)) - at(Pt(left, near ? 1 : 0)))
          .distance;
      final radius = math.max(2.0, span / 2 * 0.82);
      for (var k = 0; k < count; k++) {
        final depth = origin + (k + 0.5) * pitch;
        final y = near ? 1 - depth : depth;
        final centre = at(Pt(midX, y));
        canvas.drawCircle(centre, radius, men > 0 ? white : black);
        canvas.drawCircle(centre, radius, rim);
      }
      if (offending.contains(id)) {
        canvas.drawPath(
          Path()
            ..addPolygon(<Offset>[for (final c in quad.corners) at(c)], true),
          flagged,
        );
      }
    }
  }

  @override
  bool shouldRepaint(BeliefPainter old) =>
      !identical(old.calibration, calibration) ||
      old.frame != frame ||
      old.wrong != wrong ||
      // Contents, not size. `confirmStartingPosition` re-runs on every settled
      // frame, and a board that moved one checker turns one flagged region into
      // a DIFFERENT one — same count, new sentence, and under a length
      // comparison the old red rings stay on the old points while the caption
      // names new ones.
      !setEquals(old.offending, offending);
}

/// The stack pitch to draw with when a calibration's own is not a usable one.
///
/// Half the board over five and a half checkers, which is what a nominal board
/// looks like. **Unreachable through `BoardVision.calibrate`**: the calibrator
/// refuses a calibration whose stack fit is not well conditioned, and a
/// well-conditioned fit is by construction one whose pitch came back inside
/// [StackMetrics.minPitch]..[StackMetrics.maxPitch]. It is here because
/// [BoardLearner] is a seam and [BeliefPainter] is a painter anyone can build.
const double _kNominalPitch = RoiAtlas.midline / 5.5;

// -----------------------------------------------------------------------------
// The plugin edge. Nothing below here runs in `flutter test`.
// -----------------------------------------------------------------------------

/// The real camera: one `CameraController` for the preview AND the frames.
///
/// Deliberately thin, and deliberately untested, exactly as
/// [CameraFrameSource] is: it opens a controller, hands its preview to the
/// screen and its images to the gate. Every decision above this line is
/// reachable from `flutter test`.
///
/// **One controller, and the format is checked twice on purpose.** Two
/// controllers on one camera is a platform error on both operating systems, so
/// the preview and the frame stream share this one — and a controller built
/// with any format but [kBuddyImageFormat] does not fail when the stream
/// starts, it fails once per frame, forever, inside a `catch` that only prints
/// in debug. [checkBuddyImageFormat] is called here, at the place the
/// controller is built, as well as inside `CameraFrameSource.start`.
class PhoneBuddyCamera implements BuddyCamera {
  final CameraFrameSource _source = CameraFrameSource();
  CameraController? _controller;

  /// How many screens are currently holding this camera open.
  ///
  /// **Two screens share it, and their lifetimes overlap in both directions.**
  /// The calibration flow hands over to the game screen (which opens before
  /// the popped route disposes), and the game screen pushes the calibration
  /// flow back for a recalibration (which closes as it pops, under a screen
  /// that is still playing a match). Without a count, whichever one disposes
  /// second takes the camera away from the one still using it, and the failure
  /// is a preview that goes black with no error anywhere. So [open] and [close]
  /// are balanced calls and only the last [close] tears anything down.
  int _users = 0;

  @override
  Stream<ObservedFrame> get frames => _source.frames;

  @override
  Future<CameraOpening> open() async {
    _users++;
    if (_controller != null) return const CameraReady();
    const noCamera = CameraUnavailable(
      'This device has no camera Buddy Mode can watch the board with. '
      'Everything else in the app works without one.',
    );
    final List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } catch (_) {
      // Broad on purpose: a desktop with no `camera` implementation raises a
      // MissingPluginException rather than a CameraException, and "there is no
      // camera here" is the same answer either way.
      return noCamera;
    }
    if (cameras.isEmpty) return noCamera;
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      back,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: kBuddyImageFormat,
    );
    // Outside the catch below, deliberately: a controller built with the wrong
    // format is a bug in THIS file, not a condition of the device, and it must
    // be loud rather than dressed up as "the camera could not be started".
    checkBuddyImageFormat(controller.imageFormatGroup);
    try {
      // This is where the operating system asks the user for the camera, which
      // is what makes the ask in-context: it happens on the screen that
      // explains why Buddy needs to look at the board.
      await controller.initialize();
      _controller = controller;
      await _source.start(controller);
      return const CameraReady();
    } on CameraException catch (error) {
      await controller.dispose();
      return CameraUnavailable(_reasonFor(error));
    }
  }

  static String _reasonFor(CameraException error) =>
      switch (error.code) {
        'CameraAccessDenied' ||
        'CameraAccessDeniedWithoutPrompt' ||
        'CameraAccessRestricted' =>
          'AIGammon does not have permission to use the camera. Allow camera '
              'access in your device settings and try again.',
        _ => 'The camera could not be started. ${error.description ?? ''}'.trim(),
      };

  /// The controller's own preview widget, handed over unwrapped.
  ///
  /// The caller stretches this to fill a box it sized from the FRAME's aspect
  /// ratio, which overrides the `AspectRatio` `CameraPreview` builds for
  /// itself. That is deliberate — a letterboxed preview and a full-bleed
  /// overlay would not be the same picture — and it is only correct while the
  /// displayed preview and the sensor frame agree about orientation and
  /// mirroring. See `_CalibrationScreenState._preview`, which states the
  /// assumption in full and names it as the first thing Task 15 verifies on a
  /// real phone.
  @override
  Widget preview(BuildContext context) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const ColoredBox(color: Color(0xFF000000));
    }
    return CameraPreview(controller);
  }

  /// Gives up one screen's hold. The last one out turns the camera off.
  @override
  Future<void> close() async {
    if (_users > 0) _users--;
    if (_users > 0) return;
    final controller = _controller;
    _controller = null;
    await _source.stop();
    await controller?.dispose();
  }

  /// Releases the gate as well — the provider's own teardown, not a screen's,
  /// so it ignores the count rather than waiting for a screen that has leaked.
  Future<void> shutDown() async {
    _users = 0;
    await close();
    await _source.dispose();
  }
}
