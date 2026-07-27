# AIGammon online play — deployment & configuration

**The entire backend is `firestore.rules`.** There is no server code: no Cloud
Functions, no container, nothing to build or deploy but a rules file. Matches
live in Firestore documents, players sign in anonymously, dice are agreed
between the two clients by a commit-reveal handshake, and each client validates
the other's moves with the full rules engine. That is what keeps online play on
the **free Spark plan — no Blaze upgrade, no credit card, no billing account.**

Deployment is therefore four short steps (§1–§4 below), of which only one is a
command.

The app resolves its online backend from `onlineConfigProvider`
(`app/lib/online/online_providers.dart`):

1. If **both** `--dart-define=AIGAMMON_FIREBASE_API_KEY=...` and
   `--dart-define=AIGAMMON_FIREBASE_PROJECT=...` are set → a **production**
   config against that Firebase project.
2. Otherwise, in a **debug** build → the local **Firebase Emulator Suite**.
3. Otherwise (a release build with no defines) → online play is **disabled**
   (the Online screen shows a "not configured" card).

## Emulator dev flow

Debug builds default to the emulator — no dart-define needed. Just start the
emulator suite, then run the app in debug:

```sh
# From firebase/ — start the Firestore + Auth emulators (the only two there
# are; firebase.json declares no others).
firebase emulators:start

# From app/ — a normal debug run picks up OnlineConfig.emulator()
# (demo-aigammon on 127.0.0.1: Firestore 8080, Auth 9099).
flutter run
```

Create a match on one client and join it by code from another (a second
`flutter run`, or the two-client emulator E2E test) to exercise online play
end to end. To run the full emulator test matrix locally — the `firestore.rules`
unit tests, the `online_client` transport suite and the app's two-client E2E,
each in a throwaway emulator:

```powershell
pwsh firebase/run-emulator-tests.ps1
```

CI runs the same three suites on Linux via `firebase/ci-emulator-suites.sh`
inside a single `firebase emulators:exec` (see the `online` job in
`.github/workflows/ci.yml`).

## Production deployment

### 1. Create (or verify) the `aigammon` project — Spark plan

In the [Firebase console](https://console.firebase.google.com/), **Add project**
→ name it `aigammon` (Google Analytics is not needed). A new project is on the
free **Spark** plan by default: **leave it there.** Nothing in this app requires
Blaze, and no billing account needs to exist.

If the project already exists, check the plan badge at the bottom of the console
sidebar; **Spark** is the expected value.

Then create the Firestore database itself: **Build → Firestore Database →
Create database** → production mode → pick a location (any; it cannot be changed
later). The rules deployed in §3 replace the default deny-all ruleset.

### 2. Enable anonymous authentication

**Build → Authentication → Get started → Sign-in method → Anonymous → Enable →
Save.**

Every client signs in anonymously before creating or joining a match; the uid it
receives is what `firestore.rules` checks ownership against. Online play cannot
work without this, and it is the only auth provider the app uses.

### 3. Deploy the rules

Install the Firebase CLI and log in as an **owner/editor of the project**:

```sh
npm install -g firebase-tools
firebase login
```

Then, from the `firebase/` directory:

```sh
firebase deploy --only firestore:rules --project aigammon
```

That is the whole backend deploy. (`firestore.indexes.json` is deployed by
`--only firestore` if it ever grows an index; it is currently empty, and the
queries the client makes — `events` by `seq`, `rolls` by `n` — are served by the
automatic single-field indexes.)

Re-run this command after ANY edit to `firestore.rules`; nothing else in the
repo needs deploying, ever.

### 4. Retrieve the Web API key and set the repo Variables

The production `OnlineConfig` needs two values:

| Value | Where to find it |
|---|---|
| **Project ID** | `aigammon` (Firebase console → ⚙ *Project settings* → **General** → *Project ID*) |
| **Web API Key** | Firebase console → ⚙ *Project settings* → **General** tab → **Web API Key** |

If the Web API Key row is missing, the project has no web app registered yet:
**Project settings → General → Your apps → Web (`</>`)**, register any nickname
(no hosting), and the key appears. The app bundles no Firebase SDK, so the rest
of the generated config snippet is irrelevant.

Add both in the GitHub repo under **Settings → Secrets and variables → Actions →
Variables → New repository variable** (Variables, not Secrets — see below):

- `AIGAMMON_FIREBASE_PROJECT` → `aigammon`
- `AIGAMMON_FIREBASE_API_KEY` → the Web API Key

The Web API key is **not a secret** in the credential sense: it identifies the
project to Firebase's public REST/Auth endpoints, ships inside every client
binary, and grants nothing on its own — access is gated by
`firestore.rules` (and, optionally, App Check). Storing it as a Variable keeps it
readable in build logs, which is what makes a failed online build diagnosable.

### 5. Build the app for production online play

Supply both defines so `onlineConfigProvider` selects the production backend:

```sh
flutter build apk --release \
  --dart-define=AIGAMMON_FIREBASE_PROJECT=aigammon \
  --dart-define=AIGAMMON_FIREBASE_API_KEY=<web-api-key>
```

The same two defines work for any release target (`build appbundle`,
`build windows`, etc.).

### Follow-up: wire the defines into `android.yml`

The `android.yml` release-APK workflow currently builds without online defines,
so its APKs have online play disabled. A later change can pass the two repo
Variables from §4 through as `--dart-define`s in the build step. Not implemented
here — tracked as a follow-up.

## Free-tier budget

Spark's daily Firestore quota is **50,000 document reads, 20,000 writes and
20,000 deletes**, and it resets every day at midnight Pacific.

Reads are what this design spends: each client polls two collection queries per
cycle, at 2s while it is idle and 500ms only while a dice handshake is
outstanding (`OnlineMatchController.currentPollInterval`). A whole match — both
clients, all games — costs on the order of a few thousand reads, so the quota is
roughly **10–15 matches a day** across all users. That is a friends-and-family
budget, and it is the deliberate price of having no server. Exceeding it makes
reads fail until the reset (the app surfaces them as transient errors); the only
remedies are polling less often or moving to Blaze.

Writes are negligible by comparison: one document per event and three phase
writes per roll, a few hundred per match.

## What is NOT set up (and does not need to be)

For the avoidance of doubt, online play needs **none** of: Cloud Functions,
Cloud Run, a service account for gameplay, App Engine, Hosting, Cloud Storage,
FlutterFire/`google-services.json`/`GoogleService-Info.plist`, or a billing
account. The client talks to Firestore and Identity Toolkit over plain REST with
the Web API key, and the only server-side artifact in this repo is
`firebase/firestore.rules`.

(`FIREBASE_SERVICE_ACCOUNT` does exist as a repo secret — it is used by the
**App Distribution** steps in `android.yml`/`ios.yml` to upload builds to
testers, which is unrelated to online play.)

## iOS distribution

The `ios.yml` workflow always builds an **unsigned** `Runner.app`
(artifact `aigammon-ios-unsigned`). **An unsigned `.app` cannot be installed on
an iPhone** — Apple requires a signed, provisioned build. Producing that signed
build is a **one-time, user-gated** setup that needs a paid Apple Developer
account; it cannot be automated for you because it involves your Apple identity.
Once the secrets below exist, every `ios.yml` run builds a signed **ad-hoc IPA**
and pushes it to the Firebase `testers` group automatically (same group and
`FIREBASE_SERVICE_ACCOUNT` secret as Android).

The workflow's signed path stays **skipped** until all four secrets exist:
`IOS_CERT_P12_BASE64`, `IOS_CERT_PASSWORD`,
`IOS_PROVISIONING_PROFILE_BASE64`, `FIREBASE_IOS_APP_ID`.

### 1. Enroll in the Apple Developer Program

Ad-hoc signing (and any App Store / TestFlight path) requires a paid
**Apple Developer Program** membership (USD 99/yr):
<https://developer.apple.com/programs/enroll/>. A free personal team can sign
for a locally-attached device but cannot create the distribution certificate
and ad-hoc profile CI needs, so enrollment is required.

### 2. Register the App ID (bundle id)

In the [Apple Developer portal](https://developer.apple.com/account/resources/identifiers/list)
→ **Certificates, Identifiers & Profiles → Identifiers → +** → **App IDs → App**,
register the explicit bundle id **`com.xmelon.aigammon`** (this is the iOS
`PRODUCT_BUNDLE_IDENTIFIER`; it intentionally omits the underscore in the
Android `com.xmelon.aigammon_app` because Apple's `CFBundleIdentifier` charset
forbids underscores — see `native/README.md`). No special capabilities are
needed.

### 3. Register tester devices (UDIDs)

Ad-hoc builds only install on devices whose **UDID** is baked into the profile.
For each tester device, in **Devices → +**, add a name + UDID. A tester finds
their iPhone UDID via **Settings → General → About → tap the serial/identifier
rows** until the UDID shows (or connect to a Mac: Finder → the device → click
under the device name to reveal the UDID, then right-click → Copy). Collect all
tester UDIDs before creating the profile.

### 4. Create the distribution certificate → `.p12`

On a Mac (Keychain Access can generate the signing request):

1. In the portal, **Certificates → +** → **Apple Distribution** → upload a
   Certificate Signing Request (**Keychain Access → Certificate Assistant →
   Request a Certificate from a Certificate Authority**, "Saved to disk").
2. Download the resulting `.cer` and double-click to add it to the login
   keychain.
3. In Keychain Access, expand the certificate to reveal its **private key**,
   select both the cert and the key, **right-click → Export 2 items…**, save as
   `aigammon-dist.p12`, and set an export **password** (this becomes
   `IOS_CERT_PASSWORD`).

### 5. Create the ad-hoc provisioning profile

In the portal, **Profiles → +** → **Distribution → Ad Hoc** → select App ID
`com.xmelon.aigammon` → the Apple Distribution certificate from step 4 → the
tester devices from step 3. **Name it exactly `aigammon-adhoc`** (the workflow's
`ExportOptions.plist` reads the profile's actual name dynamically, but keeping
this name matches the docs and CI logs). Download the `.mobileprovision`.

### 6. Create the iOS app in Firebase → `FIREBASE_IOS_APP_ID`

In the [Firebase console](https://console.firebase.google.com/project/aigammon)
→ **Project overview → Add app → iOS**, register bundle id
**`com.xmelon.aigammon`**. You do **not** need `GoogleService-Info.plist` (the
app bundles no Firebase SDK; App Distribution of a raw IPA needs only the App ID
+ the service account). Copy the generated **App ID** — it looks like
`1:1234567890:ios:abcdef0123456789`. Ensure a testers group aliased exactly
**`testers`** exists (created once for Android; reused here).

### 7. Base64-encode and add the GitHub secrets

Base64-encode the two binary files (no line wrapping):

```powershell
# PowerShell (Windows)
[Convert]::ToBase64String([IO.File]::ReadAllBytes("aigammon-dist.p12"))       > cert.b64.txt
[Convert]::ToBase64String([IO.File]::ReadAllBytes("aigammon-adhoc.mobileprovision")) > profile.b64.txt
```

```sh
# macOS / Linux
base64 -i aigammon-dist.p12               | tr -d '\n' > cert.b64.txt
base64 -i aigammon-adhoc.mobileprovision  | tr -d '\n' > profile.b64.txt
```

Then in the repo **Settings → Secrets and variables → Actions → New repository
secret**, add:

- `IOS_CERT_P12_BASE64` — contents of `cert.b64.txt`.
- `IOS_CERT_PASSWORD` — the `.p12` export password from step 4.
- `IOS_PROVISIONING_PROFILE_BASE64` — contents of `profile.b64.txt`.
- `FIREBASE_IOS_APP_ID` — the App ID from step 6 (`1:…:ios:…`).

`FIREBASE_SERVICE_ACCOUNT` already exists from the Android setup and is reused.
Once all four secrets are present, the next `ios.yml` run signs the IPA and
distributes it to `testers`.

### Alternative: TestFlight via App Store Connect (not wired)

Instead of ad-hoc (which is capped at the UDIDs registered in the profile and
requires re-issuing the profile for every new device), you can distribute
through **TestFlight**: build with the App Store export method, upload the IPA to
**App Store Connect** (e.g. via `xcrun altool`/`notarytool` or Transporter), and
manage testers there. TestFlight avoids per-device UDID management and supports
external testers, but adds App Store Connect app-record setup and Apple's
build-review step. It is **not wired into `ios.yml`** — noted here as the
production-scale alternative if the ad-hoc tester count becomes limiting.
