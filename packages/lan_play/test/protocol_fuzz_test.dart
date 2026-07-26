import 'dart:convert';
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:lan_play/lan_play.dart';
import 'package:test/test.dart';

/// A hostile LAN peer must not be able to crash the host: [Envelope.decode] is
/// TOTAL (every input yields DecodeOk or DecodeFailure) and
/// [HostAuthority.onGuestRaw] never throws whatever it is fed.
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
        return '{"v":1,"type":"submit","payload":{"event":'
            '${'[' * depth}${']' * depth}}}';
      case 4: // huge strings
        return jsonEncode({
          'v': 1,
          'type': 'hello',
          'payload': {'name': 'x' * (1 << r.nextInt(16))},
        });
      case 5: // right shape, wrong types everywhere
        final junk = <Object?>[null, 1, -1, 3.7, true, 'x', [], {}, 'white'];
        Object? pick() => junk[r.nextInt(junk.length)];
        return jsonEncode({
          'v': pick(),
          'type': pick(),
          'seq': pick(),
          'payload': {
            'name': pick(),
            'side': pick(),
            'gameNo': pick(),
            'log': pick(),
            'matchConfig': pick(),
            'event': {'type': pick(), 'player': pick(), 'move': pick()},
          },
        });
      case 6: // a plausible move event with nonsense hops
        return jsonEncode({
          'v': 1,
          'type': 'submit',
          'payload': {
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
        final buf = StringBuffer(r.nextBool() ? '{"v":1,' : '');
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
    expect(ok, lessThan(cases), reason: 'corpus never produced an invalid frame');
  });

  test('the authority survives $cases hostile frames and stays consistent', () {
    final r = Random(4242);
    final host = HostAuthority(
      config: const MatchConfig(length: 3),
      dice: ScriptedDiceRoller([Dice(6, 1)]),
    );
    final seen = <HostOutbound>[];
    host.outbound.listen(seen.add);
    host.onGuestMessage(const HelloMessage(name: 'peer'));

    for (var i = 0; i < cases; i++) {
      expect(() => host.onGuestRaw(nasty(r)), returnsNormally);
    }
    // Nothing hostile advanced the game: still game 1, opening roll only.
    expect(host.lastSeq, 1);
    expect(host.log.single.event, const OpeningRollEvent(whiteDie: 6, blackDie: 1));
    expect(host.state!.turn, Player.white);
    host.close();
  });

  test('the DEEP validation path survives hostile frames with the guest on turn',
      () async {
    // The other authority fuzz test never gets past the turn guard (its guest
    // is not on turn), so move legality is never reached. Here the host plays
    // Black and the opening roll hands White — the GUEST — the first move, so
    // every frame below lands squarely in canonicalPlay.
    final host = HostAuthority(
      config: const MatchConfig(length: 3),
      hostSide: Player.black,
      dice: ScriptedDiceRoller([Dice(6, 1)]),
    );
    final seen = <HostOutbound>[];
    host.outbound.listen(seen.add);
    host.onGuestMessage(const HelloMessage(name: 'peer'));
    await Future<void>.delayed(Duration.zero);
    expect(host.guestSide, Player.white);
    expect(host.state!.turn, Player.white, reason: 'the guest is on turn');
    expect(host.state!.phase, GamePhase.moving);
    final board = host.state!.board;

    String moveFrame(String hops) => '{"v":1,"type":"submit","payload":'
        '{"event":{"type":"move","player":"white","move":$hops}}}';

    // Targeted adversarial plays: out-of-range hops, bar/off sentinels abused,
    // non-representable numbers, the wrong number of hops, a pass while moves
    // exist, and a hop onto a blocked point.
    final adversarial = <String>[
      moveFrame('[[-100,-100,false],[5,3,false]]'),
      moveFrame('[[500,-7,false],[5,3,false]]'),
      moveFrame('[[24,-1,false],[24,-1,false]]'),
      moveFrame('[[1e300,6,false],[7,6,false]]'),
      moveFrame('[[-1e300,-1e300,false],[7,6,false]]'),
      moveFrame('[[12,6,false],[7,6,false],[5,4,false],[4,3,false]]'),
      moveFrame('[]'),
      moveFrame('[[23,17,false],[12,11,false]]'), // lands on a made Black point
      moveFrame('[[23,17,false],[12,6,false]]'), // two 6s on a 6-1
    ];
    var mark = seen.length;
    for (final frame in adversarial) {
      host.onGuestRaw(frame);
    }
    await Future<void>.delayed(Duration.zero);

    // Every targeted frame drew exactly one rejection.
    final replies = seen.sublist(mark);
    expect(replies, hasLength(adversarial.length));
    expect(replies.every((o) => o.message is RejectMessage), isTrue,
        reason: 'a hostile frame produced something other than a rejection');
    expect(replies.every((o) => o.to == HostDestination.guest), isTrue);

    // Then the generic corpus, on the same open turn. (Some of those frames
    // are valid hellos or pings, so the replies are not all rejections — what
    // matters is that NONE of them appended an event.)
    mark = seen.length;
    final r = Random(99);
    for (var i = 0; i < cases; i++) {
      expect(() => host.onGuestRaw(nasty(r)), returnsNormally);
    }
    await Future<void>.delayed(Duration.zero);
    expect(seen.sublist(mark).where((o) => o.message is EventMessage), isEmpty,
        reason: 'a hostile frame moved the game');

    expect(host.lastSeq, 1);
    expect(host.state!.board, board, reason: 'the board never moved');
    expect(host.state!.turn, Player.white);
    expect(host.state!.phase, GamePhase.moving);
    // And a LEGAL move still works afterwards: nothing was left wedged.
    host.onGuestMessage(
        SubmitMessage(MoveEvent(Player.white, host.state!.legalMoves.first)));
    await Future<void>.delayed(Duration.zero);
    expect(host.lastSeq, 2);
    expect(host.state!.turn, Player.black);
    host.close();
  });

  test('an oversized frame is dropped without a large reply', () async {
    final host = HostAuthority(config: const MatchConfig(length: 1));
    final seen = <HostOutbound>[];
    host.outbound.listen(seen.add);
    host.onGuestRaw('x' * (maxMessageLength + 1));
    await Future<void>.delayed(Duration.zero);
    // A 512 KB hostile frame must not pull anything sizeable back out of the
    // host: the answer is a constant-size rejection.
    final reject = seen.single.message as RejectMessage;
    expect(reject.encode().length, lessThan(150));
    host.close();
  });
}
