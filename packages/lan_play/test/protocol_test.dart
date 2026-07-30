import 'dart:convert';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:lan_play/lan_play.dart';
import 'package:match_transport/match_transport.dart';
import 'package:test/test.dart';

/// Decode helper: expects success and returns the envelope.
Envelope ok(String raw) {
  final r = Envelope.decode(raw);
  expect(r, isA<DecodeOk>(), reason: 'expected a decodable frame: $raw');
  return (r as DecodeOk).envelope;
}

/// Decode helper: expects failure and returns the typed error.
ProtocolError bad(String raw) {
  final r = Envelope.decode(raw);
  expect(r, isA<DecodeFailure>(), reason: 'expected a rejected frame: $raw');
  return (r as DecodeFailure).error;
}

/// A valid commit-reveal value: 64 lowercase hex characters.
String hex(int fill) => fill.toRadixString(16).padLeft(kHexLength, '0');

void main() {
  final commit = hex(0xabc);
  final entropy = hex(0xdef);
  final reveal = hex(0x123);

  group('envelope round-trips', () {
    test('hello with and without a resume token', () {
      final a = ok(const HelloMessage(name: 'Ana').encode()) as HelloMessage;
      expect(a.name, 'Ana');
      expect(a.resume, isNull);

      final b = ok(const HelloMessage(name: 'Bo', resume: 'tok-1').encode())
          as HelloMessage;
      expect(b.name, 'Bo');
      expect(b.resume, 'tok-1');
      expect(b.code, isNull, reason: 'the code is optional on the wire');
    });

    test('hello carries the room code, bounded', () {
      final withCode =
          ok(const HelloMessage(name: 'Bo', code: '0421').encode())
              as HelloMessage;
      expect(withCode.code, '0421');

      // An oversized code is a bad field, not a truncation.
      expect(
        bad(jsonEncode({
          'v': protocolVersion,
          'type': 'hello',
          'payload': {'name': 'Bo', 'code': 'x' * (maxCodeLength + 1)},
        })).kind,
        ProtocolErrorKind.badField,
      );
      expect(
        bad(jsonEncode({
          'v': protocolVersion,
          'type': 'hello',
          'payload': {'name': 'Bo', 'code': 421},
        })).kind,
        ProtocolErrorKind.badField,
      );
    });

    test('welcome carries config, side, the log AND the roll documents', () {
      final msg = WelcomeMessage(
        config: const MatchConfig(length: 5, cubeless: true),
        side: Player.black,
        resume: 'tok-9',
        log: [
          const EventFrame(
              seq: 1,
              gameNo: 1,
              author: 'host',
              event: OpeningRollEvent(whiteDie: 6, blackDie: 3)),
          EventFrame(
            seq: 2,
            gameNo: 1,
            author: 'host',
            event: MoveEvent(
                Player.white, Move([const CheckerMove(23, 20, isHit: true)])),
          ),
        ],
        rolls: [
          RollFrame(
              n: 1,
              roller: 'host',
              commit: commit,
              entropy: entropy,
              reveal: reveal),
          RollFrame(n: 2, roller: 'guest', commit: commit),
        ],
      );
      final back = ok(msg.encode()) as WelcomeMessage;
      expect(back.config.length, 5);
      expect(back.config.cubeless, isTrue);
      expect(back.side, Player.black);
      expect(back.resume, 'tok-9');
      expect(back.log.map((e) => e.seq), [1, 2]);
      expect(back.log.map((e) => e.gameNo), [1, 1]);
      expect(back.log.map((e) => e.author), ['host', 'host'],
          reason: 'the relay\'s own attribution travels with the entry');
      expect(back.log.first.event,
          const OpeningRollEvent(whiteDie: 6, blackDie: 3));
      final move = back.log[1].event as MoveEvent;
      expect(move.player, Player.white);
      expect(move.move.checkerMoves.single,
          const CheckerMove(23, 20, isHit: true));

      expect(back.rolls.map((r) => r.n), [1, 2]);
      expect(back.rolls.first.isComplete, isTrue);
      expect(back.rolls.first.phase, FairDicePhase.revealed);
      expect(back.rolls.first.entropy, entropy);
      expect(back.rolls.first.reveal, reveal);
      expect(back.rolls.last.phase, FairDicePhase.committed);
      expect(back.rolls.last.roller, 'guest');
    });

    test('every GameEvent variant survives the envelope', () {
      final events = <GameEvent>[
        const OpeningRollEvent(whiteDie: 2, blackDie: 5),
        const RollEvent(Player.black, 4, 4),
        MoveEvent(Player.black, Move.none),
        MoveEvent(
            Player.white,
            Move([
              const CheckerMove(CheckerMove.bar, 22),
              const CheckerMove(5, CheckerMove.off),
            ])),
        const DoubleEvent(Player.white),
        const TakeEvent(Player.black),
        const DropEvent(Player.black),
        const ResignOfferEvent(Player.white, ResignValue.gammon),
        const ResignAcceptEvent(Player.black),
        const ResignDeclineEvent(Player.black),
      ];
      for (final e in events) {
        final back = ok(WriteEventMessage(id: 1, seq: 3, gameNo: 1, event: e)
            .encode()) as WriteEventMessage;
        expect(back.event, e, reason: 'round-trip failed for ${e.toJson()}');
        expect(back.id, 1);
        expect(back.seq, 3);
      }
    });

    test('an event frame carries seq, gameNo, author and the event', () {
      final raw = EventMessage(const EventFrame(
              seq: 7,
              gameNo: 2,
              author: 'guest',
              event: RollEvent(Player.white, 3, 1)))
          .encode();
      final back = ok(raw) as EventMessage;
      expect(back.entry.seq, 7);
      expect(back.entry.gameNo, 2);
      expect(back.entry.author, 'guest');
      expect(back.entry.event, const RollEvent(Player.white, 3, 1));
    });

    test('a roll frame round-trips at each phase', () {
      for (final roll in [
        RollFrame(n: 4, roller: 'host', commit: commit),
        RollFrame(n: 4, roller: 'host', commit: commit, entropy: entropy),
        RollFrame(
            n: 4,
            roller: 'host',
            commit: commit,
            entropy: entropy,
            reveal: reveal),
      ]) {
        final back = ok(RollMessage(roll).encode()) as RollMessage;
        expect(back.roll.n, 4);
        expect(back.roll.roller, 'host');
        expect(back.roll.commit, commit);
        expect(back.roll.entropy, roll.entropy);
        expect(back.roll.reveal, roll.reveal);
        expect(back.roll.phase, roll.phase);
      }
    });

    test('the three roll writes round-trip', () {
      final r = ok(WriteRollMessage(id: 2, n: 1, commit: commit).encode())
          as WriteRollMessage;
      expect((r.id, r.n, r.commit), (2, 1, commit));
      final e = ok(WriteEntropyMessage(id: 3, n: 1, entropy: entropy).encode())
          as WriteEntropyMessage;
      expect((e.id, e.n, e.entropy), (3, 1, entropy));
      final v = ok(WriteRevealMessage(id: 4, n: 1, reveal: reveal).encode())
          as WriteRevealMessage;
      expect((v.id, v.n, v.reveal), (4, 1, reveal));
    });

    test('ack quotes the write id, the status and the relay seq', () {
      for (final status in AckStatus.values) {
        final raw = AckMessage(
                id: 9, status: status, lastSeq: 12, reason: 'because')
            .encode();
        final back = ok(raw) as AckMessage;
        expect(back.id, 9);
        expect(back.status, status);
        expect(back.lastSeq, 12);
        expect(back.reason, 'because');
        // Constant-size, whatever happened: an ack is never an amplifier.
        expect(raw.length, lessThan(150));
        expect((jsonDecode(raw) as Map)['payload'], isNot(contains('log')));
      }
      expect(
          (ok(AckMessage(id: 1, status: AckStatus.ok, lastSeq: 0).encode())
                  as AckMessage)
              .reason,
          isNull);
      expect(
          bad(jsonEncode({
            'v': protocolVersion,
            'type': 'ack',
            'payload': {'id': 1, 'status': 'maybe', 'lastSeq': 0}
          })).kind,
          ProtocolErrorKind.badField);
      expect(
          bad(jsonEncode({
            'v': protocolVersion,
            'type': 'ack',
            'payload': {'id': 0, 'status': 'ok', 'lastSeq': 0}
          })).kind,
          ProtocolErrorKind.badField);
    });

    test('a reason built from peer text is CAPPED at construction', () {
      // The cap used to be enforced only on READ, and several ProtocolError
      // messages quote the offending value verbatim — so one small nonsense field
      // bought an arbitrarily large outbound reject, and the honest peer then
      // DROPPED it (its decoder refuses a reason over maxReasonLength), losing
      // the "you are behind" lastSeq signal with it.
      final huge = 'x' * 100000;
      final reject = RejectMessage(reason: huge, lastSeq: 7);
      expect(reject.reason.length, maxReasonLength);
      final raw = reject.encode();
      expect(raw.length, lessThan(maxReasonLength + 200),
          reason: 'the frame is constant-size whatever the peer sent');
      // And it still DECODES, so lastSeq is still delivered.
      final back = ok(raw) as RejectMessage;
      expect(back.lastSeq, 7);
      expect(back.reason.length, maxReasonLength);

      // The same for an ack's optional reason.
      final ack = AckMessage(
          id: 1, status: AckStatus.rejected, lastSeq: 9, reason: huge);
      expect(ack.reason!.length, maxReasonLength);
      expect((ok(ack.encode()) as AckMessage).lastSeq, 9);

      // Exactly at the cap is untouched; a null ack reason stays null.
      final atCap = 'y' * maxReasonLength;
      expect(RejectMessage(reason: atCap, lastSeq: 0).reason, atCap);
      expect(
          AckMessage(id: 1, status: AckStatus.ok, lastSeq: 0).reason, isNull);
      // An empty reason would be refused by the decoder, so it never ships.
      expect(RejectMessage(reason: '', lastSeq: 0).reason, isNotEmpty);
    });

    test('the whole path from a hostile frame to a bounded reject', () {
      // The concrete route the review found: an enormous `event.type` reaches
      // `_bad('unreadable event: $e')`, whose message embeds it.
      final hostile = jsonEncode({
        'v': protocolVersion,
        'type': 'w_event',
        'payload': {
          'id': 1,
          'seq': 1,
          'gameNo': 1,
          'event': {'type': 'z' * 100000},
        },
      });
      final error = bad(hostile);
      expect(error.message.length, greaterThan(maxReasonLength),
          reason: 'the error itself does quote the peer');
      final raw = RejectMessage(reason: error.message, lastSeq: 3).encode();
      expect(raw.length, lessThan(maxReasonLength + 200));
      expect((ok(raw) as RejectMessage).lastSeq, 3);
    });

    test('reject carries a reason and the relay lastSeq, never a log', () {
      final raw =
          RejectMessage(reason: 'bad code', lastSeq: 12).encode();
      final back = ok(raw) as RejectMessage;
      expect(back.reason, 'bad code');
      expect(back.lastSeq, 12);
      // The whole point of the shape: a rejection is constant-size.
      expect(jsonDecode(raw), isNot(contains('log')));
      expect((jsonDecode(raw) as Map)['payload'], isNot(contains('log')));
      expect(raw.length, lessThan(120));

      // lastSeq is 0 before any event, and required.
      expect(
          (ok(RejectMessage(reason: 'x', lastSeq: 0).encode())
                  as RejectMessage)
              .lastSeq,
          0);
      expect(
          bad(jsonEncode({
            'v': protocolVersion,
            'type': 'reject',
            'payload': {'reason': 'x'}
          })).kind,
          ProtocolErrorKind.badField);
      expect(
          bad(jsonEncode({
            'v': protocolVersion,
            'type': 'reject',
            'payload': {'reason': 'x', 'lastSeq': -1}
          })).kind,
          ProtocolErrorKind.badField);
    });

    test('control frames', () {
      expect(ok(const BusyMessage().encode()), isA<BusyMessage>());
      expect(ok(const PingMessage().encode()), isA<PingMessage>());
      expect(ok(const PongMessage().encode()), isA<PongMessage>());
    });

    test('encoded frames always carry the version', () {
      for (final m in <Envelope>[
        const HelloMessage(name: 'x'),
        const PingMessage(),
        WriteEventMessage(
            id: 1, seq: 1, gameNo: 1, event: const TakeEvent(Player.white)),
      ]) {
        expect(jsonDecode(m.encode()), containsPair('v', protocolVersion));
      }
    });
  });

  group('strict decoding', () {
    test('unknown FIELDS are ignored (forward compatibility)', () {
      final raw = jsonEncode({
        'v': protocolVersion,
        'type': 'hello',
        'unknownTop': [1, 2, 3],
        'payload': {'name': 'Ana', 'futureFlag': true},
      });
      expect((ok(raw) as HelloMessage).name, 'Ana');
    });

    test('the PREVIOUS protocol version is refused', () {
      // v1 spoke `submit`/`roll_request` to a host authority that no longer
      // exists; letting such a peer in would be a silent stall.
      final e = bad(jsonEncode({
        'v': 1,
        'type': 'hello',
        'payload': {'name': 'Ana'},
      }));
      expect(e.kind, ProtocolErrorKind.unsupportedVersion);
      expect(e.message, contains('1'));
    });

    test('a future protocol version is refused', () {
      final e = bad(jsonEncode({
        'v': protocolVersion + 1,
        'type': 'hello',
        'payload': {'name': 'Ana'},
      }));
      expect(e.kind, ProtocolErrorKind.unsupportedVersion);
    });

    test('a missing or non-integer version is refused', () {
      expect(bad(jsonEncode({'type': 'ping'})).kind,
          ProtocolErrorKind.unsupportedVersion);
      expect(bad(jsonEncode({'v': '2', 'type': 'ping'})).kind,
          ProtocolErrorKind.unsupportedVersion);
    });

    test('an unknown message type is refused', () {
      final e = bad(
          jsonEncode({'v': protocolVersion, 'type': 'nuke', 'payload': {}}));
      expect(e.kind, ProtocolErrorKind.unknownType);
    });

    test('the retired v1 types are simply unknown now', () {
      for (final type in ['submit', 'roll_request']) {
        expect(
            bad(jsonEncode(
                    {'v': protocolVersion, 'type': type, 'payload': {}}))
                .kind,
            ProtocolErrorKind.unknownType);
      }
    });

    test('a missing/non-string type is refused', () {
      expect(bad(jsonEncode({'v': protocolVersion})).kind,
          ProtocolErrorKind.badField);
      expect(bad(jsonEncode({'v': protocolVersion, 'type': 42})).kind,
          ProtocolErrorKind.badField);
    });

    test('malformed JSON is refused', () {
      for (final raw in [
        '',
        ' ',
        '\u0000', // a bare NUL, escaped so this file stays reviewable text
        '{',
        'null',
        '[]',
        '"hi"',
        '{"v":2,,}',
      ]) {
        expect(bad(raw).kind,
            anyOf(ProtocolErrorKind.malformed, ProtocolErrorKind.badField));
      }
    });

    test('an oversized frame is refused before parsing', () {
      final raw = jsonEncode({
        'v': protocolVersion,
        'type': 'hello',
        'payload': {'name': 'a' * (maxMessageLength + 10)},
      });
      expect(bad(raw).kind, ProtocolErrorKind.tooLarge);
    });

    test('a payload of the wrong shape is refused', () {
      expect(
          bad(jsonEncode(
                  {'v': protocolVersion, 'type': 'hello', 'payload': 'Ana'}))
              .kind,
          ProtocolErrorKind.badField);
      expect(
          bad(jsonEncode(
                  {'v': protocolVersion, 'type': 'hello', 'payload': {}}))
              .kind,
          ProtocolErrorKind.badField);
      expect(
          bad(jsonEncode({
            'v': protocolVersion,
            'type': 'hello',
            'payload': {'name': 7}
          })).kind,
          ProtocolErrorKind.badField);
      expect(
          bad(jsonEncode({
            'v': protocolVersion,
            'type': 'hello',
            'payload': {'name': 'x' * (maxNameLength + 1)}
          })).kind,
          ProtocolErrorKind.badField);
    });

    test('a write with a malformed game event is refused', () {
      for (final ev in <Object>[
        {'type': 'nope'},
        {'type': 'move', 'player': 'green', 'move': <Object>[]},
        {'type': 'move', 'player': 'white'},
        {'type': 'resignOffer', 'player': 'white', 'value': 'quintuple'},
        {'type': 'roll', 'player': 'white', 'die1': 'x', 'die2': 2},
        {'type': 'move', 'player': 'white', 'move': 'all of them'},
        {
          'type': 'move',
          'player': 'white',
          'move': [
            [1, 2]
          ]
        },
        'not-an-object',
        42,
      ]) {
        expect(
            bad(jsonEncode({
              'v': protocolVersion,
              'type': 'w_event',
              'payload': {'id': 1, 'seq': 1, 'gameNo': 1, 'event': ev}
            })).kind,
            ProtocolErrorKind.badField,
            reason: 'accepted a malformed event: $ev');
      }
    });

    test('a move with too many hops is refused', () {
      final hops = [
        for (var i = 0; i < 9; i++) [5, 3, false]
      ];
      expect(
          bad(jsonEncode({
            'v': protocolVersion,
            'type': 'w_event',
            'payload': {
              'id': 1,
              'seq': 1,
              'gameNo': 1,
              'event': {'type': 'move', 'player': 'white', 'move': hops}
            }
          })).kind,
          ProtocolErrorKind.badField);
    });

    test('a protocol value that is not 64 lowercase hex is refused', () {
      String frame(Object? value) => jsonEncode({
            'v': protocolVersion,
            'type': 'w_roll',
            'payload': {'id': 1, 'n': 1, 'commit': value},
          });
      for (final v in <Object?>[
        null,
        7,
        '',
        'abc',
        commit.toUpperCase(),
        '${commit}0',
        commit.substring(1),
        'z' * kHexLength,
      ]) {
        expect(bad(frame(v)).kind, ProtocolErrorKind.badField,
            reason: 'accepted $v as a commitment');
      }
      expect((ok(frame(commit)) as WriteRollMessage).commit, commit);
    });

    test('welcome payload validation', () {
      Object base(Map<String, Object?> over) => {
            'v': protocolVersion,
            'type': 'welcome',
            'payload': {
              'matchConfig': {'length': 5, 'cubeless': false},
              'side': 'white',
              'log': <Object>[],
              ...over,
            },
          };
      expect(bad(jsonEncode(base({'side': 'purple'}))).kind,
          ProtocolErrorKind.badField);
      expect(
          bad(jsonEncode(base({
            'matchConfig': {'length': 0, 'cubeless': false}
          }))).kind,
          ProtocolErrorKind.badField);
      expect(
          bad(jsonEncode(base({
            'matchConfig': {'length': 5}
          }))).kind,
          ProtocolErrorKind.badField);
      expect(bad(jsonEncode(base({'log': 'none'}))).kind,
          ProtocolErrorKind.badField);
      // seq must be >= 1, gameNo must be present, author must be present.
      expect(
          bad(jsonEncode(base({
            'log': [
              {
                'seq': 0,
                'gameNo': 1,
                'author': 'host',
                'event': {'type': 'take', 'player': 'white'}
              }
            ]
          }))).kind,
          ProtocolErrorKind.badField);
      expect(
          bad(jsonEncode(base({
            'log': [
              {
                'gameNo': 1,
                'author': 'host',
                'event': {'type': 'take', 'player': 'white'}
              }
            ]
          }))).kind,
          ProtocolErrorKind.badField);
      expect(
          bad(jsonEncode(base({
            'log': [
              {
                'seq': 1,
                'gameNo': 1,
                'event': {'type': 'take', 'player': 'white'}
              }
            ]
          }))).kind,
          ProtocolErrorKind.badField);
      // A malformed roll document is refused too.
      expect(
          bad(jsonEncode(base({
            'rolls': [
              {'n': 1, 'roller': 'host', 'commit': 'nope'}
            ]
          }))).kind,
          ProtocolErrorKind.badField);
      expect(bad(jsonEncode(base({'rolls': 'none'}))).kind,
          ProtocolErrorKind.badField);
      // Missing rolls entirely is fine â€” an old-shaped welcome has no rolls.
      expect((ok(jsonEncode(base({}))) as WelcomeMessage).rolls, isEmpty);
    });

    test('an event frame requires a positive seq', () {
      Object frame(Object? seq) => {
            'v': protocolVersion,
            'type': 'event',
            'payload': {
              'entry': {
                if (seq != null) 'seq': seq,
                'gameNo': 1,
                'author': 'host',
                'event': {'type': 'take', 'player': 'white'}
              }
            },
          };
      expect(bad(jsonEncode(frame(null))).kind, ProtocolErrorKind.badField);
      expect(bad(jsonEncode(frame(0))).kind, ProtocolErrorKind.badField);
      expect(bad(jsonEncode(frame(-3))).kind, ProtocolErrorKind.badField);
      expect(bad(jsonEncode(frame('4'))).kind, ProtocolErrorKind.badField);
      expect(bad(jsonEncode(frame(1.5))).kind, ProtocolErrorKind.badField);
      expect((ok(jsonEncode(frame(4))) as EventMessage).entry.seq, 4);
    });

    test('numbers outside the integer range are refused, not clamped', () {
      // Both (1e300).toInt() and (2^63).toInt() silently yield
      // 9223372036854775807, so an unbounded decoder would turn nonsense into a
      // plausible seq. Every one of these must be refused instead.
      String frame(String seq) =>
          '{"v":$protocolVersion,"type":"event","payload":{"entry":'
          '{"seq":$seq,"gameNo":1,"author":"host",'
          '"event":{"type":"take","player":"white"}}}}';
      for (final n in [
        '1e300',
        '-1e300',
        '9223372036854775808', // 2^63: too big for an int, decoded as a double
        '${maxIntValue + 1}',
        '1e999', // decodes to Infinity
      ]) {
        expect(bad(frame(n)).kind, ProtocolErrorKind.badField,
            reason: 'accepted $n as a seq');
      }
      expect(
          (ok(frame('$maxIntValue')) as EventMessage).entry.seq, maxIntValue);

      // The same bound applies to hops, match length and gameNo.
      expect(
          bad(jsonEncode({
            'v': protocolVersion,
            'type': 'w_event',
            'payload': {
              'id': 1,
              'seq': 1,
              'gameNo': 1,
              'event': {
                'type': 'move',
                'player': 'white',
                'move': [
                  [1e300, 2, false]
                ]
              }
            }
          })).kind,
          ProtocolErrorKind.badField);
      expect(bad(frame('1').replaceFirst('"gameNo":1', '"gameNo":1e300')).kind,
          ProtocolErrorKind.badField);
    });

    test('numbers that are integral doubles are accepted', () {
      final raw = jsonEncode({
        'v': protocolVersion,
        'type': 'event',
        'payload': {
          'entry': {
            'seq': 3.0,
            'gameNo': 1.0,
            'author': 'host',
            'event': {
              'type': 'roll',
              'player': 'white',
              'die1': 3.0,
              'die2': 2.0
            }
          }
        },
      });
      expect((ok(raw) as EventMessage).entry.seq, 3);
    });

    test('deeply nested text is refused without being parsed', () {
      final bomb = jsonEncode({
        'v': protocolVersion,
        'type': 'w_event',
        'payload': {'id': 1, 'seq': 1, 'gameNo': 1, 'event': _nest(200)},
      });
      expect(bad(bomb).kind, ProtocolErrorKind.malformed);
      expect(bad('[' * 100000).kind, ProtocolErrorKind.malformed);
      // Brackets inside a string are not nesting.
      expect(
          (ok(const HelloMessage(name: '[[[[[[[[{{{{{{').encode())
                  as HelloMessage)
              .name,
          '[[[[[[[[{{{{{{');
      expect(
          (ok(const HelloMessage(name: r'esc\"[[[[').encode()) as HelloMessage)
              .name,
          r'esc\"[[[[');
    });

    test('a whole match log AND its rolls fit in one welcome frame', () {
      // ~300 entries plus ~150 rolls is a realistic 3-point match; it must
      // survive the size cap intact.
      final log = [
        for (var i = 1; i <= 400; i++)
          EventFrame(
            seq: i,
            gameNo: 1 + i ~/ 120,
            author: i.isEven ? 'host' : 'guest',
            event: MoveEvent(
                i.isEven ? Player.white : Player.black,
                Move([
                  const CheckerMove(12, 6),
                  const CheckerMove(7, 6, isHit: true),
                ])),
          ),
      ];
      final rolls = [
        for (var n = 1; n <= 200; n++)
          RollFrame(
              n: n,
              roller: n.isEven ? 'host' : 'guest',
              commit: commit,
              entropy: entropy,
              reveal: reveal),
      ];
      final raw = WelcomeMessage(
              config: const MatchConfig(length: 7),
              side: Player.black,
              log: log,
              rolls: rolls)
          .encode();
      expect(raw.length, lessThan(maxMessageLength));
      final back = ok(raw) as WelcomeMessage;
      expect(back.log, hasLength(400));
      expect(back.rolls, hasLength(200));
    });

    test('ProtocolError has a readable toString', () {
      expect(bad('{').toString(), contains('ProtocolError'));
    });
  });
}

/// A [depth]-deep nest of JSON arrays.
Object _nest(int depth) {
  Object node = 1;
  for (var i = 0; i < depth; i++) {
    node = [node];
  }
  return node;
}
