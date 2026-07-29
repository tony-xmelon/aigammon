import 'dart:convert';
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:lan_play/lan_play.dart';
import 'package:match_transport/match_transport.dart';
import 'package:test/test.dart';

import 'socket_harness.dart';

/// A hostile LAN peer must not be able to crash its opponent: [Envelope.decode]
/// is TOTAL (every input yields DecodeOk or DecodeFailure), and nothing a peer can
/// send moves the [MatchRelay] except a well-formed, correctly-ordered write.
///
/// ## What moved when the referee went away
///
/// The old version of this suite fuzzed `HostAuthority`, including a "deep
/// validation path" case that fed adversarial MOVES into `canonicalPlay`. There
/// is no such path here on purpose: the relay does not know the rules, so an
/// illegal move is not its business — it is written to the log and the opponent's
/// controller FREEZES on it (`app/test/net/net_cheat_freeze_test.dart` owns those
/// cases, on both transports). What this suite still owns is that a hostile frame
/// cannot make the relay throw, mis-order the log, or answer with anything
/// unbounded.
void main() {
  const cases = 200;

  /// Deterministic generator of nasty frames.
  String nasty(Random r) {
    switch (r.nextInt(8)) {
      case 0: // random bytes as latin-1 text
        return String.fromCharCodes(
            [for (var i = 0; i < r.nextInt(64); i++) r.nextInt(256)]);
      case 1: // a truncated valid frame
        final full = HelloMessage(name: 'peer${r.nextInt(99)}').encode();
        return full.substring(0, r.nextInt(full.length + 1));
      case 2: // deep nesting
        final depth = 1 + r.nextInt(2000);
        return '[' * depth + ']' * depth;
      case 3: // deep nesting inside a well-formed envelope
        final depth = 1 + r.nextInt(500);
        return '{"v":$protocolVersion,"type":"w_event","payload":{"event":'
            '${'[' * depth}${']' * depth}}}';
      case 4: // huge strings
        return jsonEncode({
          'v': protocolVersion,
          'type': 'hello',
          'payload': {'name': 'x' * (1 << r.nextInt(16))},
        });
      case 5: // right shape, wrong types everywhere
        final junk = <Object?>[null, 1, -1, 3.7, true, 'x', [], {}, 'white'];
        Object? pick() => junk[r.nextInt(junk.length)];
        return jsonEncode({
          'v': pick(),
          'type': pick(),
          'payload': {
            'id': pick(),
            'name': pick(),
            'side': pick(),
            'seq': pick(),
            'gameNo': pick(),
            'n': pick(),
            'commit': pick(),
            'status': pick(),
            'log': pick(),
            'rolls': pick(),
            'matchConfig': pick(),
            'event': {'type': pick(), 'player': pick(), 'move': pick()},
          },
        });
      case 6: // a plausible move event with nonsense hops
        return jsonEncode({
          'v': protocolVersion,
          'type': 'w_event',
          'payload': {
            'id': 1,
            'seq': 1 + r.nextInt(4),
            'gameNo': 1,
            'event': {
              'type': 'move',
              'player': r.nextBool() ? 'white' : 'black',
              'move': [
                for (var i = 0; i < r.nextInt(6); i++)
                  [
                    r.nextInt(200) - 100,
                    r.nextInt(200) - 100,
                    if (r.nextBool()) r.nextBool() else 'yes',
                  ],
              ],
            },
          },
        });
      default: // random unicode soup, sometimes JSON-ish
        final buf = StringBuffer(r.nextBool() ? '{"v":2,' : '');
        for (var i = 0; i < r.nextInt(80); i++) {
          buf.writeCharCode(r.nextInt(0x2000));
        }
        return buf.toString();
    }
  }

  test('decode is total over $cases hostile frames', () {
    final r = Random(20260726);
    var ok = 0;
    for (var i = 0; i < cases; i++) {
      final raw = nasty(r);
      final result = Envelope.decode(raw);
      switch (result) {
        case DecodeOk(:final envelope):
          ok++;
          // Anything that decodes must also re-encode and decode again.
          expect(Envelope.decode(envelope.encode()), isA<DecodeOk>());
        case DecodeFailure(:final error):
          expect(error.message, isNotEmpty);
      }
    }
    // The corpus is meant to be mostly-invalid; a few (case 4/6 with benign
    // values) do decode. Both branches must be exercised for the test to mean
    // anything.
    expect(ok, greaterThan(0), reason: 'corpus never produced a valid frame');
    expect(ok, lessThan(cases),
        reason: 'corpus never produced an invalid frame');
  });

  test('the relay survives $cases hostile frames over a real socket', () async {
    final f = await ServerFixture.start();
    addTearDown(f.dispose);
    seedOpening(f.relay, whiteDie: 6, blackDie: 1);
    final guest = await RawGuest.connect(f.server, autoPong: true);
    addTearDown(guest.close);
    guest.hello();
    await waitFor(() => guest.gotWelcome, what: 'a welcome');

    final r = Random(4242);
    for (var i = 0; i < cases; i++) {
      guest.sendRaw(nasty(r));
    }
    await settle(200);

    // Seq 1 is taken and every generated write claims 1..4 with no roll behind
    // it, so nothing in the corpus is BOTH decodable and correctly ordered
    // except an append at the next free seq — and even that only ever lands
    // once, because the seq then moves on.
    expect(f.relay.lastSeq, lessThanOrEqualTo(2),
        reason: 'a hostile burst cannot pump the log');
    expect(f.relay.events.map((e) => e.seq),
        [for (var i = 1; i <= f.relay.lastSeq; i++) i],
        reason: 'the log stayed contiguous');
    // Every answer is bounded: no welcome was replayed for a garbage frame, and
    // nothing large came back.
    expect(guest.of<WelcomeMessage>(), hasLength(1),
        reason: 'only the handshake replayed the log');
    for (final raw in guest.raw) {
      expect(raw.length, lessThan(4096),
          reason: 'a hostile frame drew an unbounded answer');
    }
  });

  test('an oversized frame is dropped without a large reply', () async {
    final f = await ServerFixture.start();
    addTearDown(f.dispose);
    final guest = await RawGuest.connect(f.server);
    addTearDown(guest.close);
    guest.hello();
    await waitFor(() => guest.gotWelcome, what: 'a welcome');
    final before = guest.answers;

    // A 512 KB hostile frame must not pull anything sizeable back out: it is
    // dropped before the parser, with no answer at all.
    guest.sendRaw('x' * (maxMessageLength + 1));
    await settle(80);
    expect(guest.answers, before);
    expect(guest.closed, isFalse);
  });

  test('a malformed frame draws a constant-size refusal', () {
    // The relay-side refusal is built by HostServer; its SHAPE is what bounds
    // the amplification, so assert on the frame itself.
    final reject =
        const RejectMessage(reason: 'not valid JSON', lastSeq: 4).encode();
    expect(reject.length, lessThan(150));
    expect(jsonDecode(reject), isNot(contains('log')));
  });

  test('a hostile write cannot forge its authorship', () async {
    final f = await ServerFixture.start();
    addTearDown(f.dispose);
    final guest = await RawGuest.connect(f.server);
    addTearDown(guest.close);
    guest.hello();
    await waitFor(() => guest.gotWelcome, what: 'a welcome');

    // There is no author field on a write frame at all — the relay stamps it —
    // so the best a hostile peer can do is add one and have it ignored.
    guest.sendRaw(jsonEncode({
      'v': protocolVersion,
      'type': 'w_event',
      'payload': {
        'id': 1,
        'seq': 1,
        'gameNo': 1,
        'author': MatchRelay.hostAuthor,
        'event': const OpeningRollEvent(whiteDie: 6, blackDie: 5).toJson(),
      },
    }));
    await waitFor(() => f.relay.lastSeq == 1, what: 'the write to land');
    expect(f.relay.events.single.author, MatchRelay.guestAuthor,
        reason: 'authorship comes from the connection, never from the wire');
    expect(MatchRelay.sideOf(f.relay.events.single.author), Player.black);
  });
}
