/// Pure-Dart REST transport + MatchApi facade for AIGammon online play.
///
/// Serverless (Plan 16): anonymous Identity-Toolkit auth plus direct Firestore
/// document operations, with `firebase/firestore.rules` as the only
/// server-side logic. No Cloud Functions.
///
/// Plan 17 adds [FirestoreTransport], this package's `MatchTransport`
/// implementation — the seam the unified match controller drives, over the very
/// same document model.
library;

/// The commit-reveal fair-dice protocol now lives in `package:match_transport`
/// (Plan 17: it is shared by LAN and online). Re-exported here so every existing
/// importer of `package:online_client/online_client.dart` keeps compiling; the
/// transport surface of that package is deliberately NOT re-exported.
export 'package:match_transport/match_transport.dart'
    show
        CompletedRoll,
        DerivationByteStream,
        FairDiceCheatException,
        FairDicePhase,
        RollerSession,
        WitnessSession,
        bytesToHex,
        commitFor,
        commitMatches,
        diceFrom,
        diceMatchRoll,
        generateSecretHex,
        hex64ToBytes,
        isHex64,
        kHexLength,
        kRejectAtOrAbove,
        kSecretBytes,
        openingDiceFrom,
        openingDiceMatchRoll,
        sampleDie;

export 'src/auth_client.dart';
export 'src/firestore_docs.dart';
export 'src/firestore_transport.dart';
export 'src/firestore_value.dart';
export 'src/match_api.dart';
export 'src/online_config.dart';
export 'src/online_exception.dart';
export 'src/token_store.dart';
