# Builds the Windows x64 engine DLL and stages it where engine_bindings looks.
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
cargo build --release
$out = Join-Path $PSScriptRoot '..\..\packages\engine_bindings\native\windows'
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'target\release\aigammon_engine.dll') $out -Force
Pop-Location
Write-Host "Staged aigammon_engine.dll -> packages/engine_bindings/native/windows/"
