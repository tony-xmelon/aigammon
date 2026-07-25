# CI workflows

| Workflow | File | Trigger | Purpose |
|---|---|---|---|
| CI | `ci.yml` | push to `master`, all PRs | `backgammon_core` + `engine_bindings` + Flutter app tests (Linux) |
| Android | `android.yml` | `workflow_dispatch`, push to `master` | Cross-compile the Rust engine for Android ABIs, build a release APK, and (when configured) push it to Firebase App Distribution |
| iOS | `ios.yml` | `workflow_dispatch`, push to `master` | Build the Rust engine staticlib, statically link it into `Runner`, produce an unsigned `Runner.app`, and (when configured) build a signed IPA and push it to Firebase App Distribution |

## `android.yml` — how it builds

1. Checks out with `submodules: recursive` (the engine needs `native/wildbg`).
2. Installs the Rust Android targets + `cargo-ndk`, then installs the exact NDK
   Flutter pins (`28.2.13676358`) via `sdkmanager` and points `ANDROID_NDK_HOME`
   at it.
3. `cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -o app/android/app/src/main/jniLibs build --release`
   cross-compiles `libaigammon_engine.so` straight into the Flutter jniLibs
   layout. At runtime the app loads it with
   `DynamicLibrary.open('libaigammon_engine.so')`.
4. `flutter build apk --release`. Flutter automatically packages every ABI
   present under `src/main/jniLibs/<abi>/` into `lib/<abi>/` inside the APK, so
   **no `abiFilters` / `ndk.abiFilters` block is needed** in `build.gradle.kts` —
   the set of ABIs is exactly the set `cargo ndk` produced.
5. Uploads the APK as the `aigammon-apk` artifact.

### Signing

The release APK is signed with Flutter's **debug** keystore (see the
`signingConfig = signingConfigs.getByName("debug")` in
`app/android/app/build.gradle.kts`). That is fine for internal tester
distribution via Firebase App Distribution, but a real Play Store release needs a
proper upload keystore + `key.properties` signing config. Not done here.

### Neural nets

The production ONNX nets ship as Flutter **assets** (`app/assets/nets/`), so the
APK bundles them automatically. No CI work is needed for nets.

## `ios.yml` — how it builds

Runs on `macos-latest` (Rust cross-compilation to `aarch64-apple-ios` and the
Xcode build both need macOS).

1. Checks out with `submodules: recursive` (the engine needs `native/wildbg`).
2. Installs the Rust `aarch64-apple-ios` target and builds the engine staticlib:
   `cargo build --release --target aarch64-apple-ios` in `native/engine_shim`.
3. Copies `libaigammon_engine.a` to **`app/ios/Frameworks/`** — the path the
   `-force_load` in `app/ios/Flutter/Release.xcconfig` expects. Unlike Android
   (a `.so` opened by path at runtime), iOS forbids `dlopen`, so the engine is
   linked **statically** into `Runner` and its symbols are resolved at runtime
   via `DynamicLibrary.process()`. See `native/README.md` "iOS".
4. `flutter build ios --release --no-codesign` produces `Runner.app`. Same
   online-play dart-defines as `android.yml` (repo **variables**
   `AIGAMMON_FIREBASE_PROJECT` / `AIGAMMON_FIREBASE_API_KEY`).
5. `Runner.app` is a directory tree with internal symlinks, so it is packaged
   with `ditto -c -k --keepParent` (upload-artifact mangles the symlinks
   otherwise) and uploaded as the **`aigammon-ios-unsigned`** artifact.

> An **unsigned `.app` cannot be installed on an iPhone.** Signing is the
> user-gated step below; without the secrets, CI stops after the unsigned
> artifact.

### Signing + Firebase distribution (secret-gated)

The signing/distribution path is **skipped** until **four** repository secrets
are all present **together with** the existing `FIREBASE_SERVICE_ACCOUNT`
(reused from Android) — the gate requires all five so a missing service account
skips cleanly instead of failing at the distribute step. When they exist, the
workflow imports the certificate into a throwaway keychain, installs the
provisioning profile, derives the team id / profile name / UUID from the profile
itself (nothing hard-coded), and writes an `ExportOptions.plist` for an
**ad-hoc** export. It then builds the signed IPA in three explicit commands
rather than `flutter build ipa`: `flutter build ios --release --no-codesign`
(compile), then `xcodebuild … archive` with **manual** signing settings passed
on the command line (`CODE_SIGN_STYLE=Manual`, `DEVELOPMENT_TEAM`,
`PROVISIONING_PROFILE_SPECIFIER`, `CODE_SIGN_IDENTITY`), then `xcodebuild
-exportArchive`. This is necessary because `Runner.xcodeproj` ships
`CODE_SIGN_STYLE=Automatic` with no `DEVELOPMENT_TEAM`, and those target-level
pbxproj settings outrank xcconfig — only command-line build settings override
them, so `flutter build ipa`'s internal archive would fail with "Signing for
Runner requires a development team" on the headless runner. The IPA is uploaded
as `aigammon-ios-signed` and distributed to the Firebase **`testers`** group.

| Secret | What it is |
|---|---|
| `IOS_CERT_P12_BASE64` | base64 of the **Apple Distribution** certificate exported as a `.p12` |
| `IOS_CERT_PASSWORD` | the password set when exporting that `.p12` |
| `IOS_PROVISIONING_PROFILE_BASE64` | base64 of the **ad-hoc** `.mobileprovision` (expected profile name `aigammon-adhoc`, bundle id `com.xmelon.aigammon`, with tester device UDIDs) |
| `FIREBASE_IOS_APP_ID` | the iOS App ID from the Firebase console (`1:…:ios:…`) |

Producing these requires an **Apple Developer Program** membership and is done
by hand once. The exact enrollment, profile-creation, export, base64-encoding,
and Firebase-console steps live in **`firebase/DEPLOY.md` → "iOS distribution"**.

## Firebase App Distribution setup

The distribution step is **secret-gated**: it runs only when both
`FIREBASE_SERVICE_ACCOUNT` and `FIREBASE_ANDROID_APP_ID` repository secrets are
present. Until then the job builds and uploads the APK artifact and logs a clear
"skipping distribution" message. To enable distribution:

1. **Register the Android app in Firebase.** In the
   [Firebase console](https://console.firebase.google.com/project/aigammon)
   open **Project overview → Add app → Android** and register package name
   `com.xmelon.aigammon_app`. You do **not** need to download or commit
   `google-services.json`: the app bundles no Firebase SDK, and App Distribution
   of a raw APK only needs the App ID + a service account. Copy the generated
   **App ID** — it looks like `1:1234567890:android:abcdef0123456789`.

2. **Create the testers group.** In **Release & Monitor → App Distribution →
   Testers & Groups**, create a group whose alias is exactly **`testers`**
   (the workflow passes `groups: testers`) and add tester emails.

3. **Create a service account key.** In **Project settings → Service accounts**,
   use the **Firebase Admin SDK** service account and **Generate new private
   key** to download a JSON file. (For least privilege you can instead create a
   dedicated service account in Google Cloud IAM granted the **Firebase App
   Distribution Admin** role and download its key.)

4. **Add the GitHub secrets** (repo **Settings → Secrets and variables →
   Actions → New repository secret**):
   - `FIREBASE_ANDROID_APP_ID` — the App ID from step 1 (`1:…:android:…`).
   - `FIREBASE_SERVICE_ACCOUNT` — the **entire contents** of the service-account
     JSON file from step 3 (paste the JSON as the secret value).

Once both secrets exist, the next run of `android.yml` distributes the release
APK to the `testers` group automatically.
