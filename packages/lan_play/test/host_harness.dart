import 'package:backgammon_core/backgammon_core.dart';
import 'package:lan_play/lan_play.dart';

/// Test rig around a [HostAuthority]: records everything the authority emits
/// and pumps the event loop after each interaction, so tests read as a script.
class HostHarness {
  HostHarness({
    int length = 3,
    bool cubeless = false,
    Player hostSide = Player.white,
    List<Dice> dice = const [],
    DiceRoller? roller,
  }) : host = HostAuthority(
          config: MatchConfig(length: length, cubeless: cubeless),
          hostSide: hostSide,
          dice: roller ?? ScriptedDiceRoller(dice),
          resumeToken: 'TESTTOKEN',
        ) {
    host.outbound.listen(sent.add);
  }

  final HostAuthority host;

  /// Everything emitted, oldest first.
  final List<HostOutbound> sent = [];

  Player get hostSide => host.hostSide;
  Player get guestSide => host.guestSide;
  GameState get state => host.state!;

  /// Flush the outbound stream's microtask delivery.
  Future<void> pump() => Future<void>.delayed(Duration.zero);

  Future<void> hello({String name = 'guest', String? resume}) =>
      _send(HelloMessage(name: name, resume: resume));

  Future<void> guestRollRequest() => _send(const RollRequestMessage());

  Future<void> guestSubmit(GameEvent e) => _send(SubmitMessage(e));

  Future<void> _send(Envelope m) async {
    host.onGuestMessage(m);
    await pump();
  }

  Future<void> guestRaw(String raw) async {
    host.onGuestRaw(raw);
    await pump();
  }

  Future<void> localRoll() async {
    host.localRoll();
    await pump();
  }

  Future<void> localSubmit(GameEvent e) async {
    host.localSubmit(e);
    await pump();
  }

  /// Roll for whoever is on turn, through that side's own entry point.
  Future<void> rollForTurn() =>
      state.turn == hostSide ? localRoll() : guestRollRequest();

  /// Submit [event] through the entry point of the side that owns it.
  Future<void> submitAsTurn(GameEvent Function(Player side) build) {
    final side = state.turn;
    final event = build(side);
    return side == hostSide ? localSubmit(event) : guestSubmit(event);
  }

  // --- assertions helpers ---------------------------------------------------

  /// Messages emitted since [mark], clearing nothing.
  List<HostOutbound> since(int mark) => sent.sublist(mark);

  int get mark => sent.length;

  List<RejectMessage> rejectsSince(int mark) => [
        for (final o in since(mark))
          if (o.message is RejectMessage) o.message as RejectMessage,
      ];

  RejectMessage rejectSince(int mark) {
    final r = rejectsSince(mark);
    if (r.length != 1) {
      throw StateError('expected exactly one reject, got ${since(mark)}');
    }
    return r.single;
  }

  HostDestination destinationOfLast() => sent.last.to;

  List<EventMessage> eventsSince(int mark) => [
        for (final o in since(mark))
          if (o.message is EventMessage) o.message as EventMessage,
      ];

  void dispose() => host.close();
}
