import 'dart:async';

import 'package:aigammon_app/buddy/speaker.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [BuddyTts] that records instead of speaking, and lets a test decide when
/// each utterance "finishes".
///
/// The completion control is the point: [BuddySpeaker] serializes speech, and a
/// fake that completed instantly could not tell a serialized implementation
/// from one that fires every line at the engine at once — which on a device is
/// the difference between hearing a sentence and hearing it cut off.
class FakeBuddyTts implements BuddyTts {
  final List<String> spoken = [];
  final List<Completer<void>> pending = [];
  int configureCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;

  /// When false, [speak] returns a future the test completes via [finishNext].
  bool autoComplete = true;

  /// Thrown by the next [speak] call, once.
  Object? failNext;

  /// Thrown by the next [configure] call, once. The call is still COUNTED —
  /// the point of the tests that use it is how many attempts were made.
  Object? failNextConfigure;

  @override
  Future<void> configure() async {
    configureCalls++;
    final failure = failNextConfigure;
    if (failure != null) {
      failNextConfigure = null;
      throw failure;
    }
  }

  @override
  Future<void> speak(String text) {
    spoken.add(text);
    final failure = failNext;
    if (failure != null) {
      failNext = null;
      return Future.error(failure);
    }
    if (autoComplete) return Future.value();
    final completer = Completer<void>();
    pending.add(completer);
    return completer.future;
  }

  void finishNext() => pending.removeAt(0).complete();

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> dispose() async => disposeCalls++;
}

Move play(List<CheckerMove> hops) => Move(hops);

/// Points are named the way the rest of the app names them: the White-based
/// 1-24 frame `CheckerMove.toString` and the score sheet already use, so the
/// spoken line, the transcript and the score sheet cannot disagree. These
/// helpers convert a 1-24 point number to the 0-23 index the core stores.
CheckerMove hop(int from, int to, {bool hit = false}) =>
    CheckerMove(from - 1, to - 1, isHit: hit);
CheckerMove fromBar(int to, {bool hit = false}) =>
    CheckerMove(CheckerMove.bar, to - 1, isHit: hit);
CheckerMove bearOff(int from) => CheckerMove(from - 1, CheckerMove.off);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('terse phrasing', () {
    test('a plain two-hop play is the score sheet notation, comma-separated',
        () {
      final line = BuddyPhrasing.terse.describePlay(
        play([hop(13, 8), hop(24, 22)]),
      );
      expect(line.text, '13/8, 24/22');
    });

    test('a hit keeps the asterisk on screen and says the word aloud', () {
      final line = BuddyPhrasing.terse.describePlay(
        play([hop(13, 8, hit: true)]),
      );
      expect(line.text, '13/8*');
      expect(line.speech, '13 to 8 hitting');
    });

    test('the hit marker binds to its hop, not to the list of hops', () {
      // Hops are comma-separated aloud, so ", hit" between two of them is
      // heard as a third item — "13 to 8, hit, 6 to 5" is three things, and
      // one of them is not a move.
      expect(
        BuddyPhrasing.terse
            .describePlay(play([hop(13, 8, hit: true), hop(6, 5)])).speech,
        '13 to 8 hitting, 6 to 5',
      );
    });

    test('a bar entry and a bear-off use the core\'s own sentinel names', () {
      expect(BuddyPhrasing.terse.describePlay(play([fromBar(22)])).text,
          'bar/22');
      expect(BuddyPhrasing.terse.describePlay(play([bearOff(6)])).text, '6/off');
    });

    test('a doubles play groups its repeats rather than repeating itself', () {
      final line = BuddyPhrasing.terse.describePlay(play([
        hop(24, 20),
        hop(24, 20),
        hop(13, 9),
        hop(13, 9),
      ]));
      expect(line.text, '24/20(2), 13/9(2)');
      expect(line.speech, '24 to 20 twice, 13 to 9 twice');
    });

    test('a dance says so instead of falling silent', () {
      final line = BuddyPhrasing.terse.describePlay(Move.none);
      expect(line.text, '(no play)');
      expect(line.speech, 'no play');
    });

    test('the spoken form never contains a slash or an asterisk', () {
      // "13/8" handed to a platform TTS engine is read as a fraction, and "*"
      // is read as "asterisk" or dropped. The transcript wants notation; the
      // engine wants words. Same content, two renderings.
      for (final move in [
        play([hop(13, 8), hop(24, 22)]),
        play([hop(13, 8, hit: true)]),
        play([fromBar(22)]),
        play([bearOff(6)]),
        play([hop(24, 20), hop(24, 20), hop(13, 9), hop(13, 9)]),
        Move.none,
      ]) {
        final speech = BuddyPhrasing.terse.describePlay(move).speech;
        expect(speech, isNot(contains('/')), reason: 'for $move');
        expect(speech, isNot(contains('*')), reason: 'for $move');
        expect(speech, isNot(contains('(')), reason: 'for $move');
      }
    });
  });

  group('a pair of dice', () {
    test('is the score sheet hyphen written and two numbers spoken', () {
      final line = BuddyPhrasing.describeDice(Dice(6, 3));
      expect(line.text, '6-3');
      expect(line.speech, '6 3',
          reason: 'an engine reads the hyphen as a subtraction');
    });

    test('reads the same in either phrasing', () {
      // Unlike a play, a roll has nothing for terse and friendly to disagree
      // about — the helper is static so that a future edit has to decide to
      // make them disagree rather than drift into it.
      for (final dice in [Dice(6, 3), Dice(4, 4), Dice(1, 2)]) {
        expect(BuddyPhrasing.describeDice(dice).text,
            '${dice.die1}-${dice.die2}');
        expect(BuddyPhrasing.describeDice(dice).speech,
            '${dice.die1} ${dice.die2}');
      }
    });
  });

  group('friendly phrasing', () {
    test('spells the plain play in words', () {
      final line = BuddyPhrasing.friendly.describePlay(
        play([hop(13, 8), hop(24, 22)]),
      );
      expect(line.text, 'Move one checker from 13 to 8, and one from 24 to 22.');
      expect(line.speech, line.text,
          reason: 'friendly phrasing is already words — nothing to re-render');
    });

    test('names the hit', () {
      expect(
        BuddyPhrasing.friendly.describePlay(play([hop(13, 8, hit: true)])).text,
        'Move one checker from 13 to 8, hitting.',
      );
    });

    test('names the bar', () {
      expect(
        BuddyPhrasing.friendly.describePlay(play([fromBar(22), hop(13, 11)])).text,
        'Move one checker from the bar to 22, and one from 13 to 11.',
      );
    });

    test('bears off with the verb a player would use', () {
      expect(
        BuddyPhrasing.friendly.describePlay(play([bearOff(6), bearOff(6)])).text,
        'Bear two checkers off from 6.',
      );
      expect(
        BuddyPhrasing.friendly.describePlay(play([hop(13, 8), bearOff(6)])).text,
        'Move one checker from 13 to 8, and bear one off from 6.',
      );
    });

    test('an elided clause never inherits the wrong verb', () {
      // The bug this pins: clauses after the first drop their verb, which is
      // right only while the verb has not changed. Lead with a bear-off and the
      // elision turns the next hop into "bear one from 13 to 8" — an
      // instruction to take a checker off a point it cannot come off.
      expect(
        BuddyPhrasing.friendly.describePlay(play([bearOff(6), hop(13, 8)])).text,
        'Bear one checker off from 6, and move one from 13 to 8.',
      );
      // And back again: the verb in effect is the most recent one spoken, not
      // the one the sentence opened with.
      expect(
        BuddyPhrasing.friendly
            .describePlay(play([hop(13, 8), bearOff(6), hop(5, 3)])).text,
        'Move one checker from 13 to 8, bear one off from 6, and move one '
        'from 5 to 3.',
      );
      // Two bear-offs in a row DO elide — the verb has not changed.
      expect(
        BuddyPhrasing.friendly
            .describePlay(play([bearOff(6), bearOff(5)])).text,
        'Bear one checker off from 6, and one off from 5.',
      );
    });

    test('counts the checkers on a doubles play instead of repeating hops', () {
      expect(
        BuddyPhrasing.friendly.describePlay(play([
          hop(24, 20),
          hop(24, 20),
          hop(13, 9),
          hop(13, 9),
        ])).text,
        'Move two checkers from 24 to 20, and two from 13 to 9.',
      );
    });

    test('a dance is a sentence too', () {
      expect(BuddyPhrasing.friendly.describePlay(Move.none).text,
          'No legal play.');
    });
  });

  group('the mirror', () {
    test('every spoken line lands in the transcript, in order', () async {
      final tts = FakeBuddyTts();
      final speaker = BuddySpeaker(engine: tts);
      addTearDown(speaker.dispose);

      await speaker.speak('You rolled 6-3.');
      await speaker.announcePlay(play([hop(13, 8), hop(24, 22)]));

      expect(speaker.lines.map((l) => l.text).toList(),
          ['You rolled 6-3.', '13/8, 24/22']);
      expect(tts.spoken, ['You rolled 6-3.', '13 to 8, 24 to 22']);
    });

    test('the transcript stream carries the line before the engine finishes',
        () async {
      final tts = FakeBuddyTts()..autoComplete = false;
      final speaker = BuddySpeaker(engine: tts);
      addTearDown(speaker.dispose);

      final seen = <String>[];
      speaker.transcript.listen((l) => seen.add(l.text));

      final spoken = speaker.speak('Your roll.');
      await pumpEventQueue();

      // On screen already; still coming out of the phone. A transcript that
      // waited for the engine would lag every line by its whole utterance.
      expect(seen, ['Your roll.']);
      tts.finishNext();
      await spoken;
    });

    test('lines are spoken one at a time, never overlapped', () async {
      final tts = FakeBuddyTts()..autoComplete = false;
      final speaker = BuddySpeaker(engine: tts);
      addTearDown(speaker.dispose);

      final first = speaker.speak('I rolled 5-2.');
      final second = speaker.speak('Play 13/8, 24/22.');
      await pumpEventQueue();

      expect(tts.spoken, ['I rolled 5-2.'],
          reason: 'the second line must wait for the first to finish');
      tts.finishNext();
      await first;
      await pumpEventQueue();
      expect(tts.spoken.length, 2);
      tts.finishNext();
      await second;
    });

    test('an engine that throws loses its line, not the queue', () async {
      final tts = FakeBuddyTts()..failNext = StateError('engine died');
      final speaker = BuddySpeaker(engine: tts);
      addTearDown(speaker.dispose);

      await speaker.speak('first');
      await speaker.speak('second');

      expect(tts.spoken, ['first', 'second']);
      expect(speaker.lines.map((l) => l.text).toList(), ['first', 'second'],
          reason: 'a dead voice must still leave a readable transcript');
    });

    test('the engine is configured once, lazily, on the first line', () async {
      final tts = FakeBuddyTts();
      final speaker = BuddySpeaker(engine: tts);
      addTearDown(speaker.dispose);

      expect(tts.configureCalls, 0,
          reason: 'constructing a speaker must not touch the engine');
      await speaker.speak('one');
      await speaker.speak('two');
      expect(tts.configureCalls, 1);
    });

    test('phrasing can change mid-session, as the setting can', () async {
      final tts = FakeBuddyTts();
      final speaker = BuddySpeaker(engine: tts);
      addTearDown(speaker.dispose);

      await speaker.announcePlay(play([hop(13, 8)]));
      speaker.phrasing = BuddyPhrasing.friendly;
      await speaker.announcePlay(play([hop(13, 8)]));

      expect(speaker.lines.map((l) => l.text).toList(),
          ['13/8', 'Move one checker from 13 to 8.']);
    });

    test('stop() silences the engine and drops the queue, keeping the text',
        () async {
      final tts = FakeBuddyTts()..autoComplete = false;
      final speaker = BuddySpeaker(engine: tts);
      addTearDown(speaker.dispose);

      final first = speaker.speak('long line');
      unawaited(speaker.speak('queued line'));
      await pumpEventQueue();

      await speaker.stop();
      tts.finishNext();
      await first;
      await pumpEventQueue();

      expect(tts.stopCalls, 1);
      expect(tts.spoken, ['long line'],
          reason: 'the queued line was abandoned, not spoken after the stop');
      expect(speaker.lines.length, 2,
          reason: 'both lines were still SAID by Buddy, so both stay on screen');
    });
  });

  group('configuration', () {
    test('the engine is configured once, not once per line', () async {
      final tts = FakeBuddyTts();
      final speaker = BuddySpeaker(engine: tts);
      addTearDown(speaker.dispose);

      await speaker.speak('one');
      await speaker.speak('two');
      await speaker.speak('three');

      expect(tts.configureCalls, 1);
    });

    test('a configure that throws is retried on the next line', () async {
      // The guarantee at stake is `awaitSpeakCompletion(true)`, which
      // configure is the only place that applies. A speaker that marked itself
      // configured BEFORE the call would take a single transient failure — a
      // channel not up yet at the first line of a session — and spend the rest
      // of the match speaking through an engine whose `speak` returns
      // immediately: the queue below stops serializing and Buddy talks over
      // itself, with nothing thrown and nothing logged outside debug mode.
      final tts = FakeBuddyTts()..failNextConfigure = StateError('no channel');
      final speaker = BuddySpeaker(engine: tts);
      addTearDown(speaker.dispose);

      await speaker.speak('the line that pays for it');
      expect(tts.configureCalls, 1);
      expect(tts.spoken, isEmpty,
          reason: 'the failure came before speak, and is swallowed');

      await speaker.speak('the next line');
      expect(tts.configureCalls, 2, reason: 'the flag never latched');
      expect(tts.spoken, ['the next line']);

      // And having succeeded, it latches: no third attempt.
      await speaker.speak('a third line');
      expect(tts.configureCalls, 2);
      expect(tts.spoken, ['the next line', 'a third line']);
    });

    test('a failed configure still leaves the line on screen', () async {
      // The transcript is the channel that matters when the voice is broken.
      final tts = FakeBuddyTts()..failNextConfigure = StateError('no channel');
      final speaker = BuddySpeaker(engine: tts);
      addTearDown(speaker.dispose);

      await speaker.speak('You rolled 6-3.');

      expect(speaker.lines.map((l) => l.text).toList(), ['You rolled 6-3.']);
    });

    test('a failed first line does not wedge the queue behind it', () async {
      // Deliberately NOT claimed as proof that the "one line at a time"
      // guarantee survives: this fake serializes on its own completers, so it
      // would serialize with or without `awaitSpeakCompletion`. Only
      // `configureCalls` above can see that difference. What this pins is the
      // other half — that the line lost to a failed configure does not take
      // the rest of the session's queue down with it.
      final tts = FakeBuddyTts()
        ..failNextConfigure = StateError('no channel')
        ..autoComplete = false;
      final speaker = BuddySpeaker(engine: tts);
      addTearDown(speaker.dispose);

      await speaker.speak('lost line');

      unawaited(speaker.speak('first real line'));
      unawaited(speaker.speak('second real line'));
      await pumpEventQueue();

      expect(tts.spoken, ['first real line'],
          reason: 'the second line waits for the first to finish');
      tts.finishNext();
      await pumpEventQueue();
      expect(tts.spoken, ['first real line', 'second real line']);
      tts.finishNext();
    });
  });

  group('the desktop guard', () {
    /// Every message on the TTS channel, so the assertion is about what was
    /// ATTEMPTED and not merely about what came back — the same technique
    /// test/analytics/desktop_guard_test.dart uses for FlutterFire.
    late List<String> channelCalls;

    setUp(() {
      channelCalls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('flutter_tts'),
              (call) async {
        channelCalls.add(call.method);
        return null;
      });
    });

    test('is true only on Android and iOS', () {
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          isBuddySpeechSupportedPlatform,
          platform == TargetPlatform.android || platform == TargetPlatform.iOS,
          reason: 'unexpected verdict for $platform',
        );
      }
    });

    for (final platform in const [
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    ]) {
      test('$platform gets a silent engine and touches no TTS channel',
          () async {
        debugDefaultTargetPlatformOverride = platform;
        final speaker = BuddySpeaker.forPlatform();
        addTearDown(speaker.dispose);

        expect(speaker.engine, isA<SilentBuddyTts>());
        await speaker.speak('anything');
        await speaker.stop();

        expect(channelCalls, isEmpty);
      });
    }

    test('the transcript still works on desktop — it is pure Dart', () async {
      // Buddy Mode is mobile-only, but its SCREEN is built and widget-tested on
      // this Windows dev machine, and a transcript that only filled up on a
      // phone would be untestable there.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final speaker = BuddySpeaker.forPlatform();
      addTearDown(speaker.dispose);

      await speaker.announcePlay(play([hop(13, 8), hop(24, 22)]));

      expect(speaker.lines.single.text, '13/8, 24/22');
      expect(channelCalls, isEmpty);
    });
  });
}
