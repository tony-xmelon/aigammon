import 'dart:typed_data';

import 'package:aigammon_app/buddy/dice_sound_trigger.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_mic.dart';

/// A run of [count] hops all at [db], starting at [from].
List<AmplitudeSample> _level(
  double db, {
  required int count,
  Duration from = Duration.zero,
  Duration hop = const Duration(milliseconds: 16),
}) =>
    <AmplitudeSample>[
      for (var i = 0; i < count; i++)
        AmplitudeSample.decibels(db, from + hop * i),
    ];

/// The whole script, offered in order; the times each hint fired at.
List<Duration> _run(DiceSoundTrigger trigger, List<AmplitudeSample> script) {
  final fired = <Duration>[];
  for (final sample in script) {
    if (trigger.offer(sample)) fired.add(sample.at);
  }
  return fired;
}

void main() {
  group('the transient signature', () {
    test('dice landing in a quiet room fire one hint', () {
      final trigger = DiceSoundTrigger();
      final fired = _run(trigger, diceClatter());
      expect(fired, hasLength(1),
          reason: 'one throw is one hint, not one per bounce');
      expect(trigger.fired, 1);
    });

    test('the hint fires when the noise STOPS, not when it starts', () {
      // The board is worth looking at once the dice have come to rest, so the
      // hint is deliberately at the END of the transient.
      final trigger = DiceSoundTrigger();
      final script = diceClatter();
      final attackAt = script[60].at;
      final fired = _run(trigger, script);
      expect(fired.single, greaterThan(attackAt));
      expect(fired.single - attackAt, lessThanOrEqualTo(kDiceDecayWindow));
    });

    test('a quiet room on its own never fires', () {
      final trigger = DiceSoundTrigger();
      expect(_run(trigger, _level(-60, count: 400)), isEmpty);
    });

    test('sustained speech never fires, however loud', () {
      // The discrimination this detector exists for: an impulse comes and goes
      // inside the decay window, a talking voice does not.
      final trigger = DiceSoundTrigger();
      final script = _level(-60, count: 60);
      script.addAll(_level(-30,
          count: 200, from: script.last.at + const Duration(milliseconds: 16)));
      expect(_run(trigger, script), isEmpty);
    });

    test('a room of speech that pauses between words still never fires', () {
      // Syllables: loud, briefly quieter, loud again. Each onset may START a
      // candidate transient; none of them decays back to the pre-speech floor,
      // and the running floor climbs to meet the room besides.
      final trigger = DiceSoundTrigger();
      final script = _level(-60, count: 60);
      var at = script.last.at + const Duration(milliseconds: 16);
      for (var word = 0; word < 12; word++) {
        script.addAll(_level(-30, count: 20, from: at));
        at += const Duration(milliseconds: 16) * 20;
        script.addAll(_level(-45, count: 6, from: at));
        at += const Duration(milliseconds: 16) * 6;
      }
      expect(_run(trigger, script), isEmpty);
    });

    test('a transient too quiet to be dice on a table does not fire', () {
      // Twelve decibels over a very quiet room is still nothing: a rustle at
      // -55 dBFS is not a die landing, and the absolute floor is what says so.
      final trigger = DiceSoundTrigger();
      expect(_run(trigger, diceClatter(room: -80, peak: -55)), isEmpty);
      expect(_run(DiceSoundTrigger(), diceClatter(room: -80, peak: -30)),
          hasLength(1),
          reason: 'the same quiet room with a real throw in it still fires');
    });

    test('a rise that is not sharp does not fire', () {
      // A fade-in reaches the same level without ever being an attack: the hop
      // before the peak has to still be in the quiet room.
      final trigger = DiceSoundTrigger();
      final script = _level(-60, count: 60);
      var at = script.last.at + const Duration(milliseconds: 16);
      for (var db = -58.0; db <= -25; db += 2) {
        script.add(AmplitudeSample.decibels(db, at));
        at += const Duration(milliseconds: 16);
      }
      script.addAll(_level(-60, count: 30, from: at));
      expect(_run(trigger, script), isEmpty);
    });

    test('two throws in quick succession are held to one hint', () {
      final trigger = DiceSoundTrigger();
      final first = diceClatter(tailHops: 4);
      final second = diceClatter(roomHops: 4, tailHops: 30).map((s) =>
          AmplitudeSample.decibels(
              s.decibels, s.at + first.last.at + const Duration(milliseconds: 16)));
      final fired = _run(trigger, <AmplitudeSample>[...first, ...second]);
      expect(fired, hasLength(1),
          reason: 'the refractory bounds how often a hint can be spent');
      expect(kDiceRefractory, greaterThan(kDiceDecayWindow));
    });

    test('the decay window is what rejects speech, and nothing else is', () {
      // The contrast that proves the constant is load-bearing rather than
      // decorative: the SAME sustained script fires the moment the window is
      // widened past the length of a spoken phrase.
      List<AmplitudeSample> speech() {
        final script = _level(-60, count: 60);
        script.addAll(_level(-30,
            count: 200,
            from: script.last.at + const Duration(milliseconds: 16)));
        script.addAll(_level(-60,
            count: 30,
            from: script.last.at + const Duration(milliseconds: 16)));
        return script;
      }

      expect(_run(DiceSoundTrigger(), speech()), isEmpty);
      expect(
          _run(
              DiceSoundTrigger(
                decayWindow: const Duration(seconds: 5),
                // The floor would otherwise climb to meet the speech and stop
                // it being an attack at all, which is a second defence; this
                // isolates the first.
                floorTimeConstant: const Duration(minutes: 1),
              ),
              speech()),
          isNotEmpty,
          reason: 'a window long enough to swallow a sentence swallows one');
    });

    test('the absolute floor is what rejects a rustle, and nothing else is',
        () {
      expect(_run(DiceSoundTrigger(), diceClatter(room: -80, peak: -55)), isEmpty);
      expect(
          _run(DiceSoundTrigger(minimumDecibels: -100),
              diceClatter(room: -80, peak: -55)),
          hasLength(1),
          reason: 'the same script clears every other test in the signature');
    });

    test('a throw after the refractory has passed fires again', () {
      final trigger = DiceSoundTrigger();
      final first = diceClatter();
      final gap = first.last.at + const Duration(seconds: 2);
      final second = diceClatter()
          .map((s) => AmplitudeSample.decibels(s.decibels, s.at + gap));
      expect(_run(trigger, <AmplitudeSample>[...first, ...second]), hasLength(2));
    });
  });

  group('the room floor', () {
    test('follows a room that got louder, so its own noise stops firing', () {
      // A television switched on raises the floor within a couple of seconds;
      // after that its bursts are no longer twelve decibels over anything.
      final trigger = DiceSoundTrigger();
      _run(trigger, _level(-60, count: 60));
      expect(trigger.roomFloorDecibels, closeTo(-60, 0.5));
      _run(trigger, _level(-35, count: 400, from: const Duration(seconds: 1)));
      expect(trigger.roomFloorDecibels, greaterThan(-40),
          reason: 'six seconds of a loud room is the new normal');
    });

    test('a sample out of order does not move the floor backwards', () {
      final trigger = DiceSoundTrigger();
      _run(trigger, _level(-60, count: 30));
      final floor = trigger.roomFloorDecibels;
      trigger.offer(AmplitudeSample.decibels(-10, Duration.zero));
      expect(trigger.roomFloorDecibels, floor);
    });

    test('reset forgets the room and the refractory alike', () {
      final trigger = DiceSoundTrigger();
      _run(trigger, diceClatter());
      expect(trigger.fired, 1);
      trigger.reset();
      expect(trigger.roomFloorDecibels, isNull);
      expect(trigger.fired, 0);
    });
  });

  group('PcmAmplitudeMeter', () {
    /// [count] 16-bit little-endian samples, all at [value].
    Uint8List pcm(int value, int count) {
      final bytes = Uint8List(count * 2);
      ByteData.view(bytes.buffer);
      for (var i = 0; i < count; i++) {
        bytes.buffer.asByteData().setInt16(i * 2, value, Endian.little);
      }
      return bytes;
    }

    test('full-scale samples read as 0 dBFS and silence as the floor', () {
      final meter = PcmAmplitudeMeter();
      final loud = meter.add(pcm(32767, kAmplitudeHopSamples));
      expect(loud, hasLength(1));
      expect(loud.single.decibels, closeTo(0, 0.1));

      final quiet = meter.add(pcm(0, kAmplitudeHopSamples));
      expect(quiet.single.decibels, lessThan(-100),
          reason: 'digital silence must not be a divide-by-zero');
    });

    test('the clock is the SAMPLE COUNT, not a wall clock', () {
      // The detector's timing has to come out of the audio itself, or a
      // scheduler hiccup reads as a transient.
      final meter = PcmAmplitudeMeter();
      final out = meter.add(pcm(1000, kAmplitudeHopSamples * 3));
      expect(out, hasLength(3));
      expect(out[0].at, Duration.zero);
      final hop = Duration(
          microseconds: kAmplitudeHopSamples * 1000000 ~/ kMicSampleRate);
      expect(out[1].at, hop);
      expect(out[2].at, hop * 2);
    });

    test('a part-hop is carried over to the next chunk, never dropped', () {
      final meter = PcmAmplitudeMeter();
      expect(meter.add(pcm(1000, kAmplitudeHopSamples - 10)), isEmpty);
      expect(meter.add(pcm(1000, 10)), hasLength(1));
    });

    test('an odd byte count does not lose the trailing half-sample', () {
      final meter = PcmAmplitudeMeter();
      final chunk = Uint8List(kAmplitudeHopSamples * 2 + 1);
      expect(meter.add(chunk), hasLength(1));
      expect(meter.add(Uint8List(1)), isEmpty,
          reason: 'the stray byte joined the next one to make a sample');
    });
  });

  group('DiceSoundListener', () {
    test('a refused microphone reports refused and hints nothing', () async {
      var looks = 0;
      final source = FakeMicSource(opening: MicOpening.refused);
      final listener =
          DiceSoundListener(source: source, onLookNow: () => looks++);

      expect(await listener.start(), MicOpening.refused);
      expect(listener.state, MicOpening.refused);
      expect(looks, 0);
      expect(listener.hintsFired, 0);
      await listener.stop();
    });

    test('a source that throws is unavailable rather than an error', () async {
      final listener = DiceSoundListener(
        source: FakeMicSource(throwOnOpen: true),
        onLookNow: () {},
      );
      expect(await listener.start(), MicOpening.unavailable);
    });

    test('a listening microphone turns a throw into exactly one look', () async {
      var looks = 0;
      final source = FakeMicSource();
      final listener =
          DiceSoundListener(source: source, onLookNow: () => looks++);
      expect(await listener.start(), MicOpening.listening);

      for (final sample in diceClatter()) {
        source.emit(sample);
      }
      await Future<void>.delayed(Duration.zero);

      expect(looks, 1);
      expect(listener.hintsFired, 1);
      await listener.stop();
      expect(source.closed, isTrue);
    });

    test('nothing is heard after stop', () async {
      var looks = 0;
      final source = FakeMicSource();
      final listener =
          DiceSoundListener(source: source, onLookNow: () => looks++);
      await listener.start();
      await listener.stop();
      for (final sample in diceClatter()) {
        source.emit(sample);
      }
      await Future<void>.delayed(Duration.zero);
      expect(looks, 0);
    });

    test('starting twice does not open a second microphone', () async {
      final source = FakeMicSource();
      final listener = DiceSoundListener(source: source, onLookNow: () {});
      await listener.start();
      await listener.start();
      expect(source.opens, 1);
      await listener.stop();
    });
  });
}
