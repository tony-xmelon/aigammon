@Tags(['emulator'])
library;

import 'dart:async';
import 'dart:io';

import 'package:aigammon_app/data/persistence_hooks.dart';
import 'package:aigammon_app/game/player_agent.dart' show CubeAction;
import 'package:aigammon_app/net/net_match_controller.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:match_transport/match_transport.dart';
import 'package:match_transport/testing.dart';
import 'package:online_client/online_client.dart';

/// Two-client end-to-end tests through the REAL Firebase Emulator Suite (Auth +
/// Firestore + `firestore.rules`; there is no functions emulator in the
/// serverless model).
///
/// Where `app/test/net/` drives two [NetMatchController]s against an in-process
/// `InMemoryTransport`, this file wires two of them over two [FirestoreTransport]s
/// — each with its own anonymous user, its own token and its own REST stack — to
/// one real match document and plays it out. Nothing is shortcut: every roll runs
/// the commit-reveal protocol over real `rolls/{n}` documents, every event is a
/// real `events/{seq}` create, and every refusal below is one the deployed
/// `firestore.rules` produced.
///
/// This is therefore also the proof that the UNIFIED controller (the one LAN play
/// drives over a socket) keeps every security property the shipped online
/// controller had, on the substrate that has a hostile peer in it.
///
/// ## What it covers
///
///  1. **the happy path** — create → join → a COMPLETE match, with the two
///     clients' derived state compared at every fold depth, the whole roll
///     protocol audited afterwards, persistence hooks fired on both ends and
///     the match document flipped to `complete`;
///  2. **forgeries the RULES must block** — direct `FirestoreDocs` writes that
///     bypass [MatchApi] entirely (wrong author, event rewrite, roll phase
///     skip, match-field tamper): each must come back
///     [PermissionDeniedException], and the two honest controllers must play on
///     as if nothing happened;
///  3. **forgeries the rules CANNOT block** — a well-shaped, correctly-authored
///     but ILLEGAL event; a double in a CUBELESS match; a reveal that does not
///     hash to its commitment. Rules have no rules engine and cannot compute
///     sha256, so the honest peer is the only referee: it must FREEZE,
///     permanently;
///  4. **the dice-lookahead defence** — a peer squatting its future roll
///     documents gets no entropy for them, and the DUE roll still does.
///
/// ## Gating and pacing
///
/// Skipped unless `AIGAMMON_EMULATOR` is set (see `app/dart_test.yaml` for why
/// an env gate rather than `exclude_tags`), and run by
/// `firebase/run-emulator-tests.ps1` / `firebase/ci-emulator-suites.sh` inside a
/// throwaway emulator.
///
/// The RESTING poll interval defaults to 2s in production, which is far too slow
/// here: a roll costs about three poll latencies (commit → entropy → reveal) and
/// a move costs one more, so a whole game ran to minutes of pure waiting — a
/// measured single game took **4m50s** at a flat 2000ms against 20-30s at 100ms.
/// That measurement is what produced [FirestoreTransport.fastPollInterval]:
/// production now polls at 500ms for exactly as long as a handshake is
/// outstanding. [_pollInterval] is still turned down to [_defaultPollMs] ms here
/// (overridable with `AIGAMMON_E2E_POLL_MS`), and because the fast cadence is
/// capped at the resting one, that single knob overrides both. The transport
/// takes the interval as a constructor parameter, so nothing production-side
/// changes for the sake of the test.

/// ## Reading the numbers
///
/// The happy-path test prints a wall-clock time and a delivered-document count.
/// Both need a caveat, and neither is a production figure on its own:
///
///  * **wall clock** is dominated by the delivery path. Measured on this machine
///    at a 100ms poll knob: **26.7s on the polling path** against **4.5s on the
///    listener path** for one 1-point match (the listener has no cycle to wait
///    for, so a roll's three phases arrive as fast as they commit rather than in
///    three poll latencies). Production polls at 2s/500ms rather than 100ms, so
///    the real-world gap is far wider than 6x.
///  * **delivered documents** is `FirestoreTransport.documentsRead` summed over
///    both clients. On the POLLING path it is accurate but incomplete (it counts
///    query result rows, and cannot see the `firestore.rules` `get()` that every
///    read evaluates and that Firestore bills too). On the LISTENER path it is
///    wildly INFLATED, because the Firestore EMULATOR does not diff a watch: it
///    re-sends a target's entire result set on every change, so a 94-event match
///    delivers ~15,000 documents locally where production delivers each changed
///    document once. That is why the line also prints the
///    production-equivalent figure — `(events + 3 x rolls) x 2 watchers` — which
///    is what `firebase/DEPLOY.md`'s free-tier budget is reasoned from.
///
// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Poll interval used unless `AIGAMMON_E2E_POLL_MS` overrides it.
///
/// Fast enough to keep the whole emulator pipeline well under three minutes,
/// slow enough that the two clients still exercise real polling (each cycle is
/// two Firestore queries per client).
const int _defaultPollMs = 100;

Duration get _pollInterval {
  final raw = Platform.environment['AIGAMMON_E2E_POLL_MS']?.trim();
  final ms = int.tryParse(raw ?? '') ?? _defaultPollMs;
  return Duration(milliseconds: ms);
}

/// Whether the transports get a real-time Firestore `Listen` stream.
///
/// On by default — that IS production now, and the whole suite is here to prove
/// the listener path carries every property the polling path had. Set
/// `AIGAMMON_E2E_LISTEN=0` to run the identical suite on polling alone, which is
/// how the two are compared (and how a gRPC problem is isolated from a game
/// problem).
bool get _useListeners {
  final raw = Platform.environment['AIGAMMON_E2E_LISTEN']?.trim();
  return raw == null || raw.isEmpty || raw != '0';
}

/// One anonymous user with a full REST stack of its own.
class _Client {
  _Client(this.api, this.uid);

  final MatchApi api;
  final String uid;
}

/// Records every persistence hook, so a test can prove both ends wrote history.
class _RecordingPersistence implements MatchPersistence {
  final List<({int gameNumber, GameResult result, MatchState matchAfter})>
      games = [];
  MatchState? finalState;
  int matchFinishedCalls = 0;

  @override
  Future<void> onGameFinished({
    required int gameNumber,
    required bool isCrawford,
    required List<GameEvent> events,
    required GameResult result,
    required MatchState matchAfter,
  }) async {
    games.add((gameNumber: gameNumber, result: result, matchAfter: matchAfter));
  }

  @override
  Future<void> onMatchFinished(MatchState state) async {
    matchFinishedCalls++;
    finalState = state;
  }
}

void main() {
  // Env gate: skip entirely unless explicitly asked to run against the emulator.
  // Trim because cmd.exe's `set VAR=1 && ...` captures a trailing space into the
  // value; treat any non-empty, non-"0" value as enabled.
  final gate = Platform.environment['AIGAMMON_EMULATOR']?.trim();
  final runEmulator = gate != null && gate.isNotEmpty && gate != '0';
  final skipReason = runEmulator
      ? null
      : 'Set AIGAMMON_EMULATOR=1 and run inside the Firebase Emulator Suite '
          '(see firebase/run-emulator-tests.ps1).';

  final config = OnlineConfig.emulator();

  // -------------------------------------------------------------------------
  // Fixtures
  // -------------------------------------------------------------------------

  /// A signed-in anonymous user, closed at teardown.
  Future<_Client> signIn() async {
    final api = MatchApi.forConfig(config);
    final uid = await api.signIn();
    addTearDown(api.close);
    return _Client(api, uid);
  }

  /// A created + joined match. The returned [MatchDoc] is the JOINED one, so
  /// both controllers can be seated from it.
  Future<({_Client host, _Client guest, MatchDoc doc})> newMatch({
    int length = 1,
    bool cubeless = false,
  }) async {
    final host = await signIn();
    final guest = await signIn();
    final created = await host.api.createMatch(length: length, cubeless: cubeless);
    final joined = await guest.api.joinMatch(created.code);
    expect(joined.sideOf(host.uid), Player.white);
    expect(joined.sideOf(guest.uid), Player.black);
    return (host: host, guest: guest, doc: joined);
  }

  /// Plays the OPENING roll by hand, through the real REST stack, so the test
  /// decides who starts.
  ///
  /// Every write is one a rules-abiding client would make (host commits, guest
  /// contributes entropy, host reveals, host appends the event); the secrets are
  /// brute-forced by [openingSecretsFor] so the derivation really does produce
  /// [whiteDie]/[blackDie] — the dice are AIMED, never forged, and both
  /// controllers validate them exactly as they would their own.
  ///
  /// The event goes in at DOCUMENT seq 0 — the log's native numbering, which the
  /// transport presents to the controllers as contract seq 1.
  Future<void> seedOpening(
    _Client host,
    _Client guest,
    String code, {
    required int whiteDie,
    required int blackDie,
  }) async {
    final s = openingSecretsFor(whiteDie, blackDie);
    await host.api.createRoll(code: code, n: 1, commit: s.commit);
    await guest.api.submitEntropy(code: code, n: 1, entropy: s.entropy);
    await host.api.submitReveal(code: code, n: 1, reveal: s.secret);
    await host.api.submitEvent(
      code: code,
      seq: 0,
      gameNo: 1,
      event: OpeningRollEvent(whiteDie: whiteDie, blackDie: blackDie),
    );
  }

  /// Every transport built by [controllerFor] in this test, so a test can read
  /// its read count or sever its listener.
  final transports = <FirestoreTransport>[];

  /// Every real-time channel built in this test, newest last.
  final channels = <_BreakableChannel>[];

  setUp(() {
    transports.clear();
    channels.clear();
  });

  /// A controller over its own [FirestoreTransport] — the production wiring,
  /// real-time listener included (see [_useListeners]).
  ///
  /// The channel is wrapped in a [_BreakableChannel] so a test can drop the
  /// stream the way a lost connection would, without touching the emulator.
  NetMatchController controllerFor(
    _Client client,
    MatchDoc doc, {
    MatchPersistence persistence = const NoopPersistence(),
  }) {
    final transport = FirestoreTransport(
      api: client.api,
      code: doc.code,
      match: doc,
      pollInterval: _pollInterval,
      listenRetryFloor: const Duration(milliseconds: 200),
      listenChannel: !_useListeners
          ? null
          : () {
              final channel = _BreakableChannel(GrpcFirestoreListenChannel(
                config: config,
                token: client.api.auth.validToken,
              ));
              channels.add(channel);
              return channel;
            },
    );
    transports.add(transport);
    final c = NetMatchController(
      transport: transport,
      persistence: persistence,
      // The listener can drop mid-submission, and then a committed write has to
      // come back through a poll cycle; the same sizing production uses.
      gateTimeout: transport.suggestedGateTimeout,
    );
    // The controller OWNS the transport, so disposing it is the whole teardown.
    addTearDown(c.disposeController);
    return c;
  }

  // -------------------------------------------------------------------------
  // Driving
  // -------------------------------------------------------------------------

  /// Waits (in real time) for [done], failing with [reason] on timeout.
  Future<void> waitFor(
    bool Function() done, {
    Duration timeout = const Duration(seconds: 30),
    String reason = 'condition never became true',
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail(reason);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Re-[read]s a document until [done] accepts it, and returns it.
  Future<T> readUntil<T>(
    Future<T> Function() read,
    bool Function(T) done, {
    Duration timeout = const Duration(seconds: 30),
    String reason = 'the document never reached the expected state',
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final value = await read();
      if (done(value)) return value;
      if (DateTime.now().isAfter(deadline)) fail(reason);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test(
    'two clients play a complete match through the emulator, and agree at '
    'every fold',
    () async {
      final m = await newMatch(length: 1);
      final code = m.doc.code;
      // White (the host) starts; the opening is aimed rather than left to the
      // protocol so the test is reproducible from move one.
      await seedOpening(m.host, m.guest, code, whiteDie: 6, blackDie: 3);

      final hostStore = _RecordingPersistence();
      final guestStore = _RecordingPersistence();
      final host = controllerFor(m.host, m.doc, persistence: hostStore);
      final guest = controllerFor(m.guest, m.doc, persistence: guestStore);

      final started = DateTime.now();
      await host.playMatch();
      await guest.playMatch();
      await host.ready;
      await guest.ready;
      expect(host.isReady, isTrue);
      expect(guest.isReady, isTrue);
      expect(host.localSide, Player.white, reason: 'the host holds white');
      expect(guest.localSide, Player.black);
      expect(host.state.turn, Player.white,
          reason: 'the seeded 6-3 opening puts white on move');

      var comparisons = 0;
      final lastActed = <NetMatchController, GameState?>{};
      final deadline = DateTime.now().add(const Duration(minutes: 20));
      while (!(host.matchOver && guest.matchOver)) {
        if (host.frozen || guest.frozen) {
          fail('a controller froze mid-match: ${host.cheatError ?? guest.cheatError}');
        }
        if (DateTime.now().isAfter(deadline)) {
          fail('the match did not finish in time.\n'
              '${_diag('host', host)}\n${_diag('guest', guest)}');
        }
        _act(host, lastActed);
        _act(guest, lastActed);
        comparisons += _expectConverged(host, guest);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final elapsed = DateTime.now().difference(started);

      // --- the two clients agree ------------------------------------------
      expect(host.error, isNull, reason: 'the host ended with an error');
      expect(guest.error, isNull, reason: 'the guest ended with an error');
      expect(host.match.winner, isNotNull);
      expect(host.match.winner, guest.match.winner);
      expect(host.match.whiteScore, guest.match.whiteScore);
      expect(host.match.blackScore, guest.match.blackScore);
      expect(comparisons, greaterThan(10),
          reason: 'the convergence check never got to compare the two clients');
      expect(_expectConverged(host, guest), 1,
          reason: 'the two clients did not finish at the same fold depth');

      // --- persistence fired on BOTH ends ----------------------------------
      await waitFor(
        () =>
            hostStore.matchFinishedCalls == 1 &&
            guestStore.matchFinishedCalls == 1,
        reason: 'a persistence hook never recorded the finished match',
      );
      expect(hostStore.games, hasLength(1));
      expect(guestStore.games, hasLength(1));
      expect(hostStore.games.single.gameNumber, 1);
      expect(hostStore.games.single.result, guestStore.games.single.result,
          reason: 'the two ends recorded different results for the same game');
      expect(hostStore.finalState!.whiteScore, host.match.whiteScore);
      expect(guestStore.finalState!.blackScore, host.match.blackScore);

      // --- the match document was closed out --------------------------------
      final finalDoc = await readUntil(
        () => m.host.api.fetchMatch(code),
        (d) => d.status == 'complete',
        reason: 'the match document never reached status "complete"',
      );
      expect(finalDoc.hostUid, m.host.uid);
      expect(finalDoc.guestUid, m.guest.uid);

      // --- every roll ran the whole protocol --------------------------------
      final events = await m.host.api.fetchEventsSince(code, -1);
      final rolls = await m.host.api.fetchRollsFrom(code, 1);
      expect(events.map((e) => e.seq), [for (var i = 0; i < events.length; i++) i],
          reason: 'the log must be contiguous from 0');

      final rollEvents = events
          .where((e) => e.event is OpeningRollEvent || e.event is RollEvent)
          .toList();
      expect(rolls.map((r) => r.n), [for (var i = 1; i <= rollEvents.length; i++) i],
          reason: 'one roll document per roll-bearing event, contiguous from 1');

      for (var i = 0; i < rollEvents.length; i++) {
        final re = rollEvents[i];
        final doc = rolls[i];
        expect(doc.isComplete, isTrue, reason: 'roll ${doc.n} never completed');
        expect(commitMatches(doc.commit, doc.reveal!), isTrue,
            reason: 'roll ${doc.n} revealed a secret that is not its pre-image');
        expect(doc.roller, re.author,
            reason: 'roll ${doc.n} was committed by someone other than the '
                'author of its event');
        final completed = doc.completed!;
        final event = re.event;
        if (event is OpeningRollEvent) {
          expect(re.author, m.host.uid, reason: 'openings are the host\'s');
          expect(openingDiceMatchRoll(completed, event), isTrue,
              reason: 'event ${re.seq} does not carry roll ${doc.n}\'s dice');
        } else {
          final roll = event as RollEvent;
          expect(re.author, roll.player == Player.white ? m.host.uid : m.guest.uid,
              reason: 'a roll event must be written by the player who rolled');
          expect(diceMatchRoll(completed, roll), isTrue,
              reason: 'event ${re.seq} does not carry roll ${doc.n}\'s dice');
        }
      }

      // --- an independent replay of the stored log agrees --------------------
      final byGame = <int, List<GameEvent>>{};
      for (final re in events) {
        (byGame[re.gameNo] ??= <GameEvent>[]).add(re.event);
      }
      var replayed = MatchState(matchLength: m.doc.length);
      for (final gameNo in byGame.keys.toList()..sort()) {
        final g = Game.replay(byGame[gameNo]!,
            isCrawfordGame: replayed.isCrawfordNext);
        if (g.state.phase == GamePhase.gameOver) {
          replayed = replayed.applyResult(g.state.result!);
        }
      }
      expect(replayed.whiteScore, host.match.whiteScore);
      expect(replayed.blackScore, host.match.blackScore);
      expect(replayed.winner, host.match.winner);

      // Timing and read count are the point of Plan 17's Task 5 — report both,
      // on whichever path this run used. `documentsRead` is a LOWER bound on what
      // Firestore bills (a rules `get()` is billed too and is invisible from
      // here), but it is the number that separates "polled every cycle" from
      // "pushed once per change", which is the claim `firebase/DEPLOY.md` makes.
      final reads = transports.fold<int>(0, (sum, t) => sum + t.documentsRead);
      // A changed document reaches BOTH watchers, and a roll changes three times.
      final changed = (events.length + 3 * rolls.length) * 2;
      // ignore: avoid_print
      print('E2E full match: ${elapsed.inMilliseconds / 1000}s wall-clock '
          '(${_useListeners ? 'LISTENER' : 'POLLING'} path, '
          '${_pollInterval.inMilliseconds}ms poll interval) — '
          '${events.length} events, ${rolls.length} rolls, '
          '$comparisons convergence checks. '
          'Documents handed to the two transports: $reads '
          '(production-equivalent delivery for this match: $changed — '
          'see "Reading the numbers" in this file).');
      if (_useListeners) {
        expect(transports.every((t) => t.listenerLive), isTrue,
            reason: 'the whole match should have run on the listener');
      }
    },
    timeout: const Timeout(Duration(minutes: 25)),
    skip: skipReason,
  );

  // =========================================================================
  test(
    'a listener dropped mid-match falls back to polling, and the match still '
    'finishes',
    () async {
      // The fallback is the difference between "slower for a moment" and "a dead
      // match". So: play a real match, sever the host's real-time stream in the
      // middle of it, and require BOTH that the game keeps moving on the poll
      // loop and that the listener comes back by itself.
      final m = await newMatch(length: 1);
      await seedOpening(m.host, m.guest, m.doc.code, whiteDie: 6, blackDie: 3);
      final host = controllerFor(m.host, m.doc);
      final guest = controllerFor(m.guest, m.doc);
      await host.playMatch();
      await guest.playMatch();
      await host.ready;
      await guest.ready;

      await waitFor(() => host.linkStatus.value == TransportStatus.connected);
      final hostTransport = transports.first;
      await waitFor(() => hostTransport.listenerLive,
          reason: 'the host never got a live listener to drop');

      var severed = false;
      var polledWhileDown = false;
      final lastActed = <NetMatchController, GameState?>{};
      final deadline = DateTime.now().add(const Duration(minutes: 20));
      while (!(host.matchOver && guest.matchOver)) {
        if (host.frozen || guest.frozen) {
          fail('a controller froze mid-match: '
              '${host.cheatError ?? guest.cheatError}');
        }
        if (DateTime.now().isAfter(deadline)) {
          fail('the match did not finish in time.\n'
              '${_diag('host', host)}\n${_diag('guest', guest)}');
        }
        // Sever once, a few folds in — early enough that plenty of match is left
        // to play on the fallback.
        if (!severed && host.lastSeq >= 4) {
          severed = true;
          channels.first.sever();
        }
        if (severed && !hostTransport.listenerLive) polledWhileDown = true;
        _act(host, lastActed);
        _act(guest, lastActed);
        _expectConverged(host, guest);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(severed, isTrue, reason: 'the listener was never dropped');
      expect(polledWhileDown, isTrue,
          reason: 'the drop was never observed — nothing was proven');
      expect(host.error, isNull);
      expect(guest.error, isNull);
      expect(host.frozen, isFalse, reason: 'a dropped stream is not a cheat');
      expect(host.match.winner, isNotNull);
      expect(host.match.winner, guest.match.winner);
      expect(host.match.whiteScore, guest.match.whiteScore);
      expect(_expectConverged(host, guest), 1,
          reason: 'the two clients did not finish at the same fold depth');
      // Exactly-once survived the round trip: the fold is seq-CONTIGUOUS by
      // construction, so a duplicate or a gap would have stalled or frozen it —
      // finishing at the same seq is the proof.
      expect(host.lastSeq, guest.lastSeq);
      await waitFor(() => hostTransport.listenerLive,
          reason: 'the listener never recovered');
    },
    timeout: const Timeout(Duration(minutes: 25)),
    skip: _useListeners
        ? skipReason
        : (skipReason ??
            'AIGAMMON_E2E_LISTEN=0 — there is no listener to drop.'),
  );

  // =========================================================================
  group('adversarial', () {
    test(
      'direct-write forgeries are refused by the rules and the honest clients '
      'play on',
      () async {
        final m = await newMatch(length: 1);
        final code = m.doc.code;
        await seedOpening(m.host, m.guest, code, whiteDie: 6, blackDie: 3);

        final host = controllerFor(m.host, m.doc);
        final guest = controllerFor(m.guest, m.doc);
        await host.playMatch();
        await guest.playMatch();
        await host.ready;
        await guest.ready;

        // Every forgery below bypasses MatchApi and writes documents straight
        // at Firestore, exactly as a hacked client would.
        final docs = m.guest.api.docs;

        // 1. An event authored as the OPPONENT.
        await expectLater(
          docs.create('matches/$code/events/00000500', {
            'seq': 500,
            'gameNo': 1,
            'event': '{"type":"double","player":"white"}',
            'author': m.host.uid,
          }),
          throwsA(isA<PermissionDeniedException>()),
          reason: 'the rules must pin author to the writer',
        );

        // 2. Rewriting an event that is already in the log.
        await expectLater(
          docs.patch('matches/$code/events/00000000', {'gameNo': 9},
              updateMask: const ['gameNo']),
          throwsA(isA<PermissionDeniedException>()),
          reason: 'the event log is append-only',
        );

        // 3a. Rewriting a roll that has already completed (the seeded opening).
        await expectLater(
          docs.patch('matches/$code/rolls/00000001', {'reveal': 'c' * 64},
              updateMask: const ['reveal']),
          throwsA(isA<PermissionDeniedException>()),
          reason: 'a completed roll is immutable',
        );

        // 3b. Roll PHASE SKIPS, in a second match of the same two users.
        //
        //     Deliberately not in the live one: the honest controllers witness
        //     every roll they see, so a fresh commitment there would race their
        //     entropy — and once entropy lands, a reveal is legal. The forgery
        //     under test is the reveal that comes BEFORE any entropy, so it
        //     needs a document no honest client is watching.
        final second = await m.host.api.createMatch(length: 1, cubeless: false);
        final quiet = (await m.guest.api.joinMatch(second.code)).code;
        await docs.create('matches/$quiet/rolls/00000000',
            {'n': 0, 'roller': m.guest.uid, 'commit': 'a' * 64});
        await expectLater(
          docs.patch('matches/$quiet/rolls/00000000', {'reveal': 'b' * 64},
              updateMask: const ['reveal']),
          throwsA(isA<PermissionDeniedException>()),
          reason: 'revealing before entropy would let the roller pick the dice',
        );
        await expectLater(
          docs.patch('matches/$quiet/rolls/00000000', {'entropy': 'b' * 64},
              updateMask: const ['entropy']),
          throwsA(isA<PermissionDeniedException>()),
          reason: 'the roller may not supply its own entropy',
        );

        // 4. Tampering with the match document itself.
        for (final tamper in <Map<String, Object?>>[
          {'length': 25},
          {'hostUid': m.guest.uid},
          {'cubeless': true},
          {'status': 'waiting'},
        ]) {
          await expectLater(
            docs.patch('matches/$code', tamper,
                updateMask: tamper.keys.toList()),
            throwsA(isA<PermissionDeniedException>()),
            reason: 'match fields are immutable after creation ($tamper)',
          );
        }

        // Nothing landed.
        final after = await m.host.api.fetchMatch(code);
        expect(after.length, m.doc.length);
        expect(after.hostUid, m.host.uid);
        expect(after.cubeless, m.doc.cubeless);
        expect(after.status, 'active');
        final log = await m.host.api.fetchEventsSince(code, -1);
        expect(log.every((e) => e.gameNo == 1), isTrue);
        expect(log.first.event, isA<OpeningRollEvent>());

        // And the honest pair carries on: several more exchanges, converging
        // after each one, with no freeze and no lingering error.
        final target = host.game.events.length + 8;
        final lastActed = <NetMatchController, GameState?>{};
        final deadline = DateTime.now().add(const Duration(minutes: 3));
        while (host.game.events.length < target ||
            guest.game.events.length < target) {
          expect(host.frozen, isFalse, reason: 'the host froze: ${host.cheatError}');
          expect(guest.frozen, isFalse,
              reason: 'the guest froze: ${guest.cheatError}');
          if (DateTime.now().isAfter(deadline)) {
            fail('the honest pair stalled after the forgeries.\n'
                '${_diag('host', host)}\n${_diag('guest', guest)}');
          }
          _act(host, lastActed);
          _act(guest, lastActed);
          _expectConverged(host, guest);
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        _expectConverged(host, guest);
        expect(host.cheatError, isNull);
        expect(guest.cheatError, isNull);
      },
      timeout: const Timeout(Duration(minutes: 6)),
      skip: skipReason,
    );

    test(
      'a rules-passing but ILLEGAL opponent event freezes the honest client',
      () async {
        final m = await newMatch(length: 1);
        final code = m.doc.code;
        // White (the host, our honest client) is on move.
        await seedOpening(m.host, m.guest, code, whiteDie: 6, blackDie: 3);

        final host = controllerFor(m.host, m.doc);
        await host.playMatch();
        await host.ready;
        expect(host.state.turn, Player.white);
        final foldedBefore = host.game.events.length;

        // A perfectly well-formed event: right author, right seat, right shape
        // — and completely illegal, because it is white's move and black has no
        // dice. Nothing in firestore.rules can catch this; only the rules
        // engine on the honest peer can. (Document seq 1 = contract seq 2.)
        await m.guest.api.submitEvent(
          code: code,
          seq: 1,
          gameNo: 1,
          event: MoveEvent(
              Player.black, Move([const CheckerMove(13, 10)])),
        );

        await waitFor(() => host.frozen,
            reason: 'the host never froze on an illegal opponent event');
        final cheat = host.cheatError!;
        expect(cheat.code, 'illegal-event');
        expect(cheat.message, contains('frozen'));
        expect(host.error, same(cheat),
            reason: 'a freeze outranks any transient error');
        expect(host.isThinking, isFalse);
        expect(host.awaitingHumanTurn, isFalse);
        expect(host.game.events.length, foldedBefore,
            reason: 'the illegal event must not have folded');

        // A frozen controller never folds again, however much the cheat writes.
        await m.guest.api.submitEvent(
          code: code,
          seq: 2,
          gameNo: 1,
          event: MoveEvent(Player.black, Move([const CheckerMove(24, 21)])),
        );
        await Future<void>.delayed(_pollInterval * 4);
        expect(host.game.events.length, foldedBefore);
        expect(host.cheatError, same(cheat),
            reason: 'the original violation must be the one reported');
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: skipReason,
    );

    test(
      'a DOUBLE in a cubeless match freezes the honest client',
      () async {
        // The cube option travels in the match document, and `firestore.rules`
        // has no idea what a cube is — so a peer that ignores `cubeless: true`
        // writes a perfectly well-formed, correctly-authored DoubleEvent that
        // the rules accept. Only the honest peer, which knows the match config,
        // can refuse it. (New in the unified controller: `cube-in-cubeless`.)
        final m = await newMatch(length: 1, cubeless: true);
        final code = m.doc.code;
        await seedOpening(m.host, m.guest, code, whiteDie: 3, blackDie: 6);

        final host = controllerFor(m.host, m.doc);
        await host.playMatch();
        await host.ready;
        expect(host.cubeless, isTrue);
        expect(host.state.turn, Player.black, reason: 'a 3-6 opening is black\'s');
        final foldedBefore = host.game.events.length;

        await m.guest.api.submitEvent(
          code: code,
          seq: 1,
          gameNo: 1,
          event: DoubleEvent(Player.black),
        );

        await waitFor(() => host.frozen,
            reason: 'the host never froze on a cube offer in a cubeless match');
        expect(host.cheatError!.code, 'cube-in-cubeless');
        expect(host.game.events.length, foldedBefore,
            reason: 'the cube event must not have folded');
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: skipReason,
    );

    test(
      'a reveal that does not hash to its commitment freezes the witness',
      () async {
        final m = await newMatch(length: 1);
        final code = m.doc.code;
        // BLACK opens, so once the guest has moved the next roll is genuinely
        // WHITE's — the honest witness only answers the roll that is actually
        // due (see the lookahead leg below), so the scripted host has to be on
        // turn for its commitment to be witnessed at all.
        await seedOpening(m.host, m.guest, code, whiteDie: 3, blackDie: 6);

        // Only the guest runs a controller; the "host" is scripted by hand.
        final guest = controllerFor(m.guest, m.doc);
        await guest.playMatch();
        await guest.ready;
        expect(guest.state.turn, Player.black);
        guest.submitMove(Player.black, guest.state.legalMoves.first);
        await waitFor(() => guest.isReady && guest.state.turn == Player.white,
            reason: 'the guest never handed the turn over');

        // Phase 1 — a sound-looking commitment for the next roll.
        final secret = generateSecretHex();
        final swapped = generateSecretHex();
        expect(swapped, isNot(secret));
        await m.host.api.createRoll(code: code, n: 2, commit: commitFor(secret));

        // Phase 2 — the honest witness answers with entropy all by itself.
        await readUntil(
          () => m.host.api.fetchRoll(code, 2),
          (d) => d?.entropy != null,
          reason: 'the guest controller never contributed entropy',
        );

        // Phase 3 — reveal a DIFFERENT secret. The rules cannot hash, so this
        // write is accepted; only the witness can catch it.
        await m.host.api.submitReveal(code: code, n: 2, reveal: swapped);

        await waitFor(() => guest.frozen,
            reason: 'the guest never froze on a tampered reveal');
        final cheat = guest.cheatError!;
        expect(cheat.code, 'fair-dice');
        expect(cheat.message, contains('frozen'));
        expect(cheat.message, contains('tampered dice'));
        expect(guest.isThinking, isFalse);
        expect(guest.awaitingHumanTurn, isFalse);
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: skipReason,
    );

    test(
      'a peer that squats its FUTURE roll documents gets no entropy for them',
      () async {
        // The dice-lookahead break. Turn parity is predictable, so a hostile
        // client can pre-create the roll documents for its own coming turns; if
        // the honest witness answers them it can reveal to itself and know
        // several of its future rolls before choosing a move or a double. The
        // dice stay unbiased and nothing ever folds illegally, so no freeze and
        // no rules violation catches it — only the honest client's refusal to
        // answer anything but the DUE roll.
        final m = await newMatch(length: 1);
        final code = m.doc.code;
        // Black (the guest, our honest client) is on move first.
        await seedOpening(m.host, m.guest, code, whiteDie: 3, blackDie: 6);

        final guest = controllerFor(m.guest, m.doc);
        await guest.playMatch();
        await guest.ready;
        expect(guest.state.turn, Player.black);

        // The squat: white's next roll (2) plus two it has no business
        // preparing, all correctly shaped and correctly authored.
        final secrets = {
          for (final n in [2, 4, 6]) n: generateSecretHex(),
        };
        for (final entry in secrets.entries) {
          await m.host.api.createRoll(
              code: code, n: entry.key, commit: commitFor(entry.value));
        }

        // Give the honest client several poll cycles to answer them.
        await Future<void>.delayed(_pollInterval * 6);
        for (final n in [2, 4, 6]) {
          expect((await m.guest.api.fetchRoll(code, n))?.entropy, isNull,
              reason: 'roll $n is not due — it must not be witnessed while it '
                  'is still black to move');
        }

        // Hand white the turn. Roll 2 is now genuinely due, and is the ONLY one
        // that may be answered — proving the binding is to the due index, not a
        // blanket refusal that would deadlock the match.
        guest.submitMove(Player.black, guest.state.legalMoves.first);
        await readUntil(
          () => m.host.api.fetchRoll(code, 2),
          (d) => d?.entropy != null,
          reason: 'the DUE roll must still be witnessed — no deadlock',
        );
        for (final n in [4, 6]) {
          expect((await m.guest.api.fetchRoll(code, n))?.entropy, isNull,
              reason: 'roll $n is still two turns ahead');
        }
        expect(guest.frozen, isFalse, reason: 'squatting is refused, not fatal');
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: skipReason,
    );
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// One decision for [c], de-duplicated by [GameState] identity so a submission
/// that has not been echoed back by the poll yet is never re-issued.
///
/// Deliberately dumb: first legal move, always take, always accept. The point
/// of the test is the transport and the protocol, not the play.
void _act(NetMatchController c, Map<NetMatchController, GameState?> lastActed) {
  if (c.matchOver || c.frozen) return;
  if (c.awaitingNextGame) {
    c.continueToNextGame();
    lastActed[c] = null;
    return;
  }
  if (!c.isReady) return;
  final GameState s;
  try {
    s = c.state;
  } on StateError {
    return;
  }
  if (identical(s, lastActed[c])) return;
  final side = c.localSide;
  if (c.pendingCubeOf(side).value != null) {
    c.submitCubeResponse(side, CubeAction.take);
  } else if (c.pendingResignOf(side).value != null) {
    c.submitResignResponse(side, true);
  } else if (c.pendingMoveOf(side).value != null) {
    final legal = s.legalMoves;
    c.submitMove(side, legal.isEmpty ? Move.none : legal.first);
  } else if (c.awaitingHumanTurn) {
    c.rollDice();
  }
  lastActed[c] = s;
}

/// The two clients' derived state, or null while a client has not folded a game
/// yet.
///
/// The FIRST field is the fold depth (game number + folded event count): two
/// clients at the same depth have folded exactly the same prefix of the same
/// log, so everything after it — board, turn, phase, dice, cube, scores — must
/// be identical. At different depths one is simply a poll behind the other.
String? _signature(NetMatchController c) {
  if (!c.isReady) return null;
  final GameState s;
  final Game g;
  try {
    g = c.game;
    s = g.state;
  } on StateError {
    return null;
  }
  final b = s.board;
  final dice = s.dice;
  return [
    'g${c.gameNumber}/e${g.events.length}',
    '${c.match.whiteScore}-${c.match.blackScore}',
    s.phase.name,
    s.turn.name,
    'cube${s.cube.value}@${s.cube.owner?.name ?? '-'}',
    'dice${dice == null ? '-' : '${dice.die1}${dice.die2}'}',
    b.points.join(','),
    '${b.whiteBar}/${b.blackBar}/${b.whiteOff}/${b.blackOff}',
    'crawford${s.isCrawfordGame}',
  ].join('|');
}

/// Compares the two clients when they are at the same fold depth. Returns 1 if
/// a comparison happened, 0 if they were not comparable at this instant.
int _expectConverged(NetMatchController a, NetMatchController b) {
  final sa = _signature(a);
  final sb = _signature(b);
  if (sa == null || sb == null) return 0;
  if (sa.split('|').first != sb.split('|').first) return 0;
  expect(sa, sb,
      reason: 'the two clients derived different state from the same log '
          'prefix');
  return 1;
}

String _diag(String label, NetMatchController c) {
  final buf = StringBuffer('$label: matchOver=${c.matchOver} '
      'awaitingNextGame=${c.awaitingNextGame} '
      'awaitingHumanTurn=${c.awaitingHumanTurn} isReady=${c.isReady} '
      'frozen=${c.frozen} error=${c.error}');
  final sig = _signature(c);
  if (sig != null) buf.write(' state=$sig');
  return buf.toString();
}

/// A real [FirestoreListenChannel] with a cut-out: [sever] fails the stream the
/// way a lost connection would, leaving the emulator untouched.
class _BreakableChannel implements FirestoreListenChannel {
  _BreakableChannel(this.inner);

  final FirestoreListenChannel inner;
  StreamController<ListenDelta>? _out;
  StreamSubscription<ListenDelta>? _sub;

  @override
  Stream<ListenDelta> listen(List<ListenTarget> targets) {
    final out = _out = StreamController<ListenDelta>();
    _sub = inner.listen(targets).listen(
          out.add,
          onError: out.addError,
          onDone: out.close,
        );
    return out.stream;
  }

  void sever() => _out?.addError('the connection dropped');

  @override
  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    await _out?.close();
    _out = null;
    await inner.close();
  }
}
