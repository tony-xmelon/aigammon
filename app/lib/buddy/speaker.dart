import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Whether this platform has a TTS engine worth talking to.
///
/// The same shape, and the same reason, as `isFirebaseSupportedPlatform` in
/// `lib/analytics/firebase_config.dart`: `defaultTargetPlatform` rather than
/// `dart:io`, so it is available everywhere and overridable in tests via
/// `debugDefaultTargetPlatformOverride` — which is what lets
/// `test/buddy/speaker_test.dart` prove Windows never reaches the plugin.
///
/// Buddy Mode as a whole is mobile-only (camera, microphone, a phone propped
/// over a board), so this is not a degradation of a desktop feature; it is the
/// guard that keeps a desktop `flutter run` and the whole widget-test suite
/// away from a plugin whose Windows implementation does not exist.
bool get isBuddySpeechSupportedPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// One thing Buddy says: what the phone speaks, and what the screen shows.
///
/// **Two renderings of one line, deliberately.** The spec requires every spoken
/// line to be mirrored on screen — for accessibility, and for the noisy room
/// the mode is designed to be played in — and the two channels do not want the
/// same characters. A transcript wants the notation the score sheet already
/// uses, "13/8*"; a platform TTS engine reads that as a fraction followed by
/// the word "asterisk". So [text] is notation and [speech] is words, they carry
/// identical content, and [speech] defaults to [text] for the many lines
/// (dice, objections, cube talk) that are already prose.
@immutable
class BuddyLine {
  const BuddyLine(this.text, {String? speech}) : speech = speech ?? text;

  /// What the on-screen transcript shows.
  final String text;

  /// What is handed to the TTS engine.
  final String speech;

  @override
  bool operator ==(Object other) =>
      other is BuddyLine && other.text == text && other.speech == speech;

  @override
  int get hashCode => Object.hash(text, speech);

  @override
  String toString() =>
      text == speech ? 'BuddyLine($text)' : 'BuddyLine($text | $speech)';
}

/// How Buddy words a play — the spec's user-facing setting.
enum BuddyPhrasing {
  /// Notation, the way two players at a board actually talk: "13/8, 24/22".
  terse,

  /// The same content spelled out: "Move one checker from 13 to 8, and one
  /// from 24 to 22."
  friendly;

  /// Renders [move] for both channels.
  ///
  /// **Points are named in the app's single White-based 1-24 frame**, the one
  /// `CheckerMove.toString` produces and the score sheet, the game record and
  /// the analysis screen all display — for BOTH sides, exactly as they do
  /// today. Per-player numbering was considered and rejected: Buddy's spoken
  /// line, the on-screen transcript, the belief mirror and the score sheet of
  /// the very same match are all in front of the user at once, and a spoken
  /// "eight" that reads as "17" two centimetres away is worse than a frame the
  /// user has to learn once.
  BuddyLine describePlay(Move move) {
    final hops = _GroupedHop.of(move);
    if (hops.isEmpty) {
      return switch (this) {
        BuddyPhrasing.terse => const BuddyLine('(no play)', speech: 'no play'),
        BuddyPhrasing.friendly => const BuddyLine('No legal play.'),
      };
    }
    return switch (this) {
      BuddyPhrasing.terse => BuddyLine(
          hops.map((h) => h.notation).join(', '),
          speech: hops.map((h) => h.terseSpeech).join(', '),
        ),
      BuddyPhrasing.friendly => BuddyLine(_friendlySentence(hops)),
    };
  }

  /// Joins the clauses, eliding what English elides and no more.
  ///
  /// A clause after the first drops its verb — "…, and one from 24 to 22" —
  /// but only while the verb has not CHANGED. The play `6/off 13/8` opens on
  /// "bear", so an unconditional elision produces "bear one from 13 to 8": an
  /// instruction to take a checker off a point it cannot come off. So the verb
  /// in effect is tracked and restated whenever it changes, which is what a
  /// person does without thinking about it.
  static String _friendlySentence(List<_GroupedHop> hops) {
    final parts = <String>[];
    String? verbInEffect;
    for (final hop in hops) {
      final verb = hop.friendlyVerb;
      parts.add(hop.friendlyClause(
        withVerb: parts.isEmpty || verb != verbInEffect,
        withNoun: parts.isEmpty,
      ));
      verbInEffect = verb;
    }
    final joined = parts.length == 1
        ? parts.single
        : '${parts.take(parts.length - 1).join(', ')}, and ${parts.last}';
    return '${joined[0].toUpperCase()}${joined.substring(1)}.';
  }
}

/// Identical hops folded into one, with a count.
///
/// **Why grouping exists at all.** A doubles play is up to four hops and
/// commonly two pairs, so the ungrouped form is "24/20 24/20 13/9 13/9" — which
/// `Move.toString` produces and the score sheet shows, but which is miserable
/// to hear four times a turn and reads as a stutter in a transcript. "(2)" is
/// the standard written notation for it, and "twice" is what a player says. One
/// roll in six is doubles, so this is not an edge case.
///
/// Hops are grouped by (from, to) only, and the group is marked as a hit if ANY
/// of its members hit — matching the written convention "13/8*(2)", where one
/// blot was hit and the second checker landed on the point already made.
/// First-appearance order is preserved, so the played order still reads left to
/// right.
@immutable
class _GroupedHop {
  const _GroupedHop(this.from, this.to, this.count, {required this.isHit});

  final int from;
  final int to;
  final int count;
  final bool isHit;

  static List<_GroupedHop> of(Move move) {
    final order = <int>[];
    final counts = <int, int>{};
    final hits = <int, bool>{};
    for (final hop in move.checkerMoves) {
      final key = hop.from * 100 + hop.to + 1;
      if (!counts.containsKey(key)) order.add(key);
      counts[key] = (counts[key] ?? 0) + 1;
      hits[key] = (hits[key] ?? false) || hop.isHit;
    }
    return [
      for (final key in order)
        _GroupedHop(
          key ~/ 100,
          key % 100 - 1,
          counts[key]!,
          isHit: hits[key]!,
        ),
    ];
  }

  bool get _fromBar => from == CheckerMove.bar;
  bool get _bearsOff => to == CheckerMove.off;

  /// "13/8", "bar/22", "6/off", "24/20(2)", "13/8*" — the score sheet's
  /// characters, with the standard repeat suffix.
  String get notation {
    final f = _fromBar ? 'bar' : '${from + 1}';
    final t = _bearsOff ? 'off' : '${to + 1}';
    final repeat = count > 1 ? '($count)' : '';
    return '$f/$t${isHit ? '*' : ''}$repeat';
  }

  /// The same, in words an engine can pronounce: no slash, no asterisk, no
  /// parenthesis. "13 to 8 hitting", "bar to 22", "6 off", "24 to 20 twice".
  ///
  /// Note the ABSENCE of a comma before "hitting". Hops are comma-separated in
  /// the spoken form, so ", hit" would be heard as a third item in the list —
  /// "13 to 8, hit, 6 to 5" is three things, one of which is not a move. Bound
  /// to its hop without a comma, it can only attach to the hop it belongs to.
  String get terseSpeech {
    final f = _fromBar ? 'bar' : '${from + 1}';
    final body = _bearsOff ? '$f off' : '$f to ${to + 1}';
    return '$body$_times${isHit ? ' hitting' : ''}';
  }

  /// Which verb this hop wants. The unit [BuddyPhrasing._friendlySentence]
  /// compares to decide whether the verb has to be restated.
  String get friendlyVerb => _bearsOff ? 'bear' : 'move';

  /// This hop as one clause of a friendly sentence.
  ///
  /// [withVerb] states the verb ("move", "bear … off") rather than leaning on
  /// the one before it; [withNoun] spells "checker(s)" rather than leaving the
  /// bare count. The sentence builder turns the first on when the verb changes
  /// and the second only on the opening clause.
  String friendlyClause({required bool withVerb, required bool withNoun}) {
    final subject = withNoun
        ? '$_count ${count == 1 ? 'checker' : 'checkers'}'
        : _count;
    final body = _bearsOff
        ? '$subject off from ${from + 1}'
        : '$subject $_path';
    return '${withVerb ? '$friendlyVerb ' : ''}$body$_hitting';
  }

  String get _path => 'from ${_fromBar ? 'the bar' : from + 1} to ${to + 1}';

  String get _hitting => isHit ? ', hitting' : '';

  String get _count => switch (count) {
        1 => 'one',
        2 => 'two',
        3 => 'three',
        _ => 'four',
      };

  String get _times => switch (count) {
        1 => '',
        2 => ' twice',
        3 => ' three times',
        _ => ' four times',
      };
}

/// The plugin-facing edge of [BuddySpeaker], and the only thing in this file a
/// test cannot run: one method per platform call, so the speaker above it is
/// pure Dart and the fake below it is four lines.
abstract class BuddyTts {
  /// Language, rate and completion semantics. Called once, lazily, before the
  /// first utterance — never from a constructor, so building a speaker on a
  /// platform that then turns out not to need one costs nothing.
  Future<void> configure();

  /// Speaks [text], completing when the utterance has finished.
  Future<void> speak(String text);

  /// Cuts off whatever is being said now.
  Future<void> stop();

  Future<void> dispose();
}

/// The engine on a platform that has none. Mirrors `NoopAnalytics` and friends:
/// every call succeeds, nothing happens, no channel is touched.
class SilentBuddyTts implements BuddyTts {
  const SilentBuddyTts();

  @override
  Future<void> configure() async {}

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// [BuddyTts] over `flutter_tts`.
///
/// Constructed ONLY from [BuddySpeaker.forPlatform] and only after the platform
/// check has passed, so no desktop build ever reaches the `FlutterTts`
/// constructor — the same discipline `initializeObservability` applies to
/// `Firebase.initializeApp`.
class FlutterTtsBuddyTts implements BuddyTts {
  FlutterTtsBuddyTts([FlutterTts? tts]) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;

  @override
  Future<void> configure() async {
    // `awaitSpeakCompletion(true)` is what makes `speak` a real future rather
    // than a fire-and-forget; without it the speaker's queue would collapse and
    // every line would cut off the one before it.
    await _tts.awaitSpeakCompletion(true);
    await _tts.setLanguage(kBuddySpeechLanguage);
    await _tts.setSpeechRate(kBuddySpeechRate);
  }

  @override
  Future<void> speak(String text) => _tts.speak(text);

  @override
  Future<void> stop() => _tts.stop();

  @override
  Future<void> dispose() => _tts.stop();
}

/// The voice's language tag.
///
/// The app ships English only today (no `flutter_localizations`, no ARB files),
/// and every phrase in [BuddyPhrasing] is an English literal, so asking the
/// engine for the device's locale would mispronounce this file's own output on
/// a non-English phone rather than translate it. Revisit together with app-wide
/// localization, not before.
const String kBuddySpeechLanguage = 'en-US';

/// How fast Buddy talks, on the plugin's 0..1 scale.
///
/// **Provisional.** Platform defaults are 0.5 on Android and 0.5 on iOS, but
/// the two scales are not the same speech: the number that sounds right is a
/// property of the engine, the voice and a room with dice clattering in it, and
/// none of those can be measured from a Windows dev machine with no device
/// attached. Shipped slightly under the default on the reasoning that a line
/// misheard costs a whole turn while a line heard slowly costs a second; the
/// on-device protocol in Task 15 is where it gets a measured value.
const double kBuddySpeechRate = 0.45;

/// Buddy's voice, and the transcript that mirrors it.
///
/// Two guarantees, both of which the spec asks for by name and both of which
/// are tested:
///
///  * **Speak and mirror.** Every line Buddy says lands in [lines] and on
///    [transcript] *immediately* — before the engine has finished saying it,
///    and whether or not there is an engine at all. The mirror is pure Dart, so
///    it works identically on this Windows dev machine, in a widget test, and
///    on a phone whose user has the volume down.
///  * **One line at a time.** Utterances are serialized onto a chain rather
///    than fired at the engine as they arrive. Buddy routinely says two things
///    in a row ("You rolled 6-3." / "13/8, 24/22.") and a platform TTS engine
///    handed both at once speaks the second over the first.
///
/// An engine that throws loses its line and nothing else: a dead voice must
/// still leave a readable transcript, which is the only channel a user in a
/// loud room had anyway.
class BuddySpeaker {
  BuddySpeaker({
    BuddyTts? engine,
    this.phrasing = BuddyPhrasing.terse,
  }) : engine = engine ?? const SilentBuddyTts();

  /// The speaker this platform can actually have.
  ///
  /// **The platform check happens FIRST**, so a desktop build never constructs
  /// `FlutterTts` and never touches its channel — see
  /// [isBuddySpeechSupportedPlatform] and the desktop group in
  /// `test/buddy/speaker_test.dart`.
  factory BuddySpeaker.forPlatform({
    BuddyPhrasing phrasing = BuddyPhrasing.terse,
    @visibleForTesting BuddyTts? engineOverride,
  }) =>
      BuddySpeaker(
        engine: engineOverride ??
            (isBuddySpeechSupportedPlatform
                ? FlutterTtsBuddyTts()
                : const SilentBuddyTts()),
        phrasing: phrasing,
      );

  final BuddyTts engine;
  final _lines = <BuddyLine>[];
  final _transcript = StreamController<BuddyLine>.broadcast();

  /// How Buddy words a play. Mutable because the spec makes it a setting, and a
  /// setting changed mid-match must take effect on the next line.
  BuddyPhrasing phrasing;

  Future<void> _tail = Future.value();
  bool _configured = false;
  bool _disposed = false;

  /// Bumped by [stop]; any utterance queued under an older generation is
  /// abandoned instead of spoken into a silence the user asked for.
  int _generation = 0;

  /// Everything Buddy has said this session, oldest first.
  List<BuddyLine> get lines => List.unmodifiable(_lines);

  /// Lines as they are said. Broadcast, so a screen can attach and detach; a
  /// screen attaching late reads [lines] for the backlog.
  Stream<BuddyLine> get transcript => _transcript.stream;

  /// Says [line]: mirrors it now, speaks it when the queue reaches it.
  ///
  /// The returned future completes when this line has finished being spoken (or
  /// immediately, on a platform with no voice). Callers that simply want the
  /// line out — most of them — need not await it.
  Future<void> say(BuddyLine line) {
    if (_disposed) return Future.value();
    _lines.add(line);
    if (!_transcript.isClosed) _transcript.add(line);

    final generation = _generation;
    final utterance = _tail.then((_) async {
      if (_disposed || generation != _generation) return;
      try {
        if (!_configured) {
          _configured = true;
          await engine.configure();
        }
        await engine.speak(line.speech);
      } catch (error, stack) {
        // Swallowed on purpose, and for the same reason
        // `FirebaseAppAnalytics.logEvent` swallows: a voice that fails must not
        // take the turn down with it. The line is already on screen, which is
        // the channel that matters.
        //
        // `debugPrint('$stack')` rather than `debugPrintStack`: the latter runs
        // the trace through `FlutterError.defaultStackFilter`, which ASSERTS on
        // the `package:stack_trace` frames a test binary produces — so the
        // prettier call turns a swallowed engine failure into a thrown
        // assertion, in the one environment where the failure is reproduced on
        // purpose. A diagnostic must not be able to fail louder than the thing
        // it is reporting.
        if (kDebugMode) {
          debugPrint('Buddy could not speak "${line.speech}": $error\n$stack');
        }
      }
    });
    // The CHAIN must never carry an error forward, or one failure would poison
    // every later line. `utterance` already swallows; this is belt and braces
    // against a future edit that stops doing so.
    _tail = utterance.catchError((Object _) {});
    return utterance;
  }

  /// Convenience for a line that is already prose.
  Future<void> speak(String text) => say(BuddyLine(text));

  /// Says [move] in the current [phrasing].
  Future<void> announcePlay(Move move) => say(phrasing.describePlay(move));

  /// Cuts off the current line and abandons everything queued behind it.
  ///
  /// The transcript is NOT truncated: those lines were things Buddy said, and
  /// a user who silenced the phone mid-sentence still wants to read them.
  Future<void> stop() async {
    _generation++;
    if (_disposed) return;
    try {
      await engine.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    await _transcript.close();
    try {
      await engine.dispose();
    } catch (_) {}
  }
}
