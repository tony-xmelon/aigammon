// Tests for the generated Kazaross-XG2 match equity table.
//
// These exercise the PUBLIC API (MatchEquityTable) and guard against
// regeneration drift by re-parsing the vendored XML with the shared tool
// parser and comparing every entry. NOT engine-tagged: runs in the default
// (non-engine) `dart test` pass.
import 'dart:io';

import 'package:engine_bindings/engine_bindings.dart';
import 'package:test/test.dart';

// Test files may import tool/ helpers; the drift guard reuses the exact
// parsing logic the generator used, so any divergence is caught here.
import '../tool/met_parser.dart';

/// Loads the vendored XML regardless of whether the test runner's cwd is the
/// package root or the repo root.
String _readVendoredXml() {
  const rel = 'assets/met/Kazaross-XG2.xml';
  for (final candidate in [
    rel,
    'packages/engine_bindings/$rel',
  ]) {
    final f = File(candidate);
    if (f.existsSync()) return f.readAsStringSync();
  }
  fail('Could not locate $rel from cwd ${Directory.current.path}');
}

void main() {
  group('MatchEquityTable', () {
    test('maxAway matches the gnubg table length', () {
      expect(MatchEquityTable.maxAway, 25);
    });

    test('preCrawford(1, 1) is an even game', () {
      expect(MatchEquityTable.preCrawford(1, 1), closeTo(0.5, 1e-9));
    });

    test('pre-Crawford table is symmetric (t[a][b] + t[b][a] == 1)', () {
      const n = MatchEquityTable.maxAway;
      for (var a = 1; a <= n; a++) {
        for (var b = 1; b <= n; b++) {
          final sum = MatchEquityTable.preCrawford(a, b) +
              MatchEquityTable.preCrawford(b, a);
          expect(sum, closeTo(1.0, 1e-6),
              reason: 'symmetry failed at ($a, $b)');
        }
      }
    });

    test('pre-Crawford is strictly monotonic', () {
      // The Kazaross-XG2 data has no ties (verified): being further away is
      // strictly worse, so for fixed opponent-away `b`, equity strictly
      // decreases as own-away `a` grows; for fixed own-away `a`, equity
      // strictly increases as opponent-away `b` grows.
      const n = MatchEquityTable.maxAway;
      for (var b = 1; b <= n; b++) {
        for (var a = 2; a <= n; a++) {
          expect(
            MatchEquityTable.preCrawford(a, b),
            lessThan(MatchEquityTable.preCrawford(a - 1, b)),
            reason: 'not strictly decreasing in a at ($a, $b)',
          );
        }
      }
      for (var a = 1; a <= n; a++) {
        for (var b = 2; b <= n; b++) {
          expect(
            MatchEquityTable.preCrawford(a, b),
            greaterThan(MatchEquityTable.preCrawford(a, b - 1)),
            reason: 'not strictly increasing in b at ($a, $b)',
          );
        }
      }
    });

    test('post-Crawford values match the data (trailer 1-away is even)', () {
      // Asserted from the vendored data, not from prior belief: the 1-away
      // trailer post-Crawford entry is exactly 0.5 (double match point), and
      // equity decreases as the trailer falls further behind.
      expect(MatchEquityTable.postCrawford(1), closeTo(0.5, 1e-9));
      expect(MatchEquityTable.postCrawford(2), closeTo(0.48803, 1e-9));
      const n = MatchEquityTable.maxAway;
      for (var away = 2; away <= n; away++) {
        expect(
          MatchEquityTable.postCrawford(away),
          lessThan(MatchEquityTable.postCrawford(away - 1)),
          reason: 'post-Crawford not strictly decreasing at away=$away',
        );
      }
    });

    test('out-of-range arguments throw ArgumentError', () {
      expect(() => MatchEquityTable.preCrawford(0, 5), throwsArgumentError);
      expect(() => MatchEquityTable.preCrawford(26, 5), throwsArgumentError);
      expect(() => MatchEquityTable.preCrawford(5, 0), throwsArgumentError);
      expect(() => MatchEquityTable.preCrawford(5, 26), throwsArgumentError);
      expect(() => MatchEquityTable.postCrawford(0), throwsArgumentError);
      expect(() => MatchEquityTable.postCrawford(26), throwsArgumentError);
    });

    test('regeneration drift guard: constants match the vendored XML', () {
      final parsed = parseMetXml(_readVendoredXml());
      expect(parsed.length, MatchEquityTable.maxAway,
          reason: 'length/maxAway drift');

      for (var a = 1; a <= parsed.length; a++) {
        for (var b = 1; b <= parsed.length; b++) {
          expect(
            MatchEquityTable.preCrawford(a, b),
            parsed.preCrawford[a - 1][b - 1],
            reason: 'pre-Crawford drift at ($a, $b)',
          );
        }
        expect(
          MatchEquityTable.postCrawford(a),
          parsed.postCrawford[a - 1],
          reason: 'post-Crawford drift at away=$a',
        );
      }
    });
  });
}
