import 'dart:convert';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:lan_play/lan_play.dart';
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

void main() {
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
          'v': 1,
          'type': 'hello',
          'payload': {'name': 'Bo', 'code': 'x' * (maxCodeLength + 1)},
        })).kind,
        ProtocolErrorKind.badField,
      );
      expect(
        bad(jsonEncode({
          'v': 1,
          'type': 'hello',
          'payload': {'name': 'Bo', 'code': 421},
        })).kind,
        ProtocolErrorKind.badField,
      );
    });

    test('welcome carries config, side and the seq-numbered log', () {
      final msg = WelcomeMessage(
        config: const MatchConfig(length: 5, cubeless: true),
        side: Player.black,
        resume: 'tok-9',
        log: [
          const LogEntry(
              seq: 1,
              gameNo: 1,
              event: OpeningRollEvent(whiteDie: 6, blackDie: 3)),
          LogEntry(
            seq: 2,
            gameNo: 1,
            event: MoveEvent(
                Player.white, Move([const CheckerMove(23, 20, isHit: true)])),
          ),
        ],
      );
      final back = ok(msg.encode()) as WelcomeMessage;
      expect(back.config.length, 5);
      expect(back.config.cubeless, isTrue);
      expect(back.side, Player.black);
      expect(back.resume, 'tok-9');
      expect(back.log.map((e) => e.seq), [1, 2]);
      expect(back.log.map((e) => e.gameNo), [1, 1]);
      expect(back.log.first.event, const OpeningRollEvent(whiteDie: 6, blackDie: 3));
      final move = back.log[1].event as MoveEvent;
      expect(move.player, Player.white);
      expect(move.move.checkerMoves.single,
          const CheckerMove(23, 20, isHit: true));
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
        final back = ok(SubmitMessage(e).encode()) as SubmitMessage;
        expect(back.event, e, reason: 'round-trip failed for ${e.toJson()}');
      }
    });

    test('event message exposes seq at the envelope level', () {
      final raw = EventMessage(const LogEntry(
              seq: 7, gameNo: 2, event: RollEvent(Player.white, 3, 1)))
          .encode();
      expect(jsonDecode(raw), containsPair('seq', 7));
      final back = ok(raw) as EventMessage;
      expect(back.entry.seq, 7);
      expect(back.entry.gameNo, 2);
      expect(back.entry.event, const RollEvent(Player.white, 3, 1));
      expect(back.seq, 7);
    });

    test('reject carries a reason and the host lastSeq, never a log', () {
      final raw =
          const RejectMessage(reason: 'not your turn', lastSeq: 12).encode();
      final back = ok(raw) as RejectMessage;
      expect(back.reason, 'not your turn');
      expect(back.lastSeq, 12);
      // The whole point of the shape: a rejection is constant-size.
      expect(jsonDecode(raw), isNot(contains('log')));
      expect((jsonDecode(raw) as Map)['payload'], isNot(contains('log')));
      expect(raw.length, lessThan(120));

      // lastSeq is 0 before any event, and required.
      expect((ok(const RejectMessage(reason: 'x', lastSeq: 0).encode())
              as RejectMessage)
          .lastSeq, 0);
      expect(
          bad(jsonEncode({
            'v': 1,
            'type': 'reject',
            'payload': {'reason': 'x'}
          })).kind,
          ProtocolErrorKind.badField);
      expect(
          bad(jsonEncode({
            'v': 1,
            'type': 'reject',
            'payload': {'reason': 'x', 'lastSeq': -1}
          })).kind,
          ProtocolErrorKind.badField);
    });

    test('control frames', () {
      expect(ok(const RollRequestMessage().encode()), isA<RollRequestMessage>());
      expect(ok(const BusyMessage().encode()), isA<BusyMessage>());
      expect(ok(const PingMessage().encode()), isA<PingMessage>());
      expect(ok(const PongMessage().encode()), isA<PongMessage>());
    });

    test('encoded frames always carry the version', () {
      for (final m in <Envelope>[
        const HelloMessage(name: 'x'),
        const PingMessage(),
        SubmitMessage(const TakeEvent(Player.white)),
      ]) {
        expect(jsonDecode(m.encode()), containsPair('v', protocolVersion));
      }
    });
  });

  group('strict decoding', () {
    test('unknown FIELDS are ignored (forward compatibility)', () {
      final raw = jsonEncode({
        'v': 1,
        'type': 'hello',
        'unknownTop': [1, 2, 3],
        'payload': {'name': 'Ana', 'futureFlag': true},
      });
      expect((ok(raw) as HelloMessage).name, 'Ana');
    });

    test('a future protocol version is refused', () {
      final e = bad(jsonEncode({
        'v': 2,
        'type': 'hello',
        'payload': {'name': 'Ana'},
      }));
      expect(e.kind, ProtocolErrorKind.unsupportedVersion);
      expect(e.message, contains('2'));
    });

    test('a missing or non-integer version is refused', () {
      expect(bad(jsonEncode({'type': 'ping'})).kind,
          ProtocolErrorKind.unsupportedVersion);
      expect(bad(jsonEncode({'v': '1', 'type': 'ping'})).kind,
          ProtocolErrorKind.unsupportedVersion);
    });

    test('an unknown message type is refused', () {
      final e = bad(jsonEncode({'v': 1, 'type': 'nuke', 'payload': {}}));
      expect(e.kind, ProtocolErrorKind.unknownType);
    });

    test('a missing/non-string type is refused', () {
      expect(bad(jsonEncode({'v': 1})).kind, ProtocolErrorKind.badField);
      expect(bad(jsonEncode({'v': 1, 'type': 42})).kind,
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
        '{"v":1,,}',
      ]) {
        expect(bad(raw).kind,
            anyOf(ProtocolErrorKind.malformed, ProtocolErrorKind.badField));
      }
    });

    test('an oversized frame is refused before parsing', () {
      final raw = jsonEncode({
        'v': 1,
        'type': 'hello',
        'payload': {'name': 'a' * (maxMessageLength + 10)},
      });
      expect(bad(raw).kind, ProtocolErrorKind.tooLarge);
    });

    test('a payload of the wrong shape is refused', () {
      expect(
          bad(jsonEncode({'v': 1, 'type': 'hello', 'payload': 'Ana'})).kind,
          ProtocolErrorKind.badField);
      expect(bad(jsonEncode({'v': 1, 'type': 'hello', 'payload': {}})).kind,
          ProtocolErrorKind.badField);
      expect(
          bad(jsonEncode({
            'v': 1,
            'type': 'hello',
            'payload': {'name': 7}
          })).kind,
          ProtocolErrorKind.badField);
      expect(
          bad(jsonEncode({
            'v': 1,
            'type': 'hello',
            'payload': {'name': 'x' * (maxNameLength + 1)}
          })).kind,
          ProtocolErrorKind.badField);
    });

    test('a submit with a malformed game event is refused', () {
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
              'v': 1,
              'type': 'submit',
              'payload': {'event': ev}
            })).kind,
            ProtocolErrorKind.badField,
            reason: 'accepted a malformed event: $ev');
      }
    });

    test('a move with too many hops is refused', () {
      final hops = [for (var i = 0; i < 9; i++) [5, 3, false]];
      expect(
          bad(jsonEncode({
            'v': 1,
            'type': 'submit',
            'payload': {
              'event': {'type': 'move', 'player': 'white', 'move': hops}
            }
          })).kind,
          ProtocolErrorKind.badField);
    });

    test('welcome payload validation', () {
      Object base(Map<String, Object?> over) => {
            'v': 1,
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
      expect(
          bad(jsonEncode(base({
            'log': [
              {'seq': 0, 'gameNo': 1, 'event': {'type': 'take', 'player': 'white'}}
            ]
          }))).kind,
          ProtocolErrorKind.badField);
      expect(
          bad(jsonEncode(base({
            'log': [
              {'gameNo': 1, 'event': {'type': 'take', 'player': 'white'}}
            ]
          }))).kind,
          ProtocolErrorKind.badField);
    });

    test('event message requires a positive seq', () {
      Object frame(Object? seq) => {
            'v': 1,
            'type': 'event',
            if (seq != null) 'seq': seq,
            'payload': {
              'gameNo': 1,
              'event': {'type': 'take', 'player': 'white'}
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
      String frame(String seq) => '{"v":1,"type":"event","seq":$seq,'
          '"payload":{"gameNo":1,"event":{"type":"take","player":"white"}}}';
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
      expect((ok(frame('$maxIntValue')) as EventMessage).entry.seq, maxIntValue);

      // The same bound applies to hops, match length and gameNo.
      expect(
          bad(jsonEncode({
            'v': 1,
            'type': 'submit',
            'payload': {
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
        'v': 1,
        'type': 'event',
        'seq': 3.0,
        'payload': {
          'gameNo': 1.0,
          'event': {'type': 'roll', 'player': 'white', 'die1': 3.0, 'die2': 2.0}
        },
      });
      expect((ok(raw) as EventMessage).entry.seq, 3);
    });

    test('deeply nested text is refused without being parsed', () {
      final bomb = jsonEncode({
        'v': 1,
        'type': 'submit',
        'payload': {'event': _nest(200)},
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

    test('a whole match log fits in one welcome frame', () {
      // ~300 entries is a realistic 3-point match (see the full-match test in
      // host_authority_test.dart); it must survive the size cap intact.
      final log = [
        for (var i = 1; i <= 400; i++)
          LogEntry(
            seq: i,
            gameNo: 1 + i ~/ 120,
            event: MoveEvent(
                i.isEven ? Player.white : Player.black,
                Move([
                  const CheckerMove(12, 6),
                  const CheckerMove(7, 6, isHit: true),
                ])),
          ),
      ];
      final raw = WelcomeMessage(
              config: const MatchConfig(length: 7), side: Player.black, log: log)
          .encode();
      expect(raw.length, lessThan(maxMessageLength));
      expect((ok(raw) as WelcomeMessage).log, hasLength(400));
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
