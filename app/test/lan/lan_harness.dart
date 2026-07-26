import 'package:aigammon_app/data/persistence_hooks.dart';
import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/lan/lan_match_controller.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:lan_play/lan_play.dart';

/// The room code the socket tests use.
const String testRoomCode = '4271';

/// A [MatchPersistence] that records every hook call, so a test can assert
/// onGameFinished fired ONCE per finished game (with the full event log and the
/// folded result) and onMatchFinished at match end.
class RecordingPersistence implements MatchPersistence {
  final List<
      ({
        int gameNumber,
        bool isCrawford,
        List<GameEvent> events,
        GameResult result,
        MatchState matchAfter,
      })> games = [];
  int matchFinishedCalls = 0;
  MatchState? finalState;

  @override
  Future<void> onGameFinished({
    required int gameNumber,
    required bool isCrawford,
    required List<GameEvent> events,
    required GameResult result,
    required MatchState matchAfter,
  }) async {
    games.add((
      gameNumber: gameNumber,
      isCrawford: isCrawford,
      events: events,
      result: result,
      matchAfter: matchAfter,
    ));
  }

  @override
  Future<void> onMatchFinished(MatchState finalState) async {
    matchFinishedCalls++;
    this.finalState = finalState;
  }
}

/// Poll until [condition] holds, or fail loudly. Sockets and timers make the
/// exact instant unpredictable, so every asynchronous assertion goes through
/// here rather than through a fixed sleep.
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String what = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// A fresh authority with deterministic dice and a token a test can predict.
HostAuthority newAuthority({
  int length = 1,
  bool cubeless = false,
  Player hostSide = Player.white,
  List<Dice> dice = const [],
}) =>
    HostAuthority(
      config: MatchConfig(length: length, cubeless: cubeless),
      hostSide: hostSide,
      dice: ScriptedDiceRoller(dice),
      resumeToken: 'TESTTOKEN',
    );

/// Start the match the way a joining guest does.
void guestHello(HostAuthority authority, {String name = 'Bo'}) =>
    authority.onGuestMessage(HelloMessage(name: name));

/// Act for whichever side is on turn STRAIGHT INTO [authority] — the headless
/// opponent the host-side tests play against, and the engine behind
/// [authorityLog].
///
/// [side] names the seat to act for; the caller is responsible for it being that
/// seat's turn. Guest actions travel the guest inbox (so they take the real
/// validation path), host actions the local verbs.
void actInAuthority(
  HostAuthority authority,
  Player side, {
  CubeAction cubeResponse = CubeAction.take,
  bool acceptResign = true,
}) {
  final state = authority.state!;
  final isHost = side == authority.hostSide;
  void deliver(GameEvent event) {
    if (isHost) {
      authority.localSubmit(event);
    } else {
      authority.onGuestMessage(SubmitMessage(event));
    }
  }

  switch (state.phase) {
    case GamePhase.awaitingRoll:
      if (isHost) {
        authority.localRoll();
      } else {
        authority.onGuestMessage(const RollRequestMessage());
      }
    case GamePhase.moving:
      final legal = state.legalMoves;
      deliver(MoveEvent(side, legal.isEmpty ? Move.none : legal.first));
    case GamePhase.cubeOffered:
      deliver(cubeResponse == CubeAction.take ? TakeEvent(side) : DropEvent(side));
    case GamePhase.resignOffered:
      deliver(acceptResign ? ResignAcceptEvent(side) : ResignDeclineEvent(side));
    case GamePhase.gameOver:
      throw StateError('nothing to do in the gameOver phase');
  }
}

/// Play a whole match head-on inside one [HostAuthority] (no controller, no
/// transport) and return its authoritative log — the fixture the fold tests
/// replay. Stops early once the log reaches [maxEntries] entries.
List<LogEntry> authorityLog({
  int length = 1,
  Player hostSide = Player.white,
  int maxEntries = 1 << 30,
}) {
  final authority = newAuthority(length: length, hostSide: hostSide);
  guestHello(authority);
  var guard = 0;
  while (!authority.matchOver && authority.log.length < maxEntries) {
    if (guard++ > 20000) {
      throw StateError('authority playout did not terminate');
    }
    actInAuthority(authority, authority.state!.turn);
  }
  final log = authority.log;
  authority.close();
  return log.length <= maxEntries ? log : log.sublist(0, maxEntries);
}

/// Act for [controller]'s own side, whatever the phase asks for. Mirrors what
/// the game screen's controls would do.
void actInController(
  LanMatchController controller, {
  CubeAction cubeResponse = CubeAction.take,
  bool acceptResign = true,
}) {
  final side = controller.localSide;
  final state = controller.state;
  switch (state.phase) {
    case GamePhase.awaitingRoll:
      controller.rollDice();
    case GamePhase.moving:
      final legal = state.legalMoves;
      controller.submitMove(side, legal.isEmpty ? Move.none : legal.first);
    case GamePhase.cubeOffered:
      controller.submitCubeResponse(side, cubeResponse);
    case GamePhase.resignOffered:
      controller.submitResignResponse(side, acceptResign);
    case GamePhase.gameOver:
      throw StateError('nothing to do in the gameOver phase');
  }
}
