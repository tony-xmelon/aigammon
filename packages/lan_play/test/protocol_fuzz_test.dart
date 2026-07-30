import 'dart:convert';
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:lan_play/lan_play.dart';
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
/// illegal move is not its business â€” it is written to the log and the opponent's
/// controller FREEZES on it (`app/test/net/net_cheat_freeze_test.dart` owns those
/// cases, on both transports). What this suite still owns is that a hostile frame
/// cannot make the relay throw, mis-order the log, or answer with anything
/// unbounded.
void main() {
  const cases = 400;

  /// Every `type` the decoder switches on. Fuzzing has to USE these: a random
  /// string in `type` dies at `unknownType` before any payload decoder runs, so a
  /// corpus that invents type names tests the switch's default arm 200 times over
  /// and the ten payload decoders not once.
  const types = [
    'hello',
    'welcome',
    'event',
    'roll',
    'w_event',
    'w_roll',
    'w_entropy',
    'w_reveal',
    'ack',
    'reject',
    'busy',
    'ping',
    'pong',
  ];

  /// A hex-ish value: sometimes the exact 64-hex the wire demands, more often
  /// something that only looks like it (wrong length, wrong alphabet, wrong type).
  Object? hexish(Random r) => switch (r.nextInt(6)) {
        0 => 'ab' * 32, // valid
        1 => 'ab' * (1 + r.nextInt(64)), // wrong length
        2 => 'zz' * 32, // right length, not hex
        3 => 'AB' * 32, // uppercase
        4 => r.nextInt(1 << 20),
        _ => null,
      };

  /// Deterministic generator of nasty frames.
  String nasty(Random r) {
    /// A junk scalar, biased towards values that get PAST a type check.
    Object? junk() {
      const pool = <Object?>[
        null, 0, 1, -1, 3.7, true, false, 'x', 'white', 'black', 'ok',
        'reject', [], <String, Object?>{}, 1 << 40,
      ];
      return pool[r.nextInt(pool.length)];
    }

    switch (r.nextInt(10)) {
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
      case 5: // a REAL type, wrong types everywhere in the payload
        return jsonEncode({
          'v': r.nextBool() ? protocolVersion : junk(),
          'type': types[r.nextInt(types.length)],
          'payload': {
            'id': junk(),
            'name': junk(),
            'side': junk(),
            'seq': junk(),
            'gameNo': junk(),
            'n': junk(),
            'commit': hexish(r),
            'entropy': hexish(r),
            'reveal': hexish(r),
            'status': junk(),
            'reason': junk(),
            'lastSeq': junk(),
            'resume': junk(),
            'log': junk(),
            'rolls': junk(),
            'matchConfig': junk(),
            'entry': junk(),
            'roll': junk(),
            'event': {'type': junk(), 'player': junk(), 'move': junk()},
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
      case 7: // the ROLL-PROTOCOL writes, the deepest untested payloads
        // w_roll / w_entropy / w_reveal each run `_positive` twice and `_hex`
        // once; nothing in the old corpus ever reached them, so the hex guard —
        // the check that keeps a garbage commitment out of the log — was fuzzed
        // zero times.
        final type = ['w_roll', 'w_entropy', 'w_reveal'][r.nextInt(3)];
        final field =
            {'w_roll': 'commit', 'w_entropy': 'entropy', 'w_reveal': 'reveal'}[
                type]!;
        return jsonEncode({
          'v': protocolVersion,
          'type': type,
          'payload': {
            'id': r.nextBool() ? 1 + r.nextInt(5) : junk(),
            'n': r.nextBool() ? r.nextInt(6) - 1 : junk(),
            field: hexish(r),
            // A hostile peer may also send the OTHER two fields; they must be
            // ignored rather than confused for this one.
            if (r.nextBool()) 'commit': hexish(r),
            if (r.nextBool()) 'entropy': hexish(r),
          },
        });

      case 8: // welcome/ack/event/roll — the ARRAY-bearing replies
        // A guest decodes these, so a hostile HOST reaches them. `log` and
        // `rolls` are the only unbounded-length fields in the protocol, and they
        // were never fuzzed at all.
        Object? entry(int i) => switch (r.nextInt(4)) {
              0 => {
                  'seq': r.nextBool() ? i + 1 : junk(),
                  'gameNo': junk(),
                  'author': junk(),
                  'event': {'type': junk(), 'player': junk()},
                },
              1 => {
                  'seq': i + 1,
                  'gameNo': 1,
                  'author': 'host',
                  'event': DoubleEvent(Player.white).toJson(),
                },
              2 => junk(),
              _ => [i, i, i],
            };
        Object? roll(int i) => switch (r.nextInt(3)) {
              0 => {
                  'n': r.nextBool() ? i + 1 : junk(),
                  'roller': junk(),
                  'commit': hexish(r),
                  'entropy': hexish(r),
                  'reveal': hexish(r),
                },
              1 => junk(),
              _ => {'n': i + 1, 'roller': 'host', 'commit': 'ab' * 32},
            };
        final n = r.nextInt(8);
        return jsonEncode({
          'v': protocolVersion,
          'type': ['welcome', 'ack', 'event', 'roll'][r.nextInt(4)],
          'payload': {
            'matchConfig': r.nextBool()
                ? {'length': junk(), 'cubeless': junk()}
                : {'length': 3, 'cubeless': false},
            'side': r.nextBool() ? 'white' : junk(),
            'resume': junk(),
            'log': r.nextBool() ? [for (var i = 0; i < n; i++) entry(i)] : junk(),
            'rolls':
                r.nextBool() ? [for (var i = 0; i < n; i++) roll(i)] : junk(),
            'entry': entry(r.nextInt(3)),
            'roll': roll(r.nextInt(3)),
            'id': r.nextBool() ? 1 : junk(),
            'status': ['ok', 'reject', junk()][r.nextInt(3)],
            'reason': junk(),
            'lastSeq': r.nextBool() ? r.nextInt(9) - 1 : junk(),
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
    final kindCounts = {for (final k in ProtocolErrorKind.values) k: 0};
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
          kindCounts[error.kind] = kindCounts[error.kind]! + 1;
      }
    }
    // The corpus is meant to be mostly-invalid; a few (case 4/6 with benign
    // values) do decode. Both branches must be exercised for the test to mean
    // anything.
    expect(ok, greaterThan(0), reason: 'corpus never produced a valid frame');
    expect(ok, lessThan(cases),
        reason: 'corpus never produced an invalid frame');

    // …and it must REACH the payload decoders. `badField` can only be raised
    // after the type switch has picked a message and started reading fields, so
    // it is the evidence that the corpus is testing the ten payload decoders and
    // not just the switch's default arm 400 times over. (Before the roll-protocol
    // and array-bearing cases existed, `w_roll`/`w_entropy`/`w_reveal`/`ack`/
    // `welcome` were never once reached.)
    final kinds = kindCounts.entries
        .where((e) => e.value > 0)
        .map((e) => e.key)
        .toSet();
    expect(kinds, contains(ProtocolErrorKind.badField),
        reason: 'the corpus never got past the type switch');
    expect(kinds, contains(ProtocolErrorKind.malformed));
    expect(kindCounts[ProtocolErrorKind.badField]!, greaterThan(cases ~/ 10),
        reason: 'only $kinds and ${kindCounts[ProtocolErrorKind.badField]} '
            'badField failures — the deep paths are barely exercised');
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
    // except an append at the next free seq â€” and even that only ever lands
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
        RejectMessage(reason: 'not valid JSON', lastSeq: 4).encode();
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

    // There is no author field on a write frame at all â€” the relay stamps it â€”
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
