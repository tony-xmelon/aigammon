/// Pure-Dart REST transport + MatchApi facade for AIGammon online play.
///
/// Serverless (Plan 16): anonymous Identity-Toolkit auth plus direct Firestore
/// document operations, with `firebase/firestore.rules` as the only
/// server-side logic. No Cloud Functions.
library;

export 'src/auth_client.dart';
export 'src/fair_dice.dart';
export 'src/firestore_docs.dart';
export 'src/firestore_value.dart';
export 'src/match_api.dart';
export 'src/online_config.dart';
export 'src/online_exception.dart';
