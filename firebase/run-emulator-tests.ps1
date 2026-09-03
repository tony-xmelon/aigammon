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

# The Microsoft Store build of PowerShell is MSIX-packaged, and a packaged
# process hands its children a VIRTUALIZED %LOCALAPPDATA% — which is where the
# pub cache lives. Under it the emulator's own suites pass and then leg 2 dies
# on ``Could not find `bin\test.dart` in package `test` ``, an error that names
# nothing that is actually wrong. This used to be a README paragraph asking you
# to remember to type `powershell.exe -File ...` instead; a trap you have to
# remember is a trap, so the script types it for you. Windows PowerShell is not
# packaged, and the command strings below were already written to survive it —
# see the `--name` note in leg 4.
$isPackaged = $PSHOME -like "$env:ProgramFiles\WindowsApps\*"
if ($isPackaged -and -not $env:AIGAMMON_EMULATOR_REEXEC) {
  $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path $winPs)) {
    throw "This pwsh is Store-packaged (its children cannot see the pub cache) " +
      "and Windows PowerShell was not found at $winPs. Run this script from " +
      "cmd, Git Bash, or a non-Store PowerShell."
  }
  # Keep every STRING in this file ASCII, and this line is why. Windows
  # PowerShell reads a BOM-less UTF-8 file as ANSI, so an em dash arrives as
  # three characters ending in 0x94 -- a right smart quote, which PowerShell
  # honours as a string delimiter. This line held one, it closed its own
  # string, and the file stopped PARSING under 5.1 -- the very shell this
  # guard hands it to, so the guard would have broken the script it was
  # written to rescue. Comments are safe (they end at the newline) and the
  # eight already in this file are untouched; strings are not.
  Write-Host "Store-packaged pwsh detected - re-running under Windows PowerShell so the pub cache stays visible." -ForegroundColor Yellow
  $env:AIGAMMON_EMULATOR_REEXEC = '1'
  & $winPs -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args
  exit $LASTEXITCODE
}

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
#    `--name <regexp>` with DOTS where the test name has spaces, rather than
#    `--plain-name "…"`, and it is not a style choice: this command string is
#    handed to a native executable, and Windows PowerShell 5.1 re-splits such an
#    argument once it carries this many quoted segments — `emulators:exec` then
#    sees a dozen arguments instead of one script and refuses with "Too many
#    arguments". A regexp with no spaces needs no quotes at all. (`^` is cmd's
#    escape character, so the pattern is deliberately unanchored.)
$pollCommand = "cd /d `"$app`" && set `"AIGAMMON_EMULATOR=1`" && " +
  "set `"AIGAMMON_E2E_POLL_MS=100`" && set `"AIGAMMON_E2E_LISTEN=0`" && " +
  "flutter test --tags emulator " +
  "--name two.clients.play.a.complete.match.through.the.emulator " +
  "test\online\emulator_e2e_test.dart"

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
