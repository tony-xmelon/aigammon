#!/usr/bin/env bash
# Builds an XCFramework for iOS device + simulator. macOS only (CI).
# PREREQUISITES: Xcode CLT; rustup target add aarch64-apple-ios aarch64-apple-ios-sim
set -euo pipefail
cd "$(dirname "$0")"
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim
OUT=../../packages/engine_bindings/native/ios
mkdir -p "$OUT"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libaigammon_engine.a \
  -library target/aarch64-apple-ios-sim/release/libaigammon_engine.a \
  -output "$OUT/aigammon_engine.xcframework"
echo "Staged XCFramework -> $OUT"
