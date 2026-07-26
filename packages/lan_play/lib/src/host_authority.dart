import 'dart:async';
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';

import 'dice_roller.dart';
import 'protocol.dart';

/// Who an outbound message is for.
enum HostDestination {
  /// The remote guest only (welcome, a reject aimed at the guest).
  guest,

  /// The host's own UI only (a reject aimed at a local action).
  local,

  /// Everyone — every authoritative log entry.
  both,
}

/// One targeted message the transport must deliver.
class HostOutbound {
  const HostOutbound(this.to, this.message);

  final HostDestination to;
  final Envelope message;

  bool get toGuest =>
      to == HostDestination.guest || to == HostDestination.both;
  bool get toLocal =>
      to == HostDestination.local || to == HostDestination.both;

  @override
  String toString() => 'HostOutbound(${to.name}, ${message.type})';
}

/// The host device's authoritative referee: it owns the [MatchState], the
/// current [Game] and the append-only seq log, generates every die, and
/// validates every submission — its own player's included.
///
/// Transport-agnostic on purpose: feed it decoded [Envelope]s ([onGuestMessage])
/// or raw frames ([onGuestRaw]) and deliver whatever comes out of [outbound].
/// That makes the whole authority unit-testable in memory, and lets the host's
/// own UI ride the same event stream as the guest (Task 3).
///
/// ## Relationship to the online server (firebase/functions/src/turnflow.ts)
///
/// The rules mirrored are the same — actor must be the side on `turn`, phase
/// gates per event type, terminal events fold into scores, Crawford bookkeeping,
/// next game auto-started with a fresh opening roll — with two deliberate
/// STRENGTHENINGS, both affordable here because the host runs the real rules
/// engine while the Cloud Function is boardless:
///
///  1. **Move legality is fully validated.** A submitted [MoveEvent] must be a
///     member of `legalMoves` (order-insensitively, [Move.sameAs]) or a
///     position-equivalent decomposition of one — exactly the set
///     `GameState.play` accepts. The server v1 accepts any well-shaped move and
///     relies on client divergence to detect cheating.
///  2. **Terminal results are computed, never claimed.** There is no `result`
///     claim on the wire at all: the winner, the points and the outcome come out
///     of `GameState.result` after the event is applied, so a guest cannot
///     invent a score. The server v1 trusts a validated client claim.
///
/// Everything the core already polices (cube ownership, no doubling in the
/// Crawford game, resign values, phase transitions) is enforced by letting the
/// core reject it: every submission is applied through [Game.append] inside a
/// guard that turns ANY failure into a [RejectMessage] carrying the full log to
/// resync from.
class HostAuthority {
  HostAuthority({
    required this.config,
    this.hostSide = Player.white,
    DiceRoller? dice,
    String? resumeToken,
    Random? tokenRandom,
  })  : _dice = dice ?? RandomDiceRoller(),
        _match = MatchState(matchLength: config.length),
        resumeToken = resumeToken ?? _mintToken(tokenRandom);

  /// The match parameters this host fixed; the guest adopts them.
  final MatchConfig config;

  /// The side the host device plays. The guest gets the other one.
  final Player hostSide;

  /// The token a guest presents in a later `hello` to resume this session.
  final String resumeToken;

  final DiceRoller _dice;

  final _out = StreamController<HostOutbound>.broadcast();
  final List<LogEntry> _log = [];

  MatchState _match;
  Game? _game;
  int _gameNo = 0;
  int _seq = 0;
  bool _started = false;
  bool _closed = false;

  /// Targeted messages to deliver. Broadcast: the transport and the host's own
  /// controller can both listen.
  Stream<HostOutbound> get outbound => _out.stream;

  /// The side the guest plays.
  Player get guestSide => hostSide.opponent;

  /// The running match score.
  MatchState get match => _match;

  /// The current game, or null before the first `hello`.
  Game? get game => _game;

  /// The current game's derived state, or null before the first `hello`.
  GameState? get state => _game?.state;

  /// 1-based game number within the match; 0 before the match starts.
  int get gameNumber => _gameNo;

  /// The last assigned sequence number; 0 before the first event.
  int get lastSeq => _seq;

  /// The authoritative log, oldest first.
  List<LogEntry> get log => List.unmodifiable(_log);

  /// True once a guest has said hello and game 1 has begun.
  bool get started => _started;

  /// True once the match has been decided.
  bool get matchOver => _match.isMatchOver;

  // --- inbound ---------------------------------------------------------------

  /// Handle a raw frame from the guest. Undecodable frames never reach the
  /// game logic:
  ///  * an unknown TYPE is ignored (a newer peer may send frames we predate);
  ///  * anything else is refused with a [RejectMessage] carrying NO log —
  ///    a protocol error is a peer bug, not a divergence, and replying with the
  ///    whole log would let a 20-byte hostile frame pull a hundreds-of-KB
  ///    answer out of the host (amplification).
  void onGuestRaw(String raw) {
    if (_closed) return;
    switch (Envelope.decode(raw)) {
      case DecodeOk(:final envelope):
        onGuestMessage(envelope);
      case DecodeFailure(:final error):
        if (error.kind == ProtocolErrorKind.unknownType) return;
        _emit(HostDestination.guest, RejectMessage(reason: error.message));
    }
  }

  /// Handle a decoded frame from the guest.
  void onGuestMessage(Envelope message) {
    if (_closed) return;
    switch (message) {
      case HelloMessage():
        _hello();
      case RollRequestMessage():
        _rollFor(guestSide);
      case SubmitMessage(:final event):
        _submit(guestSide, event);
      case PingMessage():
        _emit(HostDestination.guest, const PongMessage());
      case PongMessage():
        break; // liveness only; the transport tracks it
      // Host-authored frames are not accepted FROM a guest: a guest that sends
      // one is either buggy or probing, and must never move the authority.
      case WelcomeMessage():
      case EventMessage():
      case RejectMessage():
      case BusyMessage():
        _emit(HostDestination.guest,
            RejectMessage(reason: 'host-only message type: ${message.type}'));
    }
  }

  // --- local (host player) actions -------------------------------------------
  //
  // The host's own decisions take EXACTLY the path a guest submission takes:
  // same turn/phase checks, same legality check, same append, same broadcast.
  // Only the destination of a rejection differs.

  /// The host player asks for their dice.
  void localRoll() => _rollFor(hostSide);

  /// The host player submits an event for their own side.
  void localSubmit(GameEvent event) => _submit(hostSide, event);

  void localMove(Move move) => localSubmit(MoveEvent(hostSide, move));
  void localOfferDouble() => localSubmit(DoubleEvent(hostSide));
  void localTake() => localSubmit(TakeEvent(hostSide));
  void localDrop() => localSubmit(DropEvent(hostSide));
  void localOfferResign(ResignValue value) =>
      localSubmit(ResignOfferEvent(hostSide, value));
  void localAcceptResign() => localSubmit(ResignAcceptEvent(hostSide));
  void localDeclineResign() => localSubmit(ResignDeclineEvent(hostSide));

  /// Releases the outbound stream. Idempotent.
  void close() {
    if (_closed) return;
    _closed = true;
    _out.close();
  }

  // --- handshake -------------------------------------------------------------

  void _hello() {
    // A hello is always answered with the authoritative log — that covers a
    // first join (empty log), a resume (full log) and a plain resync alike, so
    // no token check is needed to stay correct. The transport (Task 2) uses the
    // token for its single-guest / re-join policy.
    _emit(
      HostDestination.guest,
      WelcomeMessage(
        config: config,
        side: guestSide,
        resume: resumeToken,
        log: log,
      ),
    );
    if (!_started) {
      _started = true;
      _startGame();
    }
  }

  // --- the one validation path -----------------------------------------------

  /// Event types a PLAYER may submit. Dice (`openingRoll`, `roll`) are the
  /// host's alone — a guest asks with `roll_request`.
  static bool _isSubmittable(GameEvent e) =>
      e is! OpeningRollEvent && e is! RollEvent;

  static Player? _actorOf(GameEvent e) => switch (e) {
        OpeningRollEvent() => null,
        RollEvent(:final player) => player,
        MoveEvent(:final player) => player,
        DoubleEvent(:final player) => player,
        TakeEvent(:final player) => player,
        DropEvent(:final player) => player,
        ResignOfferEvent(:final player) => player,
        ResignAcceptEvent(:final player) => player,
        ResignDeclineEvent(:final player) => player,
      };

  void _rollFor(Player side) {
    final game = _guard(side);
    if (game == null) return;
    if (game.state.phase != GamePhase.awaitingRoll) {
      _reject(side, 'not awaiting a roll (phase ${game.state.phase.name})');
      return;
    }
    final d = _dice.roll();
    _applyAndAppend(side, RollEvent(side, d.die1, d.die2));
  }

  void _submit(Player side, GameEvent event) {
    final game = _guard(side);
    if (game == null) return;
    if (!_isSubmittable(event)) {
      _reject(side, 'dice are host-authoritative: cannot submit a roll');
      return;
    }
    final actor = _actorOf(event);
    if (actor != side) {
      // Never silently rewrite the player field — reject, so a mismatch is
      // visible rather than laundered (mirrors submitEvent in index.ts).
      _reject(side, 'event.player (${actor?.name}) is not your side '
          '(${side.name})');
      return;
    }
    if (config.cubeless && event is DoubleEvent) {
      _reject(side, 'this match is played without the cube');
      return;
    }
    if (event is MoveEvent && !_isLegalMove(game.state, event.move)) {
      _reject(side, 'illegal move: ${event.move}');
      return;
    }
    _applyAndAppend(side, event);
  }

  /// Shared precondition gate: the match is live and it is [side]'s turn.
  /// Returns the current game, or null after emitting the rejection.
  Game? _guard(Player side) {
    final game = _game;
    if (!_started || game == null) {
      _reject(side, 'the match has not started');
      return null;
    }
    if (matchOver) {
      _reject(side, 'the match is over');
      return null;
    }
    if (game.state.turn != side) {
      // Covers out-of-turn play AND a stale resubmission: once an event lands,
      // the turn has moved on, so replaying it lands here.
      _reject(side, 'not your turn (turn is ${game.state.turn.name}, '
          'you are ${side.name})');
      return null;
    }
    return game;
  }

  /// Full legality: the submitted move must be a legal move up to hop ORDER
  /// ([Move.sameAs]), or — when the generator deduped an equivalent
  /// decomposition away — reach the same position as one. That is precisely the
  /// set `GameState.play` applies, checked here first so the rejection carries a
  /// clear reason instead of a state-machine message.
  bool _isLegalMove(GameState state, Move move) {
    if (state.phase != GamePhase.moving) return true; // phase check is _apply's
    final legal = state.legalMoves;
    if (legal.isEmpty) return move.checkerMoves.isEmpty;
    if (legal.any((m) => m.sameAs(move))) return true;
    if (move.checkerMoves.length != legal.first.checkerMoves.length) {
      return false;
    }
    // A decomposition the generator collapsed: legal iff it lands on the same
    // position as some legal move. Bounds-check first so applyMove cannot be
    // handed an out-of-range index by a hostile peer.
    for (final cm in move.checkerMoves) {
      final fromOk =
          cm.from == CheckerMove.bar || (cm.from >= 0 && cm.from < 24);
      final toOk = cm.to == CheckerMove.off || (cm.to >= 0 && cm.to < 24);
      if (!fromOk || !toOk) return false;
    }
    try {
      final resulting = state.board.applyMove(state.turn, move);
      return legal.any((m) => state.board.applyMove(state.turn, m) == resulting);
    } catch (_) {
      return false;
    }
  }

  /// Apply through the core (the final arbiter), append, broadcast, and fold a
  /// terminal state into the match. ANY failure — a state-machine rejection or
  /// an unexpected error from hostile input — becomes a reject, never a throw.
  void _applyAndAppend(Player side, GameEvent event) {
    final Game next;
    try {
      next = _game!.append(event);
    } on StateError catch (e) {
      _reject(side, e.message);
      return;
    } catch (e) {
      _reject(side, 'rejected: $e');
      return;
    }
    _game = next;
    _record(event);

    final result = next.state.result;
    if (next.state.phase != GamePhase.gameOver || result == null) return;

    // Terminal: the result is COMPUTED by the engine, never claimed by a peer.
    _match = _match.applyResult(result);
    if (!_match.isMatchOver) _startGame();
  }

  // --- log + emission --------------------------------------------------------

  void _startGame() {
    final d = _dice.rollOpening();
    _gameNo += 1;
    final opening = OpeningRollEvent(whiteDie: d.die1, blackDie: d.die2);
    // Crawford is decided from the score BEFORE this game is played, exactly as
    // MatchState.isCrawfordNext defines it.
    _game = Game.start(opening, isCrawfordGame: _match.isCrawfordNext);
    _record(opening);
  }

  void _record(GameEvent event) {
    _seq += 1;
    final entry = LogEntry(seq: _seq, gameNo: _gameNo, event: event);
    _log.add(entry);
    _emit(HostDestination.both, EventMessage(entry));
  }

  void _reject(Player side, String reason) => _emit(
        side == hostSide ? HostDestination.local : HostDestination.guest,
        RejectMessage(reason: reason, log: log),
      );

  void _emit(HostDestination to, Envelope message) {
    if (_closed) return;
    _out.add(HostOutbound(to, message));
  }

  static const _tokenAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  static String _mintToken(Random? rng) {
    final r = rng ?? Random.secure();
    return [
      for (var i = 0; i < 12; i++) _tokenAlphabet[r.nextInt(_tokenAlphabet.length)],
    ].join();
  }
}
