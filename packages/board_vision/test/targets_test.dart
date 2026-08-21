import 'dart:io';

import 'package:board_vision/board_vision.dart';
import 'package:test/test.dart';

/// [PerceptionTargets] is a transcription of a table in the design spec, and a
/// transcription is a thing that drifts. So the test reads the table.
///
/// This is the same trick as the no-colour-literals guard in
/// `calibration_test.dart`: crude, textual, and binding. If someone lowers a
/// target here to make the corpus harness go green, this fails and names the
/// spec — which is exactly the conversation that number is supposed to force.
/// If the spec's table is renegotiated at the Task 6 gate, both move together.
void main() {
  group('the targets are the ones the spec sets', () {
    final spec = File(
      '../../docs/superpowers/specs/2026-08-02-buddy-mode-design.md',
    );

    test('the spec is where this test thinks it is', () {
      expect(spec.existsSync(), isTrue,
          reason: 'accuracy targets are the spec\'s to set; ${spec.path} is '
              'where they are written down');
    });

    /// The `≥NN%` in the first table row containing [row], anywhere in it.
    ///
    /// Anywhere rather than in the first column, because the whole line is what
    /// the caller gets from [rowFor] as well and one matching rule for both is
    /// worth more than a narrower one for each. The phrases below are row
    /// labels, so nothing else in the table says them.
    double targetIn(String row) {
      final line = spec.readAsLinesSync().firstWhere(
            (l) => l.startsWith('|') && l.contains(row),
            orElse: () => '',
          );
      expect(line, isNotEmpty, reason: 'no accuracy-table row mentions "$row"');
      final match = RegExp(r'≥(\d+)%').firstMatch(line);
      expect(match, isNotNull, reason: 'row "$row" states no ≥NN% target');
      return int.parse(match!.group(1)!) / 100.0;
    }

    test('calibration', () {
      expect(PerceptionTargets.calibrationSuccess,
          targetIn('Calibration completes'));
    });

    test('dice', () {
      expect(PerceptionTargets.dicePairRead, targetIn('Dice pair read'));
    });

    test('legal-play identification', () {
      expect(PerceptionTargets.legalPlayIdentification,
          targetIn('Legal-play identification'));
    });

    test('placement verification', () {
      expect(PerceptionTargets.placementVerification,
          targetIn('Placement verification'));
    });

    test('full-board resync', () {
      expect(PerceptionTargets.fullBoardResyncPerRegion,
          targetIn('Full-board resync'));
    });

    /// The whole first table row containing [row] — every column of it, which
    /// is the point: what the test below reads is the denominator, and that
    /// lives in the columns after the label.
    String rowFor(String row) => spec.readAsLinesSync().firstWhere(
          (l) => l.startsWith('|') && l.contains(row),
          orElse: () => '',
        );

    test('the two reshaped rows still say what an attempt is', () {
      // **The number is half the promise and the denominator is the other
      // half**, which is the whole content of the user's 2026-08-21 decision:
      // 0.95 and 0.90 did not move, what an attempt is did. A row that lost
      // its denominator would read as the per-whole-board promise the gate
      // retired, and the constants here would quietly mean something else
      // than the table does — which is the exact drift this file exists to
      // catch, one level up from the numbers.
      expect(rowFor('Placement verification'), contains('the play touches'));
      expect(rowFor('Placement verification'), contains('per dictated turn'));
      expect(rowFor('Full-board resync'), contains('per region'));
    });

    test('refusing an unreadable shot is not negotiable', () {
      // The one target with no row to read: it is not a promise about
      // answering, it is the counterweight that stops the other five being
      // gamed by answering everything. See [PerceptionTargets.expectedRefusal].
      expect(PerceptionTargets.expectedRefusal, 1.0);
    });
  });
}
