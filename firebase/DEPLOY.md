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
