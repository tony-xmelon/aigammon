/// How long a GUEST-owned roll takes to come back, over a real socket pair and
/// on the PRODUCTION clocks — and what happens to it when the host's frame
/// limiter sees the guest's three writes arrive closer together than the guest
/// sent them.
///
/// The live-play report this suite exists for: "each time the joiner rolls the
/// dice, the host plays the animation first and then delivers the result, which
/// on the joiner app looks as stuck, and a message appears that connection is
/// waiting".
///
/// The asymmetry in that report is the clue. A roll the GUEST owns is the only
/// thing in the protocol that makes the guest write a BURST: `createRoll`, then
/// `reveal`, then the `RollEvent` — three frames, the last two separated only by
/// the client's own pacer. A roll the HOST owns costs the guest a single
/// `entropy` frame, and a move costs it one event; neither bursts, and neither
/// was reported as stalling.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_play/lan_play.dart';

import 'lan_harness.dart';

void main() {
  /// Time one guest-owned roll from the button press to the guest's own fold,
  /// and report what the host saw and when.
  Future<({Duration? host, Duration? guest, Object? error})> timeGuestRoll(
      SocketPair pair) async {
    Object? seen;
    await pair.advanceUntil(() => pair.guest.awaitingHumanTurn,
        what: "the guest's pre-roll gate");
    final before = pair.lastSeq;
    final t0 = DateTime.now();
    Duration? hostSaw;
    Duration? guestSaw;
    pair.guest.rollDice();
    final deadline = t0.add(const Duration(seconds: 25));
    while (hostSaw == null || guestSaw == null) {
      if (DateTime.now().isAfter(deadline)) break;
      hostSaw ??=
          pair.host.lastSeq > before ? DateTime.now().difference(t0) : null;
      guestSaw ??=
          pair.guest.lastSeq > before ? DateTime.now().difference(t0) : null;
      // The banner the report describes goes up mid-turnaround and comes down
      // again when the roll finally lands, so it has to be caught in flight.
      seen ??= pair.guest.error;
      await tick();
    }
    // ignore: avoid_print
    print('roll turnaround: host ${hostSaw?.inMilliseconds}ms, '
        'guest ${guestSaw?.inMilliseconds}ms, error seen: $seen');
    return (host: hostSaw, guest: guestSaw, error: seen);
  }

  test('a guest-owned roll comes back promptly on production LAN clocks',
      () async {
    final pair = await SocketPair.start(
      length: 3,
      timings: const LanTimings(),
    );
    addTearDown(pair.dispose);

    final r = await timeGuestRoll(pair);
    expect(r.guest, isNotNull, reason: 'the guest never folded its own roll');
    expect(r.error, isNull,
        reason: 'a normal roll turnaround must not post a link error');
    expect(r.guest!.inMilliseconds, lessThan(1500),
        reason: 'a LAN roll must not take over a second to come back');
  });

  test('a guest-owned roll survives arrival compression at the host limiter',
      () async {
    // The guest paces its sends to 1.25x the host's stated minimum plus 2ms —
    // barely 15ms of margin on the production 50ms. A WiFi link that delays one
    // frame by more than that (a retransmit, a power-save wakeup: routinely tens
    // of milliseconds) hands the host two frames closer together than they were
    // sent. Modelled here by policing the host end harder than the guest paces,
    // which is exactly what the host sees when that happens.
    //
    // What the drop costs is the whole bug: the relay never answers a frame it
    // drops, so the guest waits out `writeTimeout` before its controller can
    // even retry — seconds of a dead board, then an error banner, per roll.
    final pair = await SocketPair.start(
      length: 3,
      timings: const LanTimings(),
      hostTimings:
          const LanTimings(frameMinInterval: Duration(milliseconds: 150)),
    );
    addTearDown(pair.dispose);

    final r = await timeGuestRoll(pair);
    expect(r.guest, isNotNull, reason: 'the guest never folded its own roll');
    expect(r.error, isNull,
        reason: 'a compressed-but-legitimate roll burst must not be dropped, '
            'and so must not post a link error');
    expect(r.guest!.inMilliseconds, lessThan(1500),
        reason: 'the roll must not wait out a write timeout');
  });
}
