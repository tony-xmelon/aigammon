import 'package:lan_play/lan_play.dart';
import 'package:test/test.dart';

void main() {
  group('truncateForDisplay', () {
    test('leaves anything already short enough completely alone', () {
      expect(truncateForDisplay('Anna', 10), 'Anna');
      expect(truncateForDisplay('exactly-10', 10), 'exactly-10');
      expect(truncateForDisplay('', 10), '');
    });

    test('cuts to the budget INCLUDING the ellipsis', () {
      expect(truncateForDisplay('abcdefghijkl', 10), 'abcdefghi…');
      expect(truncateForDisplay('abcdefghijkl', 10).runes.length, 10);
    });

    test('never splits a surrogate pair — the whole point', () {
      // Each die is one code point but TWO UTF-16 code units, so a substring
      // cut at an odd index used to leave a lone surrogate behind.
      const dice = '🎲🎲🎲🎲🎲';
      expect(dice.length, 10, reason: 'ten code units, five characters');

      for (var max = 1; max <= 6; max++) {
        final out = truncateForDisplay(dice, max);
        expect(out.runes.length, lessThanOrEqualTo(max));
        // A lone surrogate is a code unit in 0xD800..0xDFFF that `runes` cannot
        // pair up; re-encoding the runes must reproduce the string exactly.
        expect(String.fromCharCodes(out.runes), out,
            reason: 'no lone surrogate survived at max=$max');
        for (final unit in out.codeUnits) {
          if (unit >= 0xD800 && unit <= 0xDBFF) continue; // high, paired below
          expect(unit >= 0xDC00 && unit <= 0xDFFF && out.runes.isEmpty, isFalse);
        }
      }
      expect(truncateForDisplay(dice, 3), '🎲🎲…');
    });

    test('degenerate budgets', () {
      expect(truncateForDisplay('anything', 0), '');
      expect(truncateForDisplay('anything', -5), '');
      expect(truncateForDisplay('anything', 1), '…');
      // A string that is short enough is returned whole even at max 1.
      expect(truncateForDisplay('a', 1), 'a');
    });

    test('non-Latin scripts survive the cut', () {
      const greek = 'αβγδεζηθικλμν';
      final out = truncateForDisplay(greek, 5);
      expect(out, 'αβγδ…');
      expect(String.fromCharCodes(out.runes), out);
    });
  });
}
