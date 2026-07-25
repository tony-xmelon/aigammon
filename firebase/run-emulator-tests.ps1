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

# 2. Run the suite inside the emulator. Resolve the package dir to an absolute
#    path here (where $PSScriptRoot is known) and hand cmd.exe a `cd && dart`.
$onlineClient = (Resolve-Path (Join-Path $PSScriptRoot '..\packages\online_client')).Path
$execCommand = "cd /d `"$onlineClient`" && dart test -P emulator"

Push-Location $PSScriptRoot
try {
  firebase emulators:exec --project demo-aigammon --only firestore,functions,auth $execCommand
  $code = $LASTEXITCODE
} finally {
  Pop-Location
}

if ($code -ne 0) { throw "emulator integration suite failed ($code)" }
Write-Host "emulator integration suite passed" -ForegroundColor Green
