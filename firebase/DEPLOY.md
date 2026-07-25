# AIGammon online play — deployment & configuration

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
# From firebase/ — start Auth + Firestore + Functions emulators.
firebase emulators:start

# From app/ — a normal debug run picks up OnlineConfig.emulator()
# (demo-aigammon on 127.0.0.1: Firestore 8080, Auth 9099, Functions 5001).
flutter run
```

Create a match on one client and join it by code from another (a second
`flutter run`, or the two-client emulator E2E test) to exercise online play
end to end. To run the full emulator test matrix locally (functions build +
both suites in throwaway emulators):

```powershell
pwsh firebase/run-emulator-tests.ps1
```

CI runs the same two suites on Linux via `firebase/ci-emulator-suites.sh` inside
a single `firebase emulators:exec` (see the `online` job in
`.github/workflows/ci.yml`).

## Production deployment

### 0. Prerequisites

- **Firebase CLI** installed (`npm install -g firebase-tools`) and logged in as
  an **owner/editor of the `aigammon` project**:

  ```sh
  firebase login
  ```

- **Blaze (pay-as-you-go) billing plan.** The match-lifecycle backend is
  **Cloud Functions v2**, which requires the Blaze plan — the free Spark plan
  cannot deploy 2nd-gen functions. Upgrade the project first in the Firebase
  console (⚙ → *Usage and billing* → *Modify plan* → *Blaze*). At this app's
  scale (server-side dice + match writes only) the metered cost is negligible
  and stays within the free monthly allowances in practice, but a billing
  account must be attached for the deploy to succeed.
- **Anonymous authentication enabled** for the project (Firebase console →
  *Authentication* → *Sign-in method* → enable *Anonymous*). Clients sign in
  anonymously before creating or joining a match.

### 1. Deploy Firestore rules + functions

From the `firebase/` directory:

```sh
firebase deploy --only firestore:rules,functions --project aigammon
```

This pushes `firestore.rules` and the compiled Cloud Functions. (Firestore
indexes are deployed too if `firestore.indexes.json` grows any; it is currently
empty.) The functions are built from TypeScript — `firebase deploy` runs the
`predeploy` build, but you can also `npm run build` in `firebase/functions`
first to catch type errors locally.

### 2. Retrieve the Web API key

The production `OnlineConfig` needs the project's **Web API Key**:

- Firebase console → ⚙ *Project settings* → **General** tab → **Web API Key**.

This key is not a secret in the credential sense (it identifies the project to
Firebase's public REST/Auth endpoints and is safe to ship in a client binary);
access is gated by Firestore security rules and App Check, not by hiding it.

### 3. Build the app for production online play

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
so its APKs have online play disabled. A later change can add
`AIGAMMON_FIREBASE_PROJECT` as a repo **variable** and `AIGAMMON_FIREBASE_API_KEY`
as a repo **secret**, then pass both through as `--dart-define`s in the build
step. Not implemented here — tracked as a follow-up.

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
