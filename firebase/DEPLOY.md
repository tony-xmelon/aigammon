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
end to end.

## Production flow (placeholder)

Point a release build at a real Firebase project by supplying both defines:

```sh
flutter build apk \
  --dart-define=AIGAMMON_FIREBASE_PROJECT=<project-id> \
  --dart-define=AIGAMMON_FIREBASE_API_KEY=<web-api-key>
```

Full production deployment — provisioning the project, deploying Firestore
rules/indexes and the Cloud Functions, and enabling anonymous auth — is
documented in a later task.
