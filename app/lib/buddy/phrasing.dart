/// What Buddy SAYS, with no idea how it is said.
///
/// Split out of `speaker.dart` so that naming a phrasing costs nothing but
/// `backgammon_core`. The precedent is `observed_frame.dart`, moved out of
/// `camera_frame_source.dart` in Task 13 for the identical reason: a value type
/// that everybody needs should not drag a plugin in behind it. Here the plugin
/// is `flutter_tts`, and the everybody is `lib/data/app_settings.dart` — the
/// phrasing is a persisted preference now (schema v9), and the settings layer
/// has no business importing a speech engine to hold an enum with two values
/// in it.
///
/// `speaker.dart` re-exports this file, so no import anywhere had to change.
library;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';

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

  /// Renders [dice] for both channels: "6-3" written, "6 3" spoken.
  ///
  /// **Static, because a pair of dice has one reading.** The hyphen is the
  /// score sheet's and a TTS engine says "six minus three" for it, which is
  /// the same split [describePlay] exists for — but unlike a play there is
  /// nothing here for terse and friendly to disagree about, and inventing a
  /// disagreement would change what Buddy says for no reason. Callers embed
  /// the two renderings in their own sentence, so this returns the pair
  /// rather than a finished line.
  static BuddyLine describeDice(Dice dice) => BuddyLine(
        '${dice.die1}-${dice.die2}',
        speech: '${dice.die1} ${dice.die2}',
      );

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
