#!/usr/bin/env bash
# Linux equivalent of run-emulator-tests.ps1's in-emulator step, for CI.
#
# `firebase emulators:exec ... "bash ./ci-emulator-suites.sh"` runs this with the
# emulator suite already up and the working directory set to firebase/ (the
# Firebase project dir). Paths below are therefore relative to firebase/.
set -euo pipefail

# NOTE: the rules unit tests used to be step 1 here. They now run as their own
# `rules` job in .github/workflows/ci.yml, which this job `needs:` — seconds of
# mocha against a firestore-only emulator, ahead of the four toolchains and the
# two E2E legs below, so a broken firestore.rules is red before any of this
# starts. run-emulator-tests.ps1 still runs all of it in one sitting locally.

# 1. online_client transport integration suite — the real REST transport
#    (anonymous auth + direct Firestore documents) against firestore.rules.
(cd ../packages/online_client && dart test -P emulator)

# 2. The app's two-client E2E — two real NetMatchControllers (the unified
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
#
#    The E2E runs on the REAL-TIME LISTENER path by default (that is production
#    since v0.11). AIGAMMON_E2E_LISTEN=0 runs the identical suite on polling
#    alone, which is how a gRPC problem is isolated from a game problem — and the
#    poll knob above still governs the DEGRADED path either way. Leg 4 below is
#    that flag, actually executed.
(cd ../app && flutter pub get &&
  AIGAMMON_EMULATOR=1 AIGAMMON_E2E_POLL_MS=100 \
  flutter test --tags emulator test/online/emulator_e2e_test.dart)

# 3. The DEGRADED path, for real: the same E2E with the listener switched off, so
#    a client that can never open a gRPC stream (a network blocking HTTP/2, a
#    proxy, an outage) is proven to still play a whole match on the poll loop.
#
#    Documenting AIGAMMON_E2E_LISTEN=0 without ever running it left the fallback
#    covered only by the mid-match listener-drop leg, which exercises polling for
#    a few moves and then hands back to a listener that works. This leg never has
#    one.
#
#    ONE test, not the suite: a complete 1-point match end to end is what proves
#    the path, and re-running the adversarial legs on it would double this job's
#    wall clock to re-prove `firestore.rules`, which does not care which delivery
#    mechanism asked.
#    `--name <regexp>` (dots for the spaces) rather than `--plain-name '…'`, to
#    stay byte-identical with run-emulator-tests.ps1, which cannot quote it — see
#    the note on leg 4 there.
(cd ../app &&
  AIGAMMON_EMULATOR=1 AIGAMMON_E2E_POLL_MS=100 AIGAMMON_E2E_LISTEN=0 \
  flutter test --tags emulator \
    --name two.clients.play.a.complete.match.through.the.emulator \
    test/online/emulator_e2e_test.dart)
