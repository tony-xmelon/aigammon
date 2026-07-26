#!/usr/bin/env bash
# Linux equivalent of run-emulator-tests.ps1's in-emulator step, for CI.
#
# `firebase emulators:exec ... "bash ./ci-emulator-suites.sh"` runs this with the
# emulator suite already up and the working directory set to firebase/ (the
# Firebase project dir). Paths below are therefore relative to firebase/.
set -euo pipefail

# 1. Firestore security-rules unit tests (@firebase/rules-unit-testing + mocha).
(cd rules-tests && npm ci && npm test)

# ---------------------------------------------------------------------------
# NOTE (Plan 16 — serverless online play, in progress)
#   The callable-era suites below are disabled: the new rules key client reads
#   off hostUid/guestUid instead of the functions-written `uids` array, so the
#   old transport can no longer read its own match. Task 3 restores the
#   online_client suite on direct Firestore REST, Task 5 rewrites the app's
#   two-client E2E, Task 6 deletes firebase/functions/.
# ---------------------------------------------------------------------------
# (cd ../packages/online_client && dart test -P emulator)
# (cd ../app && flutter pub get && AIGAMMON_EMULATOR=1 flutter test --tags emulator test/online/emulator_e2e_test.dart)
