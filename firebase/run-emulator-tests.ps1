# Builds the Cloud Functions, then runs the online_client emulator integration
# suite inside a throwaway emulator started by `firebase emulators:exec`.
#
# Usage (from anywhere):
#   pwsh firebase/run-emulator-tests.ps1
#
# CWD handling — the important bit:
#   `firebase emulators:exec <cmd>` runs <cmd> through the system shell (cmd.exe
#   on Windows) with the working directory set to the Firebase project dir, i.e.
#   this script's own folder (firebase/). The Dart suite must instead run in
#   packages/online_client, so <cmd> first `cd /d`s there (via an ABSOLUTE path
#   with no spaces) and then invokes `dart test -P emulator`. `cd /d && ...`
#   works because emulators:exec already wraps the command in `cmd /s /c`.
$ErrorActionPreference = 'Stop'

# Make node / firebase / dart resolvable even from a bare shell.
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') +
  ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')

# 1. Build the functions (tsc) so the emulator loads fresh JS.
Push-Location (Join-Path $PSScriptRoot 'functions')
try {
  npm run build
  if ($LASTEXITCODE -ne 0) { throw "functions build failed ($LASTEXITCODE)" }
} finally {
  Pop-Location
}

# 2. Run the online_client suite inside a throwaway emulator. Resolve the
#    package dir to an absolute path here (where $PSScriptRoot is known) and hand
#    cmd.exe a `cd && dart`.
$onlineClient = (Resolve-Path (Join-Path $PSScriptRoot '..\packages\online_client')).Path
$clientCommand = "cd /d `"$onlineClient`" && dart test -P emulator"

Push-Location $PSScriptRoot
try {
  firebase emulators:exec --project demo-aigammon --only firestore,functions,auth $clientCommand
  $code = $LASTEXITCODE
} finally {
  Pop-Location
}

if ($code -ne 0) { throw "online_client emulator suite failed ($code)" }
Write-Host "online_client emulator suite passed" -ForegroundColor Green

# 3. Run the app's two-client full-match E2E in a SECOND throwaway emulator, so
#    each suite gets a clean, isolated Firestore/Auth state. Unlike the Dart
#    suite, `flutter test` supports neither `-P` presets nor re-including a
#    config-excluded tag, so the E2E is gated by the AIGAMMON_EMULATOR env var
#    instead (see app/dart_test.yaml); `set VAR=1 && ...` sets it for the cmd.exe
#    line that emulators:exec runs, and `--tags emulator` narrows the run to just
#    the tagged test.
$app = (Resolve-Path (Join-Path $PSScriptRoot '..\app')).Path
# `set "VAR=1"` (quoted) avoids cmd.exe capturing the trailing space before `&&`
# into the value; the test also trims defensively.
$appCommand = "cd /d `"$app`" && set `"AIGAMMON_EMULATOR=1`" && " +
  "flutter test --tags emulator test\online\emulator_e2e_test.dart"

Push-Location $PSScriptRoot
try {
  firebase emulators:exec --project demo-aigammon --only firestore,functions,auth $appCommand
  $appCode = $LASTEXITCODE
} finally {
  Pop-Location
}

if ($appCode -ne 0) { throw "app two-client E2E failed ($appCode)" }
Write-Host "app two-client E2E passed" -ForegroundColor Green
Write-Host "all emulator suites passed" -ForegroundColor Green
