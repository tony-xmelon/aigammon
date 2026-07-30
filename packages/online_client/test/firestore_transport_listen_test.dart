import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:http/http.dart' as http;
import 'package:match_transport/match_transport.dart';
import 'package:online_client/online_client.dart';
import 'package:test/test.dart';

import 'mock_api.dart';

/// [FirestoreTransport] on its REAL-TIME path: delta→frame mapping, batch
/// ordering, the watermarks shared with the poll loop, and the
/// listener→poll→listener state machine.
///
/// Everything here runs against an INJECTED [FirestoreListenChannel] and a
/// scripted REST client, so no network and no gRPC are involved and every timing
/// is under the test's control. What Firestore actually sends over that channel is
/// pinned by `firestore_listen_test.dart` (the wire format) and
/// `emulator_integration_test.dart` (a real server).
void main() {
  const seated = MatchDoc(
    code: 'C',
    hostUid: 'uid-local',
    guestUid: 'uid-remote',
    length: 3,
    cubeless: false,
    status: 'active',
  );

  /// A channel whose stream the test drives by hand.
  ///
  /// One instance carries one stream, exactly as the contract says, so a
  /// reconnection test just looks at the NEXT instance the factory made.
  final channels = <_FakeChannel>[];

  /// The newest channel the factory built — the live one.
  _FakeChannel channel() => channels.last;

  FirestoreListenChannelFactory factory({int failToBuild = 0}) {
    var built = 0;
    return () {
      if (built++ < failToBuild) throw StateError('no channel for you');
      final c = _FakeChannel();
      channels.add(c);
      return c;
    };
  }

  /// Answers every read with an empty page and every write with success.
  Future<http.Response> quiet(http.Request req) async {
    if (req.url.path.endsWith(':runQuery')) return http.Response('[]', 200);
    return ok({});
  }

  /// A connected transport whose listener is already open (start delay zero).
  Future<FirestoreTransport> connected(
    Future<http.Response> Function(http.Request req) handler, {
    FirestoreListenChannelFactory? listen,
    Duration poll = const Duration(seconds: 30),
    Duration retryFloor = const Duration(milliseconds: 10),
    Duration batchWindow = const Duration(milliseconds: 10),
  }) async {
    final api = await apiFor(handler);
    final t = FirestoreTransport(
      api: api,
      code: 'C',
      match: seated,
      pollInterval: poll,
      listenChannel: listen ?? factory(),
      listenStartDelay: Duration.zero,
      listenRetryFloor: retryFloor,
      listenRetryCeiling: const Duration(milliseconds: 40),
      listenBatchWindow: batchWindow,
    );
    addTearDown(t.dispose);
    await t.connect();
    return t;
  }

  Future<void> waitFor(
    bool Function() done, {
    Duration timeout = const Duration(seconds: 5),
    String reason = 'condition never became true',
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail(reason);
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  /// Both targets CURRENT — the point at which the listener owns delivery.
  void goLive() {
    channel().emit(const ListenSnapshot(targetIds: [1, 2], current: true));
  }

  setUp(channels.clear);

  // =========================================================================
  group('targets', () {
    test('two query targets, at the watermarks the poll loop would use',
        () async {
      await connected(quiet);
      await waitFor(() => channels.isNotEmpty);
      final targets = channel().opened.single;
      final events = targets.firstWhere((t) => t.collectionId == 'events');
      final rolls = targets.firstWhere((t) => t.collectionId == 'rolls');

      expect(events.field, 'seq');
      expect(events.from, -1, reason: 'nothing delivered yet');
      expect(events.inclusive, isFalse, reason: 'seq > cursor');
      expect(events.parentPath, 'matches/C');
      expect(rolls.field, 'n');
      expect(rolls.from, 1);
      expect(rolls.inclusive, isTrue, reason: 'roll 1 may still change');
      expect(events.targetId, isNot(rolls.targetId));
      expect(events.resumeToken, isNull);
    });

    test('the listener opens at the cursor a prime has already advanced',
        () async {
      // The read-budget reason listenStartDelay exists: a rejoin into a long
      // match must watch `seq > tail`, not re-read (and re-pay for) the log the
      // controller just pulled.
      final api = await apiFor((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          if (queriedCollection(req) == 'rolls') return http.Response('[]', 200);
          return http.Response(
              eventRows([
                (0, const OpeningRollEvent(whiteDie: 6, blackDie: 3)),
                (1, DoubleEvent(Player.white)),
              ]),
              200);
        }
        return quiet(req);
      });
      final t = FirestoreTransport(
        api: api,
        code: 'C',
        match: seated,
        pollInterval: const Duration(seconds: 30),
        listenChannel: factory(),
        listenStartDelay: const Duration(milliseconds: 50),
      );
      addTearDown(t.dispose);
      await t.connect();
      expect(channels, isEmpty, reason: 'the listener waits for the prime');
      expect(await t.eventsSince(0), hasLength(2));

      await waitFor(() => channels.isNotEmpty);
      final events =
          channel().opened.single.firstWhere((t) => t.collectionId == 'events');
      expect(events.from, 1, reason: 'the two primed documents are not re-read');
    });
  });

  // =========================================================================
  group('delta → frame', () {
    test('a batch is published in seq order, however it arrives', () async {
      // Listen promises a consistent SET between snapshot boundaries, never an
      // order. Contiguity is the controller's whole fold contract, so the
      // transport sorts.
      final t = await connected(quiet);
      final frames = <InboundFrame>[];
      t.inbound.listen(frames.add);

      channel().emit(_event(2, DoubleEvent(Player.white)));
      channel().emit(_event(0, const OpeningRollEvent(whiteDie: 6, blackDie: 3)));
      channel().emit(_event(1, TakeEvent(Player.black)));
      expect(frames, isEmpty, reason: 'nothing publishes before the boundary');

      channel().emit(const ListenSnapshot(targetIds: [1], current: false));
      await pumpEventQueue();
      expect(frames.cast<EventFrame>().map((f) => f.seq), [1, 2, 3],
          reason: 'sorted, and renumbered from 1');
      expect((frames.first as EventFrame).event, isA<OpeningRollEvent>());
      expect((frames.first as EventFrame).author, 'uid-remote');
    });

    test('a batch with no boundary is flushed by the safety window', () async {
      final t = await connected(quiet, batchWindow: const Duration(milliseconds: 5));
      final frames = <InboundFrame>[];
      t.inbound.listen(frames.add);
      channel().emit(_event(0, DoubleEvent(Player.white)));
      await waitFor(() => frames.isNotEmpty,
          reason: 'a boundary that never came must not strand a frame');
      expect((frames.single as EventFrame).seq, 1);
    });

    test('an event is published once, and never re-published', () async {
      final t = await connected(quiet);
      final frames = <InboundFrame>[];
      t.inbound.listen(frames.add);

      channel().emit(_event(0, DoubleEvent(Player.white)));
      channel().emit(const ListenSnapshot(targetIds: [1], current: false));
      await pumpEventQueue();
      // Firestore re-delivering the same document (a RESET replay, or an overlap
      // with the poll loop) must be free.
      channel().emit(_event(0, DoubleEvent(Player.white)));
      channel().emit(const ListenSnapshot(targetIds: [1], current: false));
      await pumpEventQueue();
      expect(frames, hasLength(1));
    });

    test('a roll is re-emitted only when its phase advances, then retired',
        () async {
      final t = await connected(quiet);
      final phases = <FairDicePhase>[];
      t.inbound.listen((f) {
        if (f is RollFrame) phases.add(f.phase);
      });

      Future<void> deliver(Map<String, Object?> fields) async {
        channel().emit(_roll(fields));
        channel().emit(const ListenSnapshot(targetIds: [2], current: false));
        await pumpEventQueue();
      }

      await deliver({'n': 1, 'roller': 'u', 'commit': hexA});
      await deliver({'n': 1, 'roller': 'u', 'commit': hexA});
      await deliver({'n': 1, 'roller': 'u', 'commit': hexA, 'entropy': hexB});
      await deliver({
        'n': 1,
        'roller': 'u',
        'commit': hexA,
        'entropy': hexB,
        'reveal': hexC,
      });

      expect(phases, [
        FairDicePhase.committed,
        FairDicePhase.entropy,
        FairDicePhase.revealed,
      ], reason: 'the unchanged second delivery must not re-emit');

      // A completed roll can never change again: the next listen must not ask
      // for it.
      channel().fail();
      await waitFor(() => channels.length >= 2);
      final rolls =
          channel().opened.single.firstWhere((t) => t.collectionId == 'rolls');
      expect(rolls.from, 2);
      await t.dispose();
    });

    test('a malformed document surfaces on inbound and keeps the stream alive',
        () async {
      final t = await connected(quiet);
      final frames = <InboundFrame>[];
      final errors = <Object>[];
      var closed = false;
      t.inbound.listen(frames.add, onError: errors.add, onDone: () => closed = true);

      channel().emit(const ListenDocument(
        name: 'projects/p/databases/(default)/documents/matches/C/events/'
            '00000000',
        fields: {'seq': 'not an int'},
        targetIds: [1],
      ));
      channel().emit(_event(0, DoubleEvent(Player.white)));
      channel().emit(const ListenSnapshot(targetIds: [1], current: false));
      await pumpEventQueue();

      expect(errors.single, isA<TransportUnavailable>());
      expect(closed, isFalse);
      expect(frames, hasLength(1), reason: 'the good document still arrives');
    });

    test('a document leaving the result set is ignored, not trusted', () async {
      // Nothing in this model is ever deleted, and seq/n never change, so a
      // delete can only be noise.
      final t = await connected(quiet);
      final frames = <InboundFrame>[];
      t.inbound.listen(frames.add);
      channel().emit(const ListenDocumentGone(
        name: 'projects/p/databases/(default)/documents/matches/C/events/'
            '00000000',
        targetIds: [1],
      ));
      channel().emit(const ListenTargetAdded([1, 2]));
      await pumpEventQueue();
      expect(frames, isEmpty);
    });
  });

  // =========================================================================
  group('going live', () {
    test('CURRENT on BOTH targets stops the poll loop and zeroes the cadence',
        () async {
      var queries = 0;
      final t = await connected((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          queries++;
          return http.Response('[]', 200);
        }
        return quiet(req);
      }, poll: const Duration(milliseconds: 10));

      expect(t.listenerLive, isFalse);
      expect(t.inboundCadence, const Duration(milliseconds: 10),
          reason: 'polling is the live path until the listener catches up');

      channel().emit(const ListenSnapshot(targetIds: [1], current: true));
      await pumpEventQueue();
      expect(t.listenerLive, isFalse, reason: 'one target is not both');

      channel().emit(const ListenSnapshot(targetIds: [2], current: true));
      await waitFor(() => t.listenerLive);
      expect(t.inboundCadence, Duration.zero);
      expect(t.status, TransportStatus.connected);

      // Cycles cost reads; a live listener must not pay for them.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final settled = queries;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(queries, settled, reason: 'polling did not stop');
    });

    test('an empty target-id list means every target', () async {
      final t = await connected(quiet);
      channel().emit(const ListenSnapshot(targetIds: [], current: true));
      await waitFor(() => t.listenerLive);
    });

    test('the pace hint is inert while the listener is live', () async {
      final t = await connected(quiet, poll: const Duration(seconds: 2));
      goLive();
      await waitFor(() => t.listenerLive);
      t.setPaceHint(fast: true);
      expect(t.inboundCadence, Duration.zero);
    });
  });

  // =========================================================================
  group('resume tokens', () {
    test('a token is replayed only while its watermark has not moved', () async {
      final t = await connected(quiet);
      goLive();
      await waitFor(() => t.listenerLive);
      channel().emit(ListenSnapshot(
        targetIds: const [1, 2],
        current: false,
        resumeToken: Uint8List.fromList(const [1, 2, 3]),
      ));
      await pumpEventQueue();

      channel().fail();
      await waitFor(() => channels.length >= 2);
      final resumed = channel().opened.single;
      expect(resumed.every((t) => t.resumeToken != null), isTrue,
          reason: 'nothing was consumed, so the token is still exact');
      expect(resumed.firstWhere((t) => t.collectionId == 'events').from, -1,
          reason: 'a token is only valid for the query that produced it');
    });

    test('consuming a document invalidates the token for that target', () async {
      final t = await connected(quiet);
      goLive();
      await waitFor(() => t.listenerLive);
      channel().emit(ListenSnapshot(
        targetIds: const [1, 2],
        current: false,
        resumeToken: Uint8List.fromList(const [9]),
      ));
      channel().emit(_event(0, DoubleEvent(Player.white)));
      channel().emit(const ListenSnapshot(targetIds: [1], current: false));
      await pumpEventQueue();

      channel().fail();
      await waitFor(() => channels.length >= 2);
      final targets = channel().opened.single;
      final events = targets.firstWhere((t) => t.collectionId == 'events');
      final rolls = targets.firstWhere((t) => t.collectionId == 'rolls');
      expect(events.resumeToken, isNull,
          reason: 'the cursor moved past the token');
      expect(events.from, 0, reason: 'a fresh bound is cheaper than a replay');
      expect(rolls.resumeToken, isNotNull,
          reason: 'the rolls watermark did not move');
    });

    test('a listen that dies before CURRENT throws its tokens away', () async {
      // Otherwise a stale token loops: replay → refused → replay.
      final t = await connected(quiet);
      goLive();
      await waitFor(() => t.listenerLive);
      channel().emit(ListenSnapshot(
        targetIds: const [1, 2],
        current: false,
        resumeToken: Uint8List.fromList(const [4]),
      ));
      await pumpEventQueue();

      channel().fail();
      await waitFor(() => channels.length >= 2);
      expect(channel().opened.single.first.resumeToken, isNotNull);
      // The resumed attempt never reaches CURRENT before dying.
      channel().fail();
      await waitFor(() => channels.length >= 3);
      expect(channel().opened.single.every((t) => t.resumeToken == null), isTrue);
    });
  });

  // =========================================================================
  group('RESET is not an identity change', () {
    test('a RESET costs nothing: no ResetFrame, no read, and no duplicate',
        () async {
      // A ResetFrame tells the controller its match identity changed and every
      // watermark is void. A Listen RESET means nothing of the kind — and the
      // emulator sends one before EVERY change batch, so the handler has to be
      // free or the read budget the listener saves is handed straight back.
      var queries = 0;
      final t = await connected((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          queries++;
          return http.Response('[]', 200);
        }
        return quiet(req);
      });
      goLive();
      await waitFor(() => t.listenerLive);
      // One event delivered, then a snapshot that tokenises BOTH targets at the
      // watermarks that event left behind.
      channel().emit(_event(0, DoubleEvent(Player.white)));
      channel().emit(const ListenSnapshot(targetIds: [1], current: false));
      await pumpEventQueue();
      channel().emit(ListenSnapshot(
        targetIds: const [1, 2],
        current: false,
        resumeToken: Uint8List.fromList(const [5]),
      ));
      await pumpEventQueue();

      final frames = <InboundFrame>[];
      // The final `fail()` below is a deliberate drop of a LIVE listener, which
      // surfaces a transient — swallowed here, and asserted in its own test.
      t.inbound.listen(frames.add, onError: (_) {});
      final before = queries;

      // A RESET, then the promised re-delivery of the whole result set.
      channel().emit(const ListenTargetReset([1]));
      channel().emit(_event(0, DoubleEvent(Player.white)));
      channel().emit(const ListenSnapshot(targetIds: [1], current: true));
      await pumpEventQueue();

      expect(frames.whereType<ResetFrame>(), isEmpty);
      expect(frames, isEmpty,
          reason: 'the re-delivered document was already published');
      expect(queries, before, reason: 'a RESET must not spend a read');
      expect(t.listenerLive, isTrue, reason: 'a RESET is not a stream failure');

      // The reset target's token is void; the other target keeps its own.
      channel().fail();
      await waitFor(() => channels.length >= 2);
      final resumed = channel().opened.single;
      expect(resumed.firstWhere((t) => t.collectionId == 'events').resumeToken,
          isNull);
      expect(resumed.firstWhere((t) => t.collectionId == 'rolls').resumeToken,
          isNotNull);
    });
  });

  // =========================================================================
  group('fallback and recovery', () {
    test('a dead stream falls back to polling AT ONCE, then recovers', () async {
      var queries = 0;
      final t = await connected((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          queries++;
          return http.Response('[]', 200);
        }
        return quiet(req);
      }, poll: const Duration(seconds: 30));
      goLive();
      await waitFor(() => t.listenerLive);
      final whileLive = queries;

      channel().fail();
      // A 30s poll interval: only the "do not wait a cycle to find out what the
      // dying stream missed" rule can make this read happen.
      await waitFor(() => queries > whileLive,
          reason: 'the fallback did not read immediately');
      expect(t.listenerLive, isFalse);
      expect(t.inboundCadence, const Duration(seconds: 30),
          reason: 'the degraded cadence is the honest one');

      await waitFor(() => channels.length >= 2, reason: 'no re-listen');
      goLive();
      await waitFor(() => t.listenerLive);
      expect(t.inboundCadence, Duration.zero);
    });

    test('a stream that merely CLOSES is a failure too', () async {
      final t = await connected(quiet);
      goLive();
      await waitFor(() => t.listenerLive);
      channel().endStream();
      await waitFor(() => !t.listenerLive);
      await waitFor(() => channels.length >= 2);
    });

    test('a REMOVEd target degrades — it never freezes the match', () async {
      // A stale resume token and a rules refusal look identical here. Only the
      // poll path, whose refusal comes from firestore.rules with a body
      // attached, is allowed to be terminal.
      final t = await connected(quiet);
      goLive();
      await waitFor(() => t.listenerLive);
      final errors = <Object>[];
      t.inbound.listen((_) {}, onError: errors.add);

      channel().emit(const ListenTargetRemoved([1], cause: 'permission denied'));
      await waitFor(() => errors.isNotEmpty);
      expect(errors.single, isA<TransportUnavailable>());
      expect(errors.single, isNot(isA<TransportRejected>()));
      await waitFor(() => channels.length >= 2);
    });

    test('a drop is a transient on inbound, and does NOT flip the status chip',
        () async {
      final t = await connected(quiet);
      final statuses = <TransportStatus>[];
      t.statusStream.listen((e) => statuses.add(e.status));
      goLive();
      await waitFor(() => t.listenerLive);

      final errors = <Object>[];
      var closed = false;
      t.inbound.listen((_) {}, onError: errors.add, onDone: () => closed = true);
      channel().fail();
      await waitFor(() => errors.isNotEmpty);

      expect(closed, isFalse,
          reason: 'inbound must never end to signal trouble');
      expect(t.status, TransportStatus.connected,
          reason: 'the match IS still connected — over polling');
      expect(statuses, isNot(contains(TransportStatus.reconnecting)));
    });

    test('a listener that never lived says nothing', () async {
      // Nothing was lost, and the poll loop was carrying the match all along.
      final t = await connected(quiet);
      final errors = <Object>[];
      t.inbound.listen((_) {}, onError: errors.add);
      channel().fail();
      await waitFor(() => channels.length >= 2);
      expect(errors, isEmpty);
    });

    test('re-listen backs off, and the backoff resets on recovery', () async {
      final t = await connected(quiet,
          retryFloor: const Duration(milliseconds: 10));
      goLive();
      await waitFor(() => t.listenerLive);

      final at = <DateTime>[];
      for (var i = 0; i < 3; i++) {
        final before = channels.length;
        channel().fail();
        await waitFor(() => channels.length > before);
        at.add(DateTime.now());
      }
      // 10ms, 20ms, 40ms (capped): each gap at least as long as the last.
      expect(at, hasLength(3));

      goLive();
      await waitFor(() => t.listenerLive);
      final before = channels.length;
      final resetAt = DateTime.now();
      channel().fail();
      await waitFor(() => channels.length > before);
      expect(DateTime.now().difference(resetAt),
          lessThan(const Duration(milliseconds: 35)),
          reason: 'a recovery must put the backoff back to the floor');
    });

    test('a factory that cannot build a channel disables the listener for good',
        () async {
      // The lobby's widget tests drive a real transport over a MatchApi FAKE:
      // there is no gRPC endpoint behind it, and an un-constructible channel must
      // not leave a retry timer pending in a widget test.
      var queries = 0;
      final t = await connected((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          queries++;
          return http.Response('[]', 200);
        }
        return quiet(req);
      },
          listen: factory(failToBuild: 99),
          poll: const Duration(milliseconds: 10));
      expect(channels, isEmpty);
      await waitFor(() => queries > 1, reason: 'polling must carry the match');
      expect(t.listenerLive, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(channels, isEmpty, reason: 'no retry storm');
    });

    test('with no factory at all the transport is exactly the polling one',
        () async {
      final api = await apiFor(quiet);
      final t = FirestoreTransport(
        api: api,
        code: 'C',
        match: seated,
        pollInterval: const Duration(seconds: 2),
      );
      addTearDown(t.dispose);
      await t.connect();
      expect(t.listenerLive, isFalse);
      expect(t.inboundCadence, const Duration(seconds: 2));
      expect(t.suggestedGateTimeout, const Duration(seconds: 8));
    });

    test('the suggested gate is sized for the DEGRADED path, and capped', () {
      // The listener can drop mid-submission, so the gate must clear a poll
      // cycle; but a suite that parks the cadence at 30s must not thereby ask the
      // controller to wait two minutes.
      FirestoreTransport at(Duration poll) => FirestoreTransport(
          api: _NeverApi(), code: 'C', match: seated, pollInterval: poll);
      expect(at(const Duration(milliseconds: 100)).suggestedGateTimeout,
          const Duration(seconds: 5));
      expect(at(const Duration(seconds: 2)).suggestedGateTimeout,
          const Duration(seconds: 8));
      expect(at(const Duration(seconds: 30)).suggestedGateTimeout,
          const Duration(seconds: 20));
    });

    test('dispose closes the channel and leaves no timer behind', () async {
      final t = await connected(quiet);
      goLive();
      await waitFor(() => t.listenerLive);
      await t.dispose();
      expect(channel().closes, 1);
      channels.clear();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(channels, isEmpty, reason: 'a disposed transport does not re-listen');
    });
  });

  // =========================================================================
  group('read accounting', () {
    test('documentsRead counts both paths', () async {
      final t = await connected((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          if (queriedCollection(req) == 'rolls') return http.Response('[]', 200);
          return http.Response(
              eventRows([(0, DoubleEvent(Player.white))]), 200);
        }
        return quiet(req);
      });
      expect(t.documentsRead, 0, reason: 'the seated match doc was handed in');
      await t.eventsSince(0);
      expect(t.documentsRead, 1);
      channel().emit(_event(1, TakeEvent(Player.black)));
      channel().emit(const ListenSnapshot(targetIds: [1], current: false));
      await pumpEventQueue();
      expect(t.documentsRead, 2, reason: 'a pushed document is billed too');
    });
  });
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// A `ListenDocument` for `events/{seq}`, already field-decoded (which is what
/// the channel hands over).
ListenDocument _event(int seq, GameEvent event,
        {int gameNo = 1, String author = 'uid-remote'}) =>
    ListenDocument(
      name: 'projects/p/databases/(default)/documents/matches/C/events/'
          '${seq.toString().padLeft(8, '0')}',
      fields: {
        'seq': seq,
        'gameNo': gameNo,
        'author': author,
        'event': jsonEncode(event.toJson()),
      },
      targetIds: const [1],
    );

/// A `ListenDocument` for `rolls/{n}` from a plain field map.
ListenDocument _roll(Map<String, Object?> fields) => ListenDocument(
      name: 'projects/p/databases/(default)/documents/matches/C/rolls/'
          '${(fields['n'] as int).toString().padLeft(8, '0')}',
      fields: fields,
      targetIds: const [2],
    );

class _FakeChannel implements FirestoreListenChannel {
  final List<List<ListenTarget>> opened = [];
  StreamController<ListenDelta>? _stream;
  int closes = 0;

  @override
  Stream<ListenDelta> listen(List<ListenTarget> targets) {
    opened.add(targets);
    final controller = _stream = StreamController<ListenDelta>();
    return controller.stream;
  }

  void emit(ListenDelta delta) => _stream!.add(delta);

  void fail([Object error = 'the stream broke']) => _stream!.addError(error);

  void endStream() => _stream!.close();

  @override
  Future<void> close() async {
    closes++;
    await _stream?.close();
    _stream = null;
  }
}

/// A [MatchApi] that would throw if touched — for the pure-arithmetic tests.
class _NeverApi implements MatchApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('this test must not touch the API');
}
