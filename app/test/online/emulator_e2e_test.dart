@Tags(['emulator'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Two-client full-MATCH end-to-end test through the REAL Firebase Emulator
/// Suite (Auth + Firestore + `firestore.rules` — NO functions emulator any
/// more).
///
/// ## Status: placeholder
///
/// The callable-era version of this test drove two [MatchApi] stacks through
/// Cloud Functions that no longer exist. Plan 16 Task 5 rewrites it for the
/// serverless model: two anonymous users, a created + joined match, the whole
/// commit-reveal roll protocol over real documents, completion, plus the
/// adversarial legs (direct-write forgeries the rules must block, and a
/// rules-passing but ILLEGAL event the honest client must freeze on — see
/// `OnlineCheatException`).
///
/// Until then this file keeps the suite wiring (`--tags emulator`, the
/// `AIGAMMON_EMULATOR` env gate used by `firebase/run-emulator-tests.ps1`) alive
/// with a single skipped test, so nothing downstream has to change when the real
/// body lands.
void main() {
  // Env gate: skip entirely unless explicitly asked to run against the emulator.
  // Trim because cmd.exe's `set VAR=1 && ...` captures a trailing space into the
  // value; treat any non-empty, non-"0" value as enabled.
  final gate = Platform.environment['AIGAMMON_EMULATOR']?.trim();
  final runEmulator = gate != null && gate.isNotEmpty && gate != '0';

  test(
    'two clients play a full match through the Firestore emulator',
    () {
      // TODO(Plan 16 Task 5): rewrite for the serverless transport.
      markTestSkipped('pending Plan 16 Task 5 (serverless two-client E2E)');
    },
    skip: runEmulator
        ? 'pending Plan 16 Task 5 (serverless two-client E2E)'
        : 'Set AIGAMMON_EMULATOR=1 and run inside the Firebase Emulator Suite '
            '(see firebase/run-emulator-tests.ps1).',
  );
}
