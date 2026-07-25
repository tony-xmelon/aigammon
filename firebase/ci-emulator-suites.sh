#!/usr/bin/env bash
# Linux equivalent of run-emulator-tests.ps1's in-emulator step, for CI.
#
# `firebase emulators:exec ... "bash ./ci-emulator-suites.sh"` runs this with the
# emulator suite (Firestore/Functions/Auth) already up and the working directory
# set to firebase/ (the Firebase project dir). Paths below are therefore relative
# to firebase/. Unlike the .ps1 flow, both suites share this single emulator
# instance — that is fine: online_client tears down its own docs, and the app E2E
# creates fresh matches by random code, so the two suites do not collide.
set -euo pipefail

# 1. online_client emulator integration suite.
(cd ../packages/online_client && dart test -P emulator)

# 2. app two-client full-match E2E. Gated by AIGAMMON_EMULATOR (see
#    app/dart_test.yaml); --tags emulator narrows the run to the tagged test.
#    The app's deps are not resolved elsewhere in this job, so pub get here.
(cd ../app && flutter pub get && AIGAMMON_EMULATOR=1 flutter test --tags emulator test/online/emulator_e2e_test.dart)
