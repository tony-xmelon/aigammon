import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';

import '../../game/match_controller.dart';
import '../../tutor/move_assessment.dart';
import '../../tutor/tutor_service.dart';

/// Everything the live tutor keeps in step with the match: the per-move
/// assessments the score sheet marks its cells with, the pre-roll cube advice,
/// and the take/pass advice while a human faces a double.
///
/// Driven by [sync], called from the screen's change handler. Notifies exactly
/// where the screen used to call `setState` — when an assessment or an advice
/// lands — and calls [onSheetDirty] on top of that for the one change that also
/// moves a score-sheet cell.
///
/// Holds no widget and no [BuildContext]: an in-flight answer is fenced by
/// [dispose] and by its own generation/sequence guards, not by `mounted`.
class TutorSync extends ChangeNotifier {
  TutorSync({
    required this.controller,
    required this.tutor,
    required this.doublingLegal,
    required this.pendingCubeSide,
    required this.onSheetDirty,
  }) {
    seedAssessmentCursor();
  }

  final MatchController controller;

  /// Read live: the screen's widget (and with it the tutor) can be replaced.
  final TutorService? Function() tutor;

  /// Whether doubling is legal in a given state — the screen's own predicate,
  /// shared rather than duplicated so the advice and the Double button can never
  /// disagree about when the cube is on offer.
  final bool Function(GameState) doublingLegal;

  /// The locally-human side facing an opponent's double right now, or `null`.
  final Player? Function() pendingCubeSide;

  /// Called when an assessment lands, since that also changes a score-sheet
  /// cell (it gains its mark dot and equity loss).
  final VoidCallback onSheetDirty;

  bool _disposed = false;

  /// Count of game events observed at the last change, so a fresh MoveEvent can
  /// be detected (and a new game — a shorter event list — resets the tutor).
  int _lastEventCount = 0;

  /// The game state the log has reached after its first [_lastEventCount]
  /// events — the running prefix [_syncAssessment] carries forward instead of
  /// replaying the log from scratch for every move it assesses.
  GameState? _assessPrefix;

  /// The event object the assessed log STARTS with, so a log that was replaced
  /// rather than appended to is detected even when it is no shorter than the
  /// old one. `Game.append` carries the same event objects forward, so an
  /// identity check on the first event is exactly "still the same log".
  GameEvent? _assessLogRoot;

  /// Points the assessment cursor at the log as it stands NOW: nothing before
  /// this point will be assessed, and the running prefix is the state the whole
  /// of it has reached.
  ///
  /// The three fields are seeded together and never apart — a count without the
  /// state that belongs to it would fold later events onto the wrong position.
  /// (They were `late` initialisers once, and that is exactly what went wrong:
  /// each initialised on its own first read, at a different point in the log.)
  void seedAssessmentCursor() {
    final events = controller.game.events;
    _lastEventCount = events.length;
    _assessPrefix = controller.game.state;
    _assessLogRoot = events.isEmpty ? null : events.first;
  }

  /// Post-move assessments for EVERY move of the current game — both sides,
  /// human or not — keyed by the source [MoveEvent]'s index in the event log
  /// (the same index `ScoreCell.eventIndex` carries). Each entry enriches its
  /// cell in the score sheet with a mark dot + equity loss, which is why the
  /// opponent's moves are assessed too: the sheet's second column would
  /// otherwise be scoreless. Cleared when a new game begins.
  final Map<int, MoveAssessment> assessmentsByEventIndex = {};

  /// Event indices whose score-sheet cell has its best-move line revealed
  /// (tap-to-reveal). Cleared when a new game begins.
  final Set<int> revealedBest = {};

  /// Bumped when a new game starts, so an in-flight [TutorService.assess] from
  /// the previous game is discarded rather than written into a fresh log's map.
  int _gameGeneration = 0;

  /// Cube advice for the human's currently-open pre-roll gate, or `null`. Keyed
  /// by [_cubeAdviceKey] so it is computed once per gate, not per rebuild.
  CubeAssessment? get cubeAdvice => _cubeAdvice;
  CubeAssessment? _cubeAdvice;
  int? _cubeAdviceKey;
  int _cubeAdviceSeq = 0;

  /// Take/pass advice for a human facing an opponent's double, or `null`. Keyed
  /// by [_cubeResponseKey] so it is computed once per offer.
  CubeAssessment? get cubeResponseAdvice => _cubeResponseAdvice;
  CubeAssessment? _cubeResponseAdvice;
  int? _cubeResponseKey;
  int _cubeResponseSeq = 0;

  /// Reacts to controller changes when tutor mode is on: fires a post-move
  /// assessment for every newly-landed move, keeps the pre-roll cube advice in
  /// sync with the open gate, and clears everything on game end / a new game.
  void sync() {
    if (tutor() == null) return;
    _syncAssessment();
    _syncCubeAdvice();
    _syncCubeResponse();
  }

  /// Detects new [MoveEvent]s in the current game's event log and kicks off an
  /// async assessment for EACH of them, stored under the move's event index
  /// (see [assessmentsByEventIndex]). A shorter event list means a new game
  /// began: reset and clear the accumulated assessments.
  ///
  /// Deliberately NOT gated on [MatchController.isLocalHuman]: the score sheet
  /// scores both columns, so the AI's / the remote player's / the other hot-seat
  /// side's moves are assessed on exactly the same terms as your own. The extra
  /// cost is one 0-ply `rankMoves` per opponent turn — the same call the tutor
  /// already makes for your own move, on the same engine isolate.
  void _syncAssessment() {
    final events = controller.game.events;
    final len = events.length;
    final root = events.isEmpty ? null : events.first;

    if (len < _lastEventCount || !identical(root, _assessLogRoot)) {
      // A new game started (the event log reset). Discard the old game's
      // assessments and abandon any in-flight ones, and re-seed the cursor on
      // the new log.
      seedAssessmentCursor();
      assessmentsByEventIndex.clear();
      revealedBest.clear();
      _gameGeneration++;
      return;
    }
    if (len == _lastEventCount) return;

    // One or more events appended since last time: assess every move among
    // them. In practice the loop notifies per-append, so this is usually one.
    //
    // The state each move was played FROM is the running prefix, carried one
    // event at a time. It used to be `Game.replay(events.sublist(0, i))` — a
    // fold of the whole log, per move, which makes reviewing a game of n moves
    // cost O(n²) folds (and n list copies) for information one forward pass
    // already has. `Game.applyEvent` is the single step `replay` is built from,
    // so the state handed to the tutor is the same state, event for event.
    var before = _assessPrefix!;
    for (var i = _lastEventCount; i < len; i++) {
      final event = events[i];
      if (event is MoveEvent) _fireAssessment(i, before, event.move);
      before = Game.applyEvent(before, event);
    }
    _assessPrefix = before;
    _lastEventCount = len;
  }

  /// Assesses the [played] move (whose event sits at [eventIndex]) and, on
  /// resolution, files it under that index — unless the game has since reset
  /// (a [_gameGeneration] mismatch) or this object was disposed.
  void _fireAssessment(int eventIndex, GameState before, Move played) {
    final gen = _gameGeneration;
    unawaited(tutor()!.assessOrNull(before, played).then((assessment) {
      if (_disposed || gen != _gameGeneration) return;
      // Null = the engine could not answer (already recorded by the tutor).
      // The cell stays unmarked rather than claiming a verdict.
      if (assessment == null) return;
      assessmentsByEventIndex[eventIndex] = assessment;
      notifyListeners();
      onSheetDirty(); // a cell gained its mark dot and equity loss
    }));
  }

  /// Recomputes the pre-roll cube advice exactly when a human's turn gate is
  /// open and doubling is legal; clears it otherwise. Keyed by the event count
  /// so it is computed once per gate.
  void _syncCubeAdvice() {
    final s = controller.state;
    final showAdvice = controller.awaitingHumanTurn && doublingLegal(s);
    if (!showAdvice) {
      _cubeAdvice = null;
      _cubeAdviceKey = null;
      return;
    }
    final key = controller.game.events.length;
    if (_cubeAdviceKey == key) return; // already computed for this gate
    _cubeAdviceKey = key;
    final seq = ++_cubeAdviceSeq;
    _cubeAdvice = null;
    unawaited(tutor()!
        .assessCubeOrNull(s, controller.contextFor(s.turn), playerDoubled: false)
        .then((advice) {
      // A null advice leaves the row absent, which is what it already looks
      // like before the answer lands — no error over the board.
      if (_disposed || seq != _cubeAdviceSeq || advice == null) return;
      _cubeAdvice = advice;
      notifyListeners();
    }));
  }

  /// Recomputes the take/pass advice while a human faces an opponent's double
  /// (a pending cube request); clears it otherwise. Keyed by the event count.
  void _syncCubeResponse() {
    final cubeSide = pendingCubeSide();
    if (cubeSide == null) {
      _cubeResponseAdvice = null;
      _cubeResponseKey = null;
      return;
    }
    final key = controller.game.events.length;
    if (_cubeResponseKey == key) return;
    _cubeResponseKey = key;
    final seq = ++_cubeResponseSeq;
    _cubeResponseAdvice = null;
    final state = controller.pendingCubeOf(cubeSide).value!;
    unawaited(tutor()!
        .assessCubeResponseOrNull(state, controller.contextFor(state.turn))
        .then((advice) {
      if (_disposed || seq != _cubeResponseSeq || advice == null) return;
      _cubeResponseAdvice = advice;
      notifyListeners();
    }));
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
