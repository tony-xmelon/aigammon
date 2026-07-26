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

# ---------------------------------------------------------------------------
# NOTE (Plan 16 — serverless online play, in progress)
#   The two suites below exercise the CALLABLE-era stack (Cloud Functions +
#   the old client transport), which the new rules deliberately no longer
#   admit: client reads now key off hostUid/guestUid, not the functions-written
#   `uids` array. They are therefore expected to fail between Task 1 and the
#   transport/E2E rewrites, and are disabled until then:
#     * Task 3 rewrites packages/online_client onto direct Firestore REST and
#       restores its emulator suite;
#     * Task 5 rewrites the app's two-client E2E for the serverless model;
#     * Task 6 deletes firebase/functions/ entirely.
#   Re-enable (in their rewritten form) as those tasks land.
# ---------------------------------------------------------------------------
# $onlineClient = (Resolve-Path (Join-Path $PSScriptRoot '..\packages\online_client')).Path
# $clientCommand = "cd /d `"$onlineClient`" && dart test -P emulator"
# firebase emulators:exec --project demo-aigammon --only firestore,auth $clientCommand
#
# $app = (Resolve-Path (Join-Path $PSScriptRoot '..\app')).Path
# $appCommand = "cd /d `"$app`" && set `"AIGAMMON_EMULATOR=1`" && " +
#   "flutter test --tags emulator test\online\emulator_e2e_test.dart"
# firebase emulators:exec --project demo-aigammon --only firestore,auth $appCommand

Write-Host "all emulator suites passed" -ForegroundColor Green
