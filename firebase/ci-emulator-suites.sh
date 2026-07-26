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

# ---------------------------------------------------------------------------
# NOTE (Plan 16 — serverless online play, in progress)
#   The app's two-client E2E still targets the CALLABLE-era stack and is
#   disabled until Task 5 rewrites it for the serverless model (Task 6 then
#   deletes firebase/functions/).
# ---------------------------------------------------------------------------
# (cd ../app && flutter pub get && AIGAMMON_EMULATOR=1 flutter test --tags emulator test/online/emulator_e2e_test.dart)
