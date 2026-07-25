/// Shared parser for gnubg match-equity-table (MET) XML files.
///
/// Used by `tool/generate_met.dart` to generate `lib/src/met.dart`, and by
/// `test/met_test.dart` as the regeneration-drift guard (the test re-parses the
/// vendored XML with this same logic and compares every value against the
/// generated constants). This file lives under `tool/` and depends on
/// `package:xml` (a DEV dependency); the generated library has zero runtime
/// dependencies.
library;

import 'package:xml/xml.dart';

/// A parsed gnubg MET: a square pre-Crawford table and a single post-Crawford
/// row, both 1-indexed by "away" score in the public API but stored 0-indexed
/// here (`preCrawford[i][j]` = equity for the player `i+1` away vs `j+1` away).
class ParsedMet {
  ParsedMet({
    required this.length,
    required this.preCrawford,
    required this.postCrawford,
  });

  /// Maximum "away" score covered by the table (gnubg `<length>`; 25 for
  /// Kazaross-XG2).
  final int length;

  /// `length` x `length` pre-Crawford equities. `preCrawford[i][j]` is the
  /// match-winning probability for the player who is `i+1` away against an
  /// opponent `j+1` away, at the start of a game.
  final List<List<double>> preCrawford;

  /// `length` post-Crawford equities. `postCrawford[i]` is the match-winning
  /// probability for the trailer who is `i+1` away at the start of a
  /// post-Crawford game.
  final List<double> postCrawford;
}

/// Parses [xmlContent] (the contents of a gnubg MET XML file) into a
/// [ParsedMet]. Throws [FormatException] if the document is structurally
/// unexpected.
ParsedMet parseMetXml(String xmlContent) {
  final doc = XmlDocument.parse(xmlContent);
  final met = doc.rootElement;
  if (met.name.local != 'met') {
    throw FormatException('Expected root element <met>, got <${met.name.local}>');
  }

  final info = _child(met, 'info');
  final length = int.parse(_child(info, 'length').innerText.trim());

  List<List<double>> parseRows(String tableTag) {
    final table = _child(met, tableTag);
    final rows = table.findElements('row').toList();
    if (rows.isEmpty) {
      throw FormatException('<$tableTag> has no <row> elements');
    }
    return [
      for (final row in rows)
        [
          for (final me in row.findElements('me'))
            double.parse(me.innerText.trim()),
        ],
    ];
  }

  final pre = parseRows('pre-crawford-table');
  final postRows = parseRows('post-crawford-table');

  // Shape validation.
  if (pre.length != length) {
    throw FormatException(
        'pre-crawford-table has ${pre.length} rows, expected $length');
  }
  for (var i = 0; i < pre.length; i++) {
    if (pre[i].length != length) {
      throw FormatException(
          'pre-crawford-table row $i has ${pre[i].length} entries, '
          'expected $length');
    }
  }
  final post = postRows.first;
  if (post.length != length) {
    throw FormatException(
        'post-crawford-table row has ${post.length} entries, expected $length');
  }

  return ParsedMet(length: length, preCrawford: pre, postCrawford: post);
}

/// Verifies orientation and internal consistency of [met], throwing
/// [StateError] if any invariant fails. Called by the generator so bad data
/// aborts generation loudly.
void validateMet(ParsedMet met, {double tolerance = 1e-9}) {
  final t = met.preCrawford;

  // The 1-away vs 1-away entry must be an even game.
  if ((t[0][0] - 0.5).abs() > tolerance) {
    throw StateError('Expected preCrawford[0][0] == 0.5, got ${t[0][0]}');
  }

  // Full symmetry: t[i][j] + t[j][i] == 1 (loser's equity is 1 minus winner's).
  for (var i = 0; i < met.length; i++) {
    for (var j = 0; j < met.length; j++) {
      final sum = t[i][j] + t[j][i];
      if ((sum - 1.0).abs() > 1e-6) {
        throw StateError(
            'Symmetry violated at ($i,$j): t[i][j]+t[j][i] = $sum (expected 1.0)');
      }
    }
  }

  // Post-Crawford: trailer 1-away must be an even (double-match-point) game.
  if ((met.postCrawford[0] - 0.5).abs() > tolerance) {
    throw StateError(
        'Expected postCrawford[0] == 0.5, got ${met.postCrawford[0]}');
  }
}

XmlElement _child(XmlElement parent, String name) {
  final el = parent.getElement(name);
  if (el == null) {
    throw FormatException('Missing <$name> under <${parent.name.local}>');
  }
  return el;
}
