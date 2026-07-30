# Runs the Firebase emulator suites for AIGammon online play.
#
# Usage (from anywhere):
#   pwsh firebase/run-emulator-tests.ps1
#
# CWD handling — the important bit:
#   `firebase emulators:exec <cmd>` runs <cmd> through the system shell (cmd.exe
#   on Windows) with the working directory set to the Firebase project dir, i.e.
#   this script's own folder (firebase/). A suite that must run elsewhere first
#   `cd /d`s there (via an ABSOLUTE path) and then invokes its runner; `cd /d &&
#   ...` works because emulators:exec already wraps the command in `cmd /s /c`.
$ErrorActionPreference = 'Stop'

# Make node / firebase / dart resolvable even from a bare shell.
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') +
  ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')

# 1. Firestore security-rules unit tests (@firebase/rules-unit-testing + mocha).
#    Firestore-only emulator: the rules suite needs no auth emulator
#    (rules-unit-testing mints its own auth contexts).
$rulesTests = (Resolve-Path (Join-Path $PSScriptRoot 'rules-tests')).Path
if (-not (Test-Path (Join-Path $rulesTests 'node_modules'))) {
  Push-Location $rulesTests
  try { npm install; if ($LASTEXITCODE -ne 0) { throw "rules-tests npm install failed" } }
  finally { Pop-Location }
}
$rulesCommand = "cd /d `"$rulesTests`" && npm test"

Push-Location $PSScriptRoot
try {
  firebase emulators:exec --project demo-aigammon --only firestore $rulesCommand
  $rulesCode = $LASTEXITCODE
} finally {
  Pop-Location
}
if ($rulesCode -ne 0) { throw "firestore rules suite failed ($rulesCode)" }
Write-Host "firestore rules suite passed" -ForegroundColor Green

# 2. online_client transport integration suite — the real REST transport
#    (anonymous auth + direct Firestore documents) against firestore.rules.
#    Needs the auth emulator too; there is no third emulator to start — the
#    whole backend is firestore.rules.
$onlineClient = (Resolve-Path (Join-Path $PSScriptRoot '..\packages\online_client')).Path
$clientCommand = "cd /d `"$onlineClient`" && dart test -P emulator"

Push-Location $PSScriptRoot
try {
  firebase emulators:exec --project demo-aigammon --only firestore,auth $clientCommand
  $clientCode = $LASTEXITCODE
} finally {
  Pop-Location
}
if ($clientCode -ne 0) { throw "online_client emulator suite failed ($clientCode)" }
Write-Host "online_client emulator suite passed" -ForegroundColor Green

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
#
#    The E2E runs on the REAL-TIME LISTENER path by default (that is production
#    since v0.11), which also adds a leg that severs the stream mid-match and
#    requires the poll fallback to carry the game. AIGAMMON_E2E_LISTEN=0 runs the
#    identical suite on polling alone — how a gRPC problem is isolated from a game
#    problem — and the poll knob above still governs the DEGRADED path either way.
$app = (Resolve-Path (Join-Path $PSScriptRoot '..\app')).Path
$appCommand = "cd /d `"$app`" && set `"AIGAMMON_EMULATOR=1`" && " +
  "set `"AIGAMMON_E2E_POLL_MS=100`" && " +
  "flutter test --tags emulator test\online\emulator_e2e_test.dart"

Push-Location $PSScriptRoot
try {
  firebase emulators:exec --project demo-aigammon --only firestore,auth $appCommand
  $appCode = $LASTEXITCODE
} finally {
  Pop-Location
}
if ($appCode -ne 0) { throw "app two-client E2E suite failed ($appCode)" }
Write-Host "app two-client E2E suite passed" -ForegroundColor Green

# 4. The DEGRADED path, for real: the same E2E with AIGAMMON_E2E_LISTEN=0, so a
#    client that can never open a gRPC stream (a network blocking HTTP/2, a
#    proxy, an outage) is proven to still play a whole match on the poll loop.
#
#    Documenting the flag without ever running it left the fallback covered only
#    by leg 3's mid-match listener-drop test, which polls for a few moves and then
#    hands back to a listener that works. This leg never has one.
#
#    ONE test, not the suite: a complete 1-point match end to end is what proves
#    the path. Re-running the adversarial legs would double the wall clock to
#    re-prove `firestore.rules`, which does not care which delivery mechanism
#    asked.
$pollCommand = "cd /d `"$app`" && set `"AIGAMMON_EMULATOR=1`" && " +
  "set `"AIGAMMON_E2E_POLL_MS=100`" && set `"AIGAMMON_E2E_LISTEN=0`" && " +
  "flutter test --tags emulator test\online\emulator_e2e_test.dart " +
  "--plain-name `"two clients play a complete match through the emulator`""

Push-Location $PSScriptRoot
try {
  firebase emulators:exec --project demo-aigammon --only firestore,auth $pollCommand
  $pollCode = $LASTEXITCODE
} finally {
  Pop-Location
}
if ($pollCode -ne 0) { throw "app E2E poll-fallback leg failed ($pollCode)" }
Write-Host "app E2E poll-fallback leg passed" -ForegroundColor Green

Write-Host "all emulator suites passed" -ForegroundColor Green
