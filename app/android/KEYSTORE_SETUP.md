# Android release signing

The release APK is signed with an **upload keystore**. Until the four repository
secrets below exist, `android.yml` skips the signing step and Gradle falls back
to Flutter's **debug** keystore with a loud warning (see the gate at the top of
`app/android/app/build.gradle.kts`). A debug-signed APK installs fine for
testers but **cannot be published**, and — because every machine has a different
debug key — an app once installed from one debug-signed build cannot be updated
by another.

> **The keystore is the app's identity.** Lose it and you can never ship an
> update to the same Play Store listing again. Back it up (a password manager is
> ideal) the moment you create it.

---

## 1. A keystore already exists locally

`E:\…\AIGammon\app\android\aigammon-upload.jks` was generated for this repo, with:

| file | contents |
|---|---|
| `app/android/aigammon-upload.jks` | the keystore itself |
| `app/android/aigammon-upload.jks.base64.txt` | the same file, base64 — paste this into the `ANDROID_KEYSTORE_BASE64` secret |
| `app/android/aigammon-upload.credentials.txt` | the generated store/key password + a copy of the table below |

All three are **git-ignored** (`app/android/.gitignore`) and exist only on this
machine. If you prefer to use your own keystore instead, see §3.

## 2. Add the four repository secrets

GitHub → the repo → **Settings → Secrets and variables → Actions → New
repository secret**. Create each of these:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | the entire contents of `aigammon-upload.jks.base64.txt` (one long line, no newlines) |
| `ANDROID_KEYSTORE_PASSWORD` | the store password from `aigammon-upload.credentials.txt` |
| `ANDROID_KEY_ALIAS` | `aigammon-upload` |
| `ANDROID_KEY_PASSWORD` | the key password (same value as the store password for the generated keystore) |

All four must be present. The workflow checks for all four together, so a
partially-filled set skips signing rather than failing the build half-way.

Once they are set, the next push to `master` produces a **release-signed** APK;
the job log prints `Release signing ENABLED`.

## 3. Generating your OWN keystore instead

Nothing about the generated one is special — replace it freely, as long as you
do so **before** any signed build reaches a real user.

```bash
keytool -genkeypair -v \
  -keystore aigammon-upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias aigammon-upload
```

`keytool` prompts for the store password, then the distinguished name, then the
key password (press Enter to reuse the store password). To do it
non-interactively — which is what was done for the checked-in setup — pass them
as flags instead:

```bash
keytool -genkeypair -v \
  -keystore aigammon-upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias aigammon-upload \
  -storepass '<STORE_PASSWORD>' -keypass '<KEY_PASSWORD>' \
  -dname "CN=AIGammon, OU=AIGammon, O=xmelon, L=Unknown, ST=Unknown, C=US"
```

Then base64 it for the secret:

```bash
# Linux / macOS
base64 -w0 aigammon-upload.jks > aigammon-upload.jks.base64.txt

# Windows PowerShell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('aigammon-upload.jks')) |
  Set-Content aigammon-upload.jks.base64.txt -NoNewline
```

…and fill in the four secrets from §2 with your own values.

> **Password characters.** The credentials travel into a Java `.properties`
> file, where a backslash is an escape character. The CI step escapes
> backslashes, but the simplest thing is to use a password without them.

## 4. Signing a release build on this machine

Create `app/android/key.properties` (git-ignored) by hand:

```properties
storeFile=aigammon-upload.jks
storePassword=<STORE_PASSWORD>
keyAlias=aigammon-upload
keyPassword=<KEY_PASSWORD>
```

`storeFile` is resolved relative to `app/android/`. With the file in place,
`flutter build apk --release` picks up the real signing config; without it, the
debug-key fallback and its warning apply.

## 5. Verifying what a build was signed with

```bash
keytool -printcert -jarfile app/build/app/outputs/flutter-apk/app-release.apk
```

The debug key shows `CN=Android Debug, O=Android, C=US`. The upload key shows
the `-dname` you supplied above.

## 6. The other file you drop in by hand: `google-services.json`

`key.properties` is not the only git-ignored, generated file `app/android`
expects. `app/google-services.json` is the second, and it is the same tier: not
committed, written by CI from repo variables/secrets, supplied by hand on a
developer machine.

It is **not** a credential — project id, project number, Android app id and the
Web API key all ship inside every APK already — but it is what the
`com.google.gms.google-services`, `com.google.firebase.crashlytics` and
`com.google.firebase.firebase-perf` Gradle plugins read, and those plugins are
what capture a native crash in the Rust engine `.so`.

**Get it, do not write it:** Firebase console → ⚙ *Project settings* → *Your
apps* → the Android app (`com.xmelon.aigammon_app`) → **google-services.json**.
Save it at `app/android/app/google-services.json`. A hand-assembled file whose
`package_name` does not match `applicationId` exactly fails the build with *"No
matching client found for package name"*.

Without it the Android build still succeeds — Gradle logs a `NOTE:` and skips
all three plugins, leaving Dart-only crash reporting and no automatic
performance traces. Full details, including the CI generation step and the
still-open native-symbol-upload gap, are in `firebase/DEPLOY.md`.

---

**Related:** `app/test/android_signing_test.dart` asserts this wiring stays in
place (the release build type reads `key.properties`, the debug fallback stays
gated, the keystore material stays git-ignored, and this document keeps naming
the same four secrets `android.yml` consumes).
