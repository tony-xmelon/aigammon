import 'dart:async';
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:match_transport/testing.dart';
import 'package:online_client/online_client.dart';

/// An in-memory stand-in for the serverless backend's DOCUMENTS: match
/// documents, their event logs and their commit-reveal roll documents.
///
/// This is the LOBBY's test double, not the match controller's: the online
/// screen's create / join / rejoin flows talk to a [MatchApi], and this is a
/// [MatchApi] whose store a widget test can inspect and pre-seed. (The match
/// itself is exercised by `app/test/net/` over `InMemoryTransport`, and by the
/// emulator E2E over real Firestore — a [FirestoreTransport] built on this fake
/// carries the screen tests from the lobby into a ready [NetMatchController]
/// without a network.)
///
/// It deliberately enforces NOTHING that `firebase/firestore.rules` enforces
/// except document-id uniqueness (the [AlreadyExistsException] a racing append
/// has to survive) and the write-once roll phases. Rules coverage lives in
/// `firebase/`.
class FakeBackend {
  final Map<String, FakeMatch> matches = {};

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

/// One signed-in user's view of a [FakeBackend] — the seam the online screens
/// (and the [FirestoreTransport] they build) consume.
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

  /// Seed a sound opening roll the first time a match goes active, standing in
  /// for the host client that no widget test has running.
  bool autoSeedOpening = false;
  int openingWhiteDie = 6;
  int openingBlackDie = 3;

  void _maybeSeedOpening(FakeMatch m) {
    if (!autoSeedOpening || m.events.isNotEmpty || m.guestUid == null) return;
    seedOpening(m, whiteDie: openingWhiteDie, blackDie: openingBlackDie);
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
    return m.doc;
  }

  @override
  Future<void> completeMatch(String code) async {
    _tick('completeMatch');
    backend.require(code).status = 'complete';
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

  @override
  Future<String> signIn() async {
    // Ticked like every other operation so a test can fail the ONE call
    // `FirestoreTransport.connect()` makes before anything else — the way a
    // launch that never connects is provoked.
    _tick('signIn');
    return uid;
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Seeding helpers
// ---------------------------------------------------------------------------

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
