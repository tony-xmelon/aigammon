import 'dart:async';
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:online_client/online_client.dart';

/// An in-memory stand-in for the WHOLE serverless backend: match documents,
/// their event logs and their commit-reveal roll documents.
///
/// The point of modelling the store rather than the API surface is that two
/// [FakeMatchApi] views (one per uid) can share it, so a test can run two real
/// [OnlineMatchController]s against each other exactly as two devices would —
/// including the roll protocol, which needs both peers to write to the same
/// document.
///
/// It deliberately enforces NOTHING that `firebase/firestore.rules` enforces
/// except document-id uniqueness (the [AlreadyExistsException] the controller
/// has to survive) and the write-once roll phases. Rules coverage lives in
/// `firebase/`; what the app must survive is a peer that gets past them, which
/// is why [forgeEvent] and [putRoll] exist.
class FakeBackend {
  final Map<String, FakeMatch> matches = {};
  final _changes = StreamController<String>.broadcast();

  /// Fires the code of every match whose documents changed.
  Stream<String> get changes => _changes.stream;

  void bump(String code) {
    if (!_changes.isClosed) _changes.add(code);
  }

  Future<void> close() => _changes.close();

  FakeMatch require(String code) {
    final m = matches[code];
    if (m == null) throw NotFoundException('no match with code $code');
    return m;
  }

  /// Creates an already-joined match, the state both peers start play from.
  FakeMatch seedMatch({
    String code = 'MATCH001',
    String hostUid = 'host',
    String guestUid = 'guest',
    int length = 3,
    bool cubeless = false,
  }) {
    final m = FakeMatch(
      code: code,
      hostUid: hostUid,
      guestUid: guestUid,
      length: length,
      cubeless: cubeless,
      status: 'active',
    );
    matches[code] = m;
    return m;
  }
}

/// One match document plus its two subcollections.
class FakeMatch {
  FakeMatch({
    required this.code,
    required this.hostUid,
    this.guestUid,
    required this.length,
    required this.cubeless,
    required this.status,
  });

  final String code;
  final String hostUid;
  String? guestUid;
  final int length;
  final bool cubeless;
  String status;

  final List<RemoteEvent> events = [];
  final Map<int, FakeRoll> rolls = {};

  MatchDoc get doc => MatchDoc(
        code: code,
        hostUid: hostUid,
        guestUid: guestUid,
        length: length,
        cubeless: cubeless,
        status: status,
      );

  int get nextSeq => events.isEmpty ? 0 : events.last.seq + 1;

  /// Roll-bearing events so far — the same count the controller keeps, and
  /// therefore the index of the roll that is next to be made minus one.
  int get rollCount => events
      .where((e) => e.event is OpeningRollEvent || e.event is RollEvent)
      .length;

  /// Append an event with NO validation whatsoever — the forgery hook. Real
  /// peers go through [FakeMatchApi.submitEvent]; a test uses this to write what
  /// a hacked client would write.
  RemoteEvent forgeEvent(String author, int gameNo, GameEvent event, {int? seq}) {
    final re = RemoteEvent(
      seq: seq ?? nextSeq,
      gameNo: gameNo,
      event: event,
      author: author,
    );
    events.add(re);
    return re;
  }

  /// Write a roll document wholesale, at any phase and with any values — the
  /// other forgery hook (a tampered reveal, a roll nobody witnessed).
  FakeRoll putRoll(
    int n,
    String roller,
    String commit, {
    String? entropy,
    String? reveal,
  }) {
    final r = FakeRoll(n: n, roller: roller, commit: commit)
      ..entropy = entropy
      ..reveal = reveal;
    rolls[n] = r;
    return r;
  }
}

/// A mutable `matches/{code}/rolls/{n}` document.
class FakeRoll {
  FakeRoll({required this.n, required this.roller, required this.commit});

  final int n;
  final String roller;
  final String commit;
  String? entropy;
  String? reveal;

  RollDoc get doc => RollDoc(
      n: n, roller: roller, commit: commit, entropy: entropy, reveal: reveal);
}

/// One signed-in user's view of a [FakeBackend] — the seam
/// [OnlineMatchController] and the online screens consume.
///
/// [intercept] is the fault-injection hook: return (or throw) an object for a
/// named operation and that call fails with it. Operation names are the method
/// names (`submitEvent`, `createRoll`, `submitEntropy`, `submitReveal`,
/// `fetchEventsSince`, …).
class FakeMatchApi implements MatchApi {
  FakeMatchApi(this.backend, this.uid);

  final FakeBackend backend;

  @override
  final String uid;

  /// Called before every operation; a non-null return is thrown instead.
  Object? Function(String op)? intercept;

  /// Per-operation call counts, for assertions.
  final Map<String, int> calls = {};

  /// Codes passed to [joinMatch], in order.
  final List<String> joinCodes = [];

  /// Every event this view appended, in order.
  final List<GameEvent> submitted = [];

  /// Invite codes handed out by [createMatch].
  String nextCode = 'MATCH001';

  /// After this many [fetchMatch] calls, an invisible opponent takes the guest
  /// seat — the create screen's "waiting → active" transition without a second
  /// live client. Negative disables it.
  int autoJoinAfterFetches = -1;
  String autoJoinUid = 'guest';

  /// How fast the poll re-reads the store, INDEPENDENTLY of the `interval` the
  /// caller asks for (which only paces the real transport).
  ///
  /// [Duration.zero] — one beat per event-loop turn — is what plain `test()`
  /// cases want. WIDGET tests must set it to `null`: their clock is fake, so a
  /// zero-duration self-rescheduling timer is always due and would spin forever
  /// inside a single `pump`. With no beat the poll is purely change-driven,
  /// which is enough whenever the controller subscribes before the writes it has
  /// to see (every widget test here does).
  Duration? pollBeat = Duration.zero;

  /// Seed a sound opening roll the first time a match goes active, standing in
  /// for the host client that no widget test has running.
  bool autoSeedOpening = false;
  int openingWhiteDie = 6;
  int openingBlackDie = 3;

  void _maybeSeedOpening(FakeMatch m) {
    if (!autoSeedOpening || m.events.isNotEmpty || m.guestUid == null) return;
    seedOpening(m, whiteDie: openingWhiteDie, blackDie: openingBlackDie);
  }

  /// Live [pollMatch] controllers, so a test can push a transport blip into the
  /// poll stream the way a real fetch failure would arrive.
  final List<StreamController<MatchPoll>> _polls = [];

  void emitPollError(Object error) {
    for (final c in _polls) {
      if (!c.isClosed) c.addError(error);
    }
  }

  void _tick(String op) {
    calls[op] = (calls[op] ?? 0) + 1;
    final failure = intercept?.call(op);
    if (failure != null) throw failure;
  }

  // --- matches ---------------------------------------------------------------

  @override
  Future<MatchDoc> createMatch({
    required int length,
    required bool cubeless,
    int attempts = 5,
  }) async {
    _tick('createMatch');
    final m = FakeMatch(
      code: nextCode,
      hostUid: uid,
      length: length,
      cubeless: cubeless,
      status: 'waiting',
    );
    backend.matches[m.code] = m;
    backend.bump(m.code);
    return m.doc;
  }

  @override
  Future<MatchDoc> fetchMatch(String code) async {
    _tick('fetchMatch');
    final m = backend.require(code);
    if (autoJoinAfterFetches >= 0 &&
        calls['fetchMatch']! >= autoJoinAfterFetches &&
        m.guestUid == null) {
      m.guestUid = autoJoinUid;
      m.status = 'active';
      _maybeSeedOpening(m);
      backend.bump(code);
    }
    return m.doc;
  }

  @override
  Future<MatchDoc> joinMatch(String code) async {
    _tick('joinMatch');
    joinCodes.add(code);
    final m = backend.require(code);
    if (m.hostUid == uid) {
      throw const FailedPreconditionException('you cannot join your own match');
    }
    if (m.status != 'waiting' || m.guestUid != null) {
      throw FailedPreconditionException('match $code is not open to join');
    }
    m.guestUid = uid;
    m.status = 'active';
    _maybeSeedOpening(m);
    backend.bump(code);
    return m.doc;
  }

  @override
  Future<void> completeMatch(String code) async {
    _tick('completeMatch');
    backend.require(code).status = 'complete';
    backend.bump(code);
  }

  // --- events ----------------------------------------------------------------

  @override
  Future<void> submitEvent({
    required String code,
    required int seq,
    required int gameNo,
    required GameEvent event,
  }) async {
    _tick('submitEvent');
    final m = backend.require(code);
    if (m.events.any((e) => e.seq == seq)) {
      throw AlreadyExistsException('events/$seq already exists');
    }
    m.events.add(
        RemoteEvent(seq: seq, gameNo: gameNo, event: event, author: uid));
    submitted.add(event);
    backend.bump(code);
  }

  @override
  Future<List<RemoteEvent>> fetchEventsSince(
    String code,
    int afterSeq, {
    int pageSize = 100,
  }) async {
    _tick('fetchEventsSince');
    final m = backend.require(code);
    return [
      for (final e in m.events)
        if (e.seq > afterSeq) e,
    ]..sort((a, b) => a.seq.compareTo(b.seq));
  }

  // --- rolls -----------------------------------------------------------------

  @override
  Future<void> createRoll({
    required String code,
    required int n,
    required String commit,
  }) async {
    _tick('createRoll');
    final m = backend.require(code);
    if (m.rolls.containsKey(n)) {
      throw AlreadyExistsException('rolls/$n already exists');
    }
    m.rolls[n] = FakeRoll(n: n, roller: uid, commit: commit);
    backend.bump(code);
  }

  @override
  Future<void> submitEntropy({
    required String code,
    required int n,
    required String entropy,
  }) async {
    _tick('submitEntropy');
    final roll = backend.require(code).rolls[n];
    if (roll == null) throw NotFoundException('rolls/$n');
    if (roll.roller == uid) {
      throw const PermissionDeniedException('the roller cannot add entropy');
    }
    if (roll.entropy != null || roll.reveal != null) {
      throw const PermissionDeniedException('entropy is write-once');
    }
    roll.entropy = entropy;
    backend.bump(code);
  }

  @override
  Future<void> submitReveal({
    required String code,
    required int n,
    required String reveal,
  }) async {
    _tick('submitReveal');
    final roll = backend.require(code).rolls[n];
    if (roll == null) throw NotFoundException('rolls/$n');
    if (roll.roller != uid) {
      throw const PermissionDeniedException('only the roller may reveal');
    }
    if (roll.entropy == null) {
      throw const PermissionDeniedException('reveal before entropy');
    }
    if (roll.reveal != null) {
      throw const PermissionDeniedException('reveal is write-once');
    }
    roll.reveal = reveal;
    backend.bump(code);
  }

  @override
  Future<RollDoc?> fetchRoll(String code, int n) async {
    _tick('fetchRoll');
    return backend.require(code).rolls[n]?.doc;
  }

  @override
  Future<List<RollDoc>> fetchRollsFrom(
    String code,
    int fromN, {
    int pageSize = 100,
  }) async {
    _tick('fetchRollsFrom');
    final m = backend.require(code);
    final out = [
      for (final r in m.rolls.values)
        if (r.n >= fromN) r.doc,
    ]..sort((a, b) => a.n.compareTo(b.n));
    return out;
  }

  // --- polling ---------------------------------------------------------------

  /// Change-driven rather than clock-driven, but with the SAME emission
  /// semantics as [MatchApi.pollMatch]: events once each in seq order, roll
  /// documents whenever their phase moved, and a watermark that retires the
  /// leading run of finished rolls.
  @override
  Stream<MatchPoll> pollMatch(
    String code, {
    Duration interval = const Duration(seconds: 2),
    int afterSeq = -1,
    int rollsFrom = 0,
    int pageSize = 100,
  }) {
    var lastSeq = afterSeq;
    var watermark = rollsFrom;
    final seen = <int, FairDicePhase>{};
    late StreamController<MatchPoll> controller;
    StreamSubscription<String>? sub;
    Timer? beat;

    void tick() {
      if (controller.isClosed) return;
      final m = backend.matches[code];
      if (m == null) return;
      final events = [
        for (final e in m.events)
          if (e.seq > lastSeq) e,
      ]..sort((a, b) => a.seq.compareTo(b.seq));
      if (events.isNotEmpty) lastSeq = events.last.seq;

      final rolls = [
        for (final r in m.rolls.values)
          if (r.n >= watermark) r.doc,
      ]..sort((a, b) => a.n.compareTo(b.n));
      final changed = <RollDoc>[];
      for (final roll in rolls) {
        if (seen[roll.n] != roll.phase) {
          seen[roll.n] = roll.phase;
          changed.add(roll);
        }
      }
      for (final roll in rolls) {
        if (roll.n != watermark || !roll.isComplete) break;
        watermark = roll.n + 1;
        seen.remove(roll.n);
      }
      final poll = MatchPoll(events: events, rolls: changed);
      if (poll.isNotEmpty) controller.add(poll);
    }

    controller = StreamController<MatchPoll>(
      onListen: () {
        _polls.add(controller);
        // A real poller re-reads the whole tail EVERY cycle, so it can never
        // miss a write that landed before it subscribed. Reproduce that (a
        // purely change-driven fake drops exactly those writes) with a beat as
        // fast as the event loop turns — [interval] is the real transport's
        // concern, and pacing the fake by it would only make tests wait.
        final period = pollBeat;
        void beatLoop() {
          if (controller.isClosed || period == null) return;
          tick();
          beat = Timer(period, beatLoop);
        }

        sub = backend.changes.where((c) => c == code).listen((_) => tick());
        if (period == null) {
          scheduleMicrotask(tick);
        } else {
          beat = Timer(period, beatLoop);
        }
      },
      onCancel: () async {
        _polls.remove(controller);
        beat?.cancel();
        beat = null;
        await sub?.cancel();
        sub = null;
      },
    );
    return controller.stream;
  }

  @override
  Stream<RemoteEvent> pollEvents(
    String code, {
    Duration interval = const Duration(seconds: 2),
    int afterSeq = -1,
  }) =>
      pollMatch(code, interval: interval, afterSeq: afterSeq)
          .expand((poll) => poll.events);

  @override
  Future<String> signIn() async => uid;

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Protocol helpers
// ---------------------------------------------------------------------------

/// A commit-reveal secret pair whose derivation gives exactly the dice a test
/// asked for.
typedef Secrets = ({String secret, String entropy, String commit});

Secrets _search(bool Function(String a, String b) matches, Random rng) {
  final secret = generateSecretHex(rng: rng);
  for (var i = 0; i < 20000; i++) {
    final entropy = generateSecretHex(rng: rng);
    if (matches(secret, entropy)) {
      return (secret: secret, entropy: entropy, commit: commitFor(secret));
    }
  }
  throw StateError('no entropy produced the requested dice in 20000 tries');
}

/// Secrets whose OPENING derivation is exactly [white]/[black]. Brute-forced
/// over the witness's entropy (about 30 tries on average — the derivation is a
/// hash, so this is the only way to aim it, and it is what lets a test seed a
/// specific opening WITHOUT forging an unverifiable roll).
Secrets openingSecretsFor(int white, int black, {Random? rng}) {
  if (white == black) {
    throw ArgumentError('an opening roll cannot be a tie');
  }
  return _search((a, b) {
    final d = openingDiceFrom(a, b);
    return d.die1 == white && d.die2 == black;
  }, rng ?? Random(20260727));
}

/// Secrets whose ordinary derivation is exactly [die1]/[die2].
Secrets turnSecretsFor(int die1, int die2, {Random? rng}) => _search((a, b) {
      final d = diceFrom(a, b);
      return d.die1 == die1 && d.die2 == die2;
    }, rng ?? Random(20260727));

/// Seed a match with a SOUND opening roll: a complete `rolls/1` document plus
/// the [OpeningRollEvent] it derives, authored by the host.
///
/// Everything a controller validates holds, so this is how a test starts from a
/// live game without running the protocol.
void seedOpening(
  FakeMatch match, {
  required int whiteDie,
  required int blackDie,
  int gameNo = 1,
  Random? rng,
}) {
  final n = match.rollCount + 1;
  final s = openingSecretsFor(whiteDie, blackDie, rng: rng);
  match.putRoll(n, match.hostUid, s.commit,
      entropy: s.entropy, reveal: s.secret);
  match.forgeEvent(match.hostUid, gameNo,
      OpeningRollEvent(whiteDie: whiteDie, blackDie: blackDie));
}

/// Seed a SOUND ordinary roll for [player] (whose uid must be [author]) plus its
/// [RollEvent].
void seedRoll(
  FakeMatch match, {
  required String author,
  required Player player,
  required int die1,
  required int die2,
  int gameNo = 1,
  Random? rng,
}) {
  final n = match.rollCount + 1;
  final s = turnSecretsFor(die1, die2, rng: rng);
  match.putRoll(n, author, s.commit, entropy: s.entropy, reveal: s.secret);
  match.forgeEvent(author, gameNo, RollEvent(player, die1, die2));
}
