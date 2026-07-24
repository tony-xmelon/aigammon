# Builds aigammon_engine for Android ABIs into Flutter jniLibs layout.
# PREREQUISITES (not present on this machine yet — verified in Plan 3):
#   - Android NDK, with $env:ANDROID_NDK_HOME set
#   - cargo install cargo-ndk
#   - rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
$out = Join-Path $PSScriptRoot '..\..\packages\engine_bindings\native\android\jniLibs'
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -o $out build --release
Pop-Location
Write-Host "Staged Android .so files -> $out"
