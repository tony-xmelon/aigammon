#!/usr/bin/env bash
# Linux equivalent of run-emulator-tests.ps1's in-emulator step, for CI.
#
# `firebase emulators:exec ... "bash ./ci-emulator-suites.sh"` runs this with the
# emulator suite already up and the working directory set to firebase/ (the
# Firebase project dir). Paths below are therefore relative to firebase/.
set -euo pipefail

# 1. Firestore security-rules unit tests (@firebase/rules-unit-testing + mocha).
(cd rules-tests && npm ci && npm test)

# 2. online_client transport integration suite — the real REST transport
#    (anonymous auth + direct Firestore documents) against firestore.rules.
(cd ../packages/online_client && dart test -P emulator)

# 3. The app's two-client E2E — two real NetMatchControllers (the unified
#    controller), each over its own FirestoreTransport and anonymous user,
#    playing a whole match over real documents, plus the adversarial legs
#    (rules-blocked forgeries, illegal event, cube-in-cubeless, tampered reveal,
#    lookahead squat).
#
#    AIGAMMON_EMULATOR=1 is the env gate the test file reads (see
#    app/dart_test.yaml for why an env gate rather than exclude_tags).
#    AIGAMMON_E2E_POLL_MS turns the transports' poll interval down from the
#    production 2s: a roll costs ~3 poll latencies, so a flat 2s pacing ran a
#    whole match into MINUTES of pure waiting (measured on one game: 20-30s at
#    100ms against 4m50s at 2000ms). Production answers that with adaptive
#    polling (500ms while a handshake is in flight); the knob still overrides
#    BOTH cadences, since the fast one is capped at the resting one.
(cd ../app && flutter pub get &&
  AIGAMMON_EMULATOR=1 AIGAMMON_E2E_POLL_MS=100 \
  flutter test --tags emulator test/online/emulator_e2e_test.dart)
