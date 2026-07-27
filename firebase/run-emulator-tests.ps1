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
#    Firestore-only emulator: the rules suite needs no auth/functions emulator
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
#    Needs the auth emulator too; no functions emulator exists in the
#    serverless model.
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

# 3. The app's two-client E2E — two real OnlineMatchControllers, each with its
#    own anonymous user, playing a whole match over real documents, plus the
#    adversarial legs (rules-blocked forgeries, illegal event, tampered reveal).
#
#    AIGAMMON_EMULATOR=1 is the env gate the test file reads (see
#    app/dart_test.yaml for why an env gate rather than exclude_tags).
#    AIGAMMON_E2E_POLL_MS turns the controllers' poll interval down from the
#    production 2s: a roll costs ~3 poll latencies, so a flat 2s pacing ran a
#    whole match into MINUTES of pure waiting (measured on one game: 20-30s at
#    100ms against 4m50s at 2000ms). Production answers that with adaptive
#    polling (500ms while a handshake is in flight); the knob still overrides
#    BOTH cadences, since the fast one is capped at the resting one.
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

Write-Host "all emulator suites passed" -ForegroundColor Green
