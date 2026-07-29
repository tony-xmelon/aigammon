import 'dart:convert';
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:match_transport/match_transport.dart'
    show CompletedRoll, FairDicePhase;

import 'auth_client.dart';
import 'firestore_docs.dart';
import 'online_config.dart';
import 'online_exception.dart';
import 'token_store.dart';

// ---------------------------------------------------------------------------
// Document-id convention
// ---------------------------------------------------------------------------

/// Number of digits in an `events/{seq}` or `rolls/{n}` document id.
const int kIndexDigits = 8;

/// The document id for log index [index]: the number rendered as exactly
/// [kIndexDigits] decimal digits, zero-padded.
///
/// Two properties depend on this, and `firebase/firestore.rules` enforces it
/// (`id.matches('^[0-9]{8}$') && int(id) == data.seq`):
///   * the id IS the sequence number, so a create can only ever land once —
///     that is what makes the append log contiguous without a server;
///   * zero padding makes lexicographic id order equal numeric order.
String logDocId(int index) {
  if (index < 0) throw ArgumentError.value(index, 'index', 'must not be negative');
  final text = index.toString();
  if (text.length > kIndexDigits) {
    throw ArgumentError.value(index, 'index', 'exceeds $kIndexDigits digits');
  }
  return text.padLeft(kIndexDigits, '0');
}

// ---------------------------------------------------------------------------
// Invite codes
// ---------------------------------------------------------------------------

/// Alphabet for invite codes: A–Z minus the confusable I and O, plus 2–9.
/// 32 symbols, so an 8-character code carries 40 bits.
const String kCodeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// Length of an invite code (also the `matches/{code}` document id).
const int kCodeLength = 8;

/// A fresh invite code. Uses [Random.secure] unless a deterministic [rng] is
/// injected (tests only — a predictable code is a guessable match).
String generateInviteCode({Random? rng}) {
  final random = rng ?? Random.secure();
  return String.fromCharCodes([
    for (var i = 0; i < kCodeLength; i++)
      kCodeAlphabet.codeUnitAt(random.nextInt(kCodeAlphabet.length)),
  ]);
}

// ---------------------------------------------------------------------------
// Decoded documents
// ---------------------------------------------------------------------------

/// A decoded `matches/{code}` document.
///
/// Seats are positional, not stored: the HOST plays white and the GUEST plays
/// black. Nothing about the game itself lives here — the event log is the game.
class MatchDoc {
  /// The invite code, which is also the document id.
  final String code;

  final String hostUid;

  /// Null until an opponent joins.
  final String? guestUid;

  /// Match length in points (odd, 1..25).
  final int length;

  /// True for a cubeless match (no doubling cube).
  final bool cubeless;

  /// `waiting` | `active` | `complete`.
  final String status;

  /// Server-stamped creation time; null when the caller has not read it back.
  final DateTime? createdAt;

  const MatchDoc({
    required this.code,
    required this.hostUid,
    required this.guestUid,
    required this.length,
    required this.cubeless,
    required this.status,
    this.createdAt,
  });

  /// The seat the host plays. The guest plays [Player.black].
  static const Player hostSide = Player.white;

  bool get isWaiting => status == 'waiting';
  bool get isActive => status == 'active';
  bool get isComplete => status == 'complete';

  /// True iff [uid] is one of the two players.
  bool isParticipant(String uid) => uid == hostUid || uid == guestUid;

  /// The seat [uid] plays, or null if it is not a participant.
  Player? sideOf(String uid) {
    if (uid == hostUid) return hostSide;
    if (guestUid != null && uid == guestUid) return hostSide.opponent;
    return null;
  }

  /// Decode from a document id and its decoded field map.
  factory MatchDoc.fromFields(String code, Map<String, Object?> f) {
    T need<T>(String key) {
      final v = f[key];
      if (v is! T) {
        throw OnlineException(
            'malformed-match', 'matches/$code: bad or missing "$key"');
      }
      return v;
    }

    final createdAt = f['createdAt'];
    return MatchDoc(
      code: code,
      hostUid: need<String>('hostUid'),
      guestUid: f['guestUid'] as String?,
      length: need<int>('length'),
      cubeless: need<bool>('cubeless'),
      status: need<String>('status'),
      createdAt: createdAt is DateTime ? createdAt : null,
    );
  }

  MatchDoc copyWith({String? guestUid, String? status}) => MatchDoc(
        code: code,
        hostUid: hostUid,
        guestUid: guestUid ?? this.guestUid,
        length: length,
        cubeless: cubeless,
        status: status ?? this.status,
        createdAt: createdAt,
      );
}

/// One decoded document from a match's `events` subcollection.
///
/// The folding contract the controller relies on — `{seq, gameNo, event}` in
/// contiguous seq order — is unchanged from the callable era; [author] is new
/// and lets the folding side check who claimed each event.
class RemoteEvent {
  final int seq;
  final int gameNo;
  final GameEvent event;

  /// The uid that appended this event (rules pin it to the writer).
  final String author;

  const RemoteEvent({
    required this.seq,
    required this.gameNo,
    required this.event,
    required this.author,
  });

  /// Decode an event document's field map.
  ///
  /// `event` is stored as a JSON *string* (the rules can only size-cap a
  /// string; see the header of `firebase/firestore.rules`), so decoding is
  /// `jsonDecode` then [GameEvent.fromJson] — no field remapping. This is why
  /// the old nested-array workaround (move hops as maps) is gone: a JSON string
  /// carries `[[from,to,hit],…]` verbatim.
  factory RemoteEvent.fromFields(Map<String, Object?> f) {
    final raw = f['event'];
    if (raw is! String) {
      throw OnlineException('malformed-event', 'event field is not a string');
    }
    final seq = f['seq'];
    final gameNo = f['gameNo'];
    if (seq is! int || gameNo is! int) {
      throw OnlineException('malformed-event', 'bad seq/gameNo: $f');
    }
    return RemoteEvent(
      seq: seq,
      gameNo: gameNo,
      author: f['author'] as String? ?? '',
      event: GameEvent.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      ),
    );
  }
}

/// A decoded `matches/{code}/rolls/{n}` document at whatever phase it has
/// reached: `commit` always, then `entropy`, then `reveal`.
class RollDoc {
  final int n;

  /// Uid of the player whose roll this is (the committer).
  final String roller;

  final String commit;
  final String? entropy;
  final String? reveal;

  const RollDoc({
    required this.n,
    required this.roller,
    required this.commit,
    this.entropy,
    this.reveal,
  });

  /// True once all three protocol values are present.
  bool get isComplete => entropy != null && reveal != null;

  /// The phase this document has reached, in the vocabulary of `fair_dice.dart`.
  FairDicePhase get phase {
    if (reveal != null) return FairDicePhase.revealed;
    if (entropy != null) return FairDicePhase.entropy;
    return FairDicePhase.committed;
  }

  /// The finished roll, or null while a phase is still outstanding. Verifying
  /// the commitment and deriving dice is the caller's job (see [CompletedRoll]).
  CompletedRoll? get completed => isComplete
      ? CompletedRoll(
          commit: commit, entropy: entropy!, reveal: reveal!, index: n)
      : null;

  factory RollDoc.fromFields(Map<String, Object?> f) {
    final n = f['n'];
    final roller = f['roller'];
    final commit = f['commit'];
    if (n is! int || roller is! String || commit is! String) {
      throw OnlineException('malformed-roll', 'bad roll document: $f');
    }
    return RollDoc(
      n: n,
      roller: roller,
      commit: commit,
      entropy: f['entropy'] as String?,
      reveal: f['reveal'] as String?,
    );
  }
}

// ---------------------------------------------------------------------------
// MatchApi
// ---------------------------------------------------------------------------

/// The LOW-LEVEL online layer: anonymous auth plus direct Firestore document
/// operations, one method per document operation the model has. There is no
/// server-side code — every rule the model has is in `firebase/firestore.rules`,
/// and everything else is agreed between the two clients (see `fair_dice.dart`
/// for the dice, and the controller for game legality).
///
/// One [MatchApi] serves the whole app run (it holds the anonymous session and
/// the HTTP clients). The per-match `MatchTransport` the controller drives is
/// [FirestoreTransport], which is a thin view over this class and adds the parts
/// that are per-match rather than per-app: the poll loop, the read-budget
/// watermarks, the 0-based↔1-based seq bridge and the typed-error mapping.
///
/// Errors are typed (see `online_exception.dart`). The three the caller must
/// handle by name:
///   * [AlreadyExistsException] on [submitEvent] / [createRoll] — the opponent
///     claimed that index first; resync the log and retry at the next index;
///   * [PermissionDeniedException] — the rules refused; never retryable, and on
///     a roll-phase write it means the peer is out of protocol;
///   * [NotFoundException] on [joinMatch] — no match with that code.
class MatchApi {
  final AuthClient auth;
  final FirestoreDocs docs;
  final Random? _codeRandom;

  MatchApi({required this.auth, required this.docs, Random? codeRandom})
      : _codeRandom = codeRandom;

  /// Build the whole stack (auth + Firestore) for [config]. Call [signIn]
  /// before any other operation.
  ///
  /// Pass a [tokenStore] to make the anonymous uid survive a restart — without
  /// one every launch is a new user, which strands both seats of a match in
  /// progress (see `token_store.dart`).
  factory MatchApi.forConfig(
    OnlineConfig config, {
    Random? codeRandom,
    TokenStore? tokenStore,
  }) {
    final auth = AuthClient(config, store: tokenStore);
    return MatchApi(
      auth: auth,
      docs: FirestoreDocs(config, token: auth.validToken),
      codeRandom: codeRandom,
    );
  }

  /// The signed-in uid. Throws [StateError] before [signIn].
  String get uid {
    final session = auth.session;
    if (session == null) {
      throw StateError('not signed in — call signIn() first');
    }
    return session.uid;
  }

  /// Sign in anonymously (idempotent: reuses an existing session), returning
  /// the uid. Token refresh is automatic from here on.
  Future<String> signIn() async {
    final existing = auth.session;
    if (existing != null) return existing.uid;
    final session = await auth.signInAnonymously();
    return session.uid;
  }

  /// Release the underlying HTTP clients.
  void close() {
    auth.close();
    docs.close();
  }

  // --- matches ---------------------------------------------------------------

  /// Open a new match and return its document (the invite code is [MatchDoc.code]).
  ///
  /// The code is chosen client-side and IS the document id, so creation doubles
  /// as claiming it; a collision (astronomically unlikely at 40 bits, but
  /// cheap to survive) is retried up to [attempts] times with a fresh code.
  ///
  /// `createdAt` is stamped by the server via an `updateTransforms`
  /// `REQUEST_TIME` — the rules require `createdAt == request.time`, which no
  /// client-supplied value can satisfy. The returned [MatchDoc] therefore
  /// leaves `createdAt` null; read the match back if the value is needed.
  Future<MatchDoc> createMatch({
    required int length,
    required bool cubeless,
    int attempts = 5,
  }) async {
    Object? lastFailure;
    for (var attempt = 0; attempt < attempts; attempt++) {
      final code = generateInviteCode(rng: _codeRandom);
      final fields = <String, Object?>{
        'hostUid': uid,
        'guestUid': null,
        'length': length,
        'cubeless': cubeless,
        'status': 'waiting',
      };
      try {
        await docs.create('matches/$code', fields, serverTimestamps: ['createdAt']);
        return MatchDoc(
          code: code,
          hostUid: uid,
          guestUid: null,
          length: length,
          cubeless: cubeless,
          status: 'waiting',
        );
      } on AlreadyExistsException catch (e) {
        lastFailure = e;
      }
    }
    throw OnlineException(
      'code-collision',
      'could not claim a free invite code in $attempts attempts '
          '(last: $lastFailure)',
    );
  }

  /// Read the match with invite [code].
  ///
  /// Throws [NotFoundException] for an unknown code and
  /// [PermissionDeniedException] when the match exists but is neither waiting
  /// nor ours (the rules only expose a joined match to its two players).
  Future<MatchDoc> fetchMatch(String code) async {
    final doc = await docs.get('matches/$code');
    if (doc == null) {
      throw NotFoundException('no match with code $code');
    }
    return MatchDoc.fromFields(code, doc.fields);
  }

  /// Take the open seat in the match with invite [code].
  ///
  /// Reads the match first — a bad code surfaces as [NotFoundException], and an
  /// already-full or already-yours match as [FailedPreconditionException],
  /// both before any write is attempted — then patches exactly
  /// `guestUid` + `status`, the two keys the join transition pins.
  ///
  /// Contention is resolved by the rules, not by a client precondition: the
  /// join transition requires `status == 'waiting' && guestUid == null` in the
  /// PRE-state, so of two guests racing for the last seat exactly one write
  /// lands and the loser is refused. Since this method has already seen the
  /// seat open, a refusal here can only mean the race was lost, so it is
  /// re-thrown as [FailedPreconditionException] — same class the caller gets
  /// for a match that was full to begin with.
  ///
  /// Returns the joined match, with the caller seated as guest.
  Future<MatchDoc> joinMatch(String code) async {
    final doc = await docs.get('matches/$code');
    if (doc == null) {
      throw NotFoundException('no match with code $code');
    }
    final match = MatchDoc.fromFields(code, doc.fields);
    if (match.hostUid == uid) {
      throw FailedPreconditionException('you cannot join your own match');
    }
    if (!match.isWaiting || match.guestUid != null) {
      throw FailedPreconditionException(
          'match $code is not open to join (status: ${match.status})');
    }
    try {
      await docs.patch(
        'matches/$code',
        {'guestUid': uid, 'status': 'active'},
        updateMask: const ['guestUid', 'status'],
      );
    } on PermissionDeniedException {
      throw FailedPreconditionException(
          'someone else took the last seat in match $code');
    }
    return match.copyWith(guestUid: uid, status: 'active');
  }

  /// Mark an active match complete. Either participant may do this; the
  /// authoritative result lives in the event log.
  Future<void> completeMatch(String code) async {
    await docs.patch(
      'matches/$code',
      {'status': 'complete'},
      updateMask: const ['status'],
    );
  }

  // --- events ----------------------------------------------------------------

  /// Append [event] to the log at [seq].
  ///
  /// [seq] is the caller's — the log has no server to allocate it, so the
  /// controller writes at `lastFoldedSeq + 1` and relies on the document id
  /// being the sequence number: if the opponent got there first this throws
  /// [AlreadyExistsException] and the caller must resync and retry.
  Future<void> submitEvent({
    required String code,
    required int seq,
    required int gameNo,
    required GameEvent event,
  }) async {
    await docs.create('matches/$code/events/${logDocId(seq)}', {
      'seq': seq,
      'gameNo': gameNo,
      'event': jsonEncode(event.toJson()),
      'author': uid,
    });
  }

  /// Fetch events with `seq > afterSeq`, ascending, following pages until the
  /// log is exhausted. [pageSize] bounds each round trip (and is what the
  /// pagination tests shrink).
  Future<List<RemoteEvent>> fetchEventsSince(
    String code,
    int afterSeq, {
    int pageSize = 100,
  }) async {
    final out = <RemoteEvent>[];
    var cursor = afterSeq;
    while (true) {
      final page = await docs.query(
        'matches/$code',
        'events',
        whereInt: ('seq', FieldOp.greaterThan, cursor),
        orderBy: 'seq',
        limit: pageSize,
      );
      for (final doc in page) {
        final event = RemoteEvent.fromFields(doc.fields);
        out.add(event);
        cursor = event.seq;
      }
      if (page.length < pageSize) return out;
    }
  }

  // --- rolls (commit-reveal) -------------------------------------------------

  /// Phase 1 — publish the roller's commitment for roll [n].
  ///
  /// Throws [AlreadyExistsException] if roll [n] already exists (both peers
  /// thought it was their roll, or a stale retry).
  Future<void> createRoll({
    required String code,
    required int n,
    required String commit,
  }) async {
    await docs.create('matches/$code/rolls/${logDocId(n)}', {
      'n': n,
      'roller': uid,
      'commit': commit,
    });
  }

  /// Phase 2 — the witness contributes entropy to roll [n].
  ///
  /// [PermissionDeniedException] means the rules refused: writing entropy to
  /// our own roll, writing it twice, or writing it after a reveal already
  /// landed. All of those are protocol violations, not transient failures.
  Future<void> submitEntropy({
    required String code,
    required int n,
    required String entropy,
  }) async {
    await docs.patch(
      'matches/$code/rolls/${logDocId(n)}',
      {'entropy': entropy},
      updateMask: const ['entropy'],
    );
  }

  /// Phase 3 — the roller reveals its secret for roll [n]. Denied by the rules
  /// until entropy exists, which is what stops the roller picking its secret
  /// after seeing the opponent's.
  Future<void> submitReveal({
    required String code,
    required int n,
    required String reveal,
  }) async {
    await docs.patch(
      'matches/$code/rolls/${logDocId(n)}',
      {'reveal': reveal},
      updateMask: const ['reveal'],
    );
  }

  /// Read roll [n], or null if it has not been created yet.
  Future<RollDoc?> fetchRoll(String code, int n) async {
    final doc = await docs.get('matches/$code/rolls/${logDocId(n)}');
    if (doc == null) return null;
    return RollDoc.fromFields(doc.fields);
  }

  /// Fetch rolls with `n >= fromN`, ascending, following pages to the end.
  Future<List<RollDoc>> fetchRollsFrom(
    String code,
    int fromN, {
    int pageSize = 100,
  }) async {
    final out = <RollDoc>[];
    var cursor = fromN;
    while (true) {
      final page = await docs.query(
        'matches/$code',
        'rolls',
        whereInt: ('n', FieldOp.greaterThanOrEqual, cursor),
        orderBy: 'n',
        limit: pageSize,
      );
      for (final doc in page) {
        final roll = RollDoc.fromFields(doc.fields);
        out.add(roll);
        cursor = roll.n + 1;
      }
      if (page.length < pageSize) return out;
    }
  }
}
