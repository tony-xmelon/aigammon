/// The one place a human-readable label gets shortened to fit.
///
/// Three call sites used to cut with a bare `substring`: the beacon's advertised
/// name, this device's hostname, and the score line's abbreviation of the other
/// player. `substring` counts UTF-16 CODE UNITS, so a cut that lands in the
/// middle of a surrogate pair — every emoji, and plenty of non-Latin scripts —
/// leaves a LONE surrogate at the end of the string. That is not a character; it
/// renders as a replacement box, and on the wire it is invalid UTF-8 that a
/// strict decoder is entitled to reject. A phone called "Anna 🎲" is an ordinary
/// name, not an edge case.
///
/// Truncating over RUNES (Unicode code points) cannot split a surrogate pair, so
/// the result is always well-formed text.
library;

/// The character appended when [truncateForDisplay] actually shortens.
const String displayEllipsis = '…';

/// [text] shortened to at most [max] characters, ellipsised when it had to cut.
///
/// Counts and cuts in RUNES, never code units, so a surrogate pair is never
/// split (see the library doc). The ellipsis is included IN the budget — the
/// result is never longer than [max] runes — so this is safe to use for a bound
/// that something downstream enforces, such as the wire protocol's
/// `maxNameLength`.
///
/// Note the budget is code points, not grapheme clusters: a ZWJ emoji sequence
/// (👩‍👩‍👧) can still lose a joiner and render as its component parts. That is a
/// cosmetic degradation of an already-degraded string, not the malformed output
/// this exists to prevent, and avoiding it would cost a dependency on
/// `package:characters` in what is otherwise a pure-Dart package.
///
/// [max] of 0 or less gives the empty string; 1 gives the bare ellipsis.
String truncateForDisplay(String text, int max) {
  if (max <= 0) return '';
  final runes = text.runes.toList(growable: false);
  if (runes.length <= max) return text;
  if (max == 1) return displayEllipsis;
  return String.fromCharCodes(runes.take(max - 1)) + displayEllipsis;
}
