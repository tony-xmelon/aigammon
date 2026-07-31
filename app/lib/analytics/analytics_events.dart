/// **The one place** every analytics event name, parameter name, screen name
/// and performance-trace name is written down.
///
/// Nothing else in the app may pass a bare string literal to
/// [AppAnalytics.logEvent] or [AppPerformance]. Two reasons this is a hard
/// rule rather than a style preference:
///
///  * Firebase Analytics event/parameter names are a SCHEMA. Once an event
///    lands in the console under one spelling, renaming it splits the history
///    in two and there is no back-fill. A typo is permanent.
///  * Google reserves a set of event names (`screen_view`, `session_start`, …)
///    and imposes limits (40 chars, alphanumeric + underscore, no leading
///    underscore or digit, 25 parameters per event). Keeping them together is
///    what makes those limits reviewable in one screenful.
///
/// The names below are deliberately snake_case, verb-last, and prefixed by
/// their subject (`match_started`, `cube_offered`) so they sort into families
/// in the console's event list.
library;

/// Custom event names.
abstract final class AnalyticsEvents {
  /// A screen came to the front. Firebase's own reserved name — using it means
  /// the events feed the built-in screen-engagement reports rather than a
  /// parallel custom funnel.
  static const screenView = 'screen_view';

  /// A match was started, from whichever surface starts it.
  /// Params: [AnalyticsParams.mode], [AnalyticsParams.matchLength],
  /// [AnalyticsParams.difficulty] (vs-computer only),
  /// [AnalyticsParams.cubeless], [AnalyticsParams.tutor].
  static const matchStarted = 'match_started';

  /// A match was decided (not merely a game within it).
  /// Params: [AnalyticsParams.mode], [AnalyticsParams.winner],
  /// [AnalyticsParams.scoreWinner], [AnalyticsParams.scoreLoser],
  /// [AnalyticsParams.matchLength].
  static const matchCompleted = 'match_completed';

  /// The tutor's hint panel was opened (the hint was asked for, not merely
  /// available). Params: [AnalyticsParams.mode].
  static const tutorHintUsed = 'tutor_hint_used';

  /// The local player offered a resignation.
  /// Params: [AnalyticsParams.mode], [AnalyticsParams.resignValue].
  static const resignOffered = 'resign_offered';

  /// The local player doubled. Params: [AnalyticsParams.mode],
  /// [AnalyticsParams.cubeValue] (the value BEFORE the double).
  static const cubeOffered = 'cube_offered';

  /// The local player answered an opponent's double.
  /// Params: [AnalyticsParams.mode], [AnalyticsParams.cubeAction] (`take` or
  /// `drop`), [AnalyticsParams.cubeValue].
  static const cubeAnswered = 'cube_answered';

  /// The GitHub-issue feedback link was opened.
  static const feedbackOpened = 'feedback_opened';
}

/// Custom parameter names.
abstract final class AnalyticsParams {
  /// Firebase's reserved screen-name parameter for [AnalyticsEvents.screenView].
  static const screenName = 'screen_name';

  /// One of [AnalyticsModes].
  static const mode = 'mode';

  /// Points the match is played to (1, 3, 5, 7…).
  static const matchLength = 'match_length';

  /// `easy` | `medium` | `hard` | `expert`, vs-computer only.
  static const difficulty = 'difficulty';

  /// Whether the match is played without the doubling cube.
  static const cubeless = 'cubeless';

  /// Whether live tutor mode was on at match start.
  static const tutor = 'tutor';

  /// `local` | `opponent` — deliberately NOT `white`/`black`, which would say
  /// nothing about whether the person using the app won.
  static const winner = 'winner';

  /// Final score, winner's side then loser's.
  static const scoreWinner = 'score_winner';
  static const scoreLoser = 'score_loser';

  /// `single` | `gammon` | `backgammon`.
  static const resignValue = 'resign_value';

  /// The doubling cube's face value at the moment of the action.
  static const cubeValue = 'cube_value';

  /// `take` | `drop`.
  static const cubeAction = 'cube_action';
}

/// The values [AnalyticsParams.mode] may take.
///
/// These mirror the `mode` strings already persisted by
/// `MatchRepository.startMatch` (`vsComputer`, `hotSeat`, `lan`, `online`), so
/// a question answered locally against the history database and the same
/// question answered in the Firebase console agree on their vocabulary.
abstract final class AnalyticsModes {
  static const vsComputer = 'vsComputer';
  static const hotSeat = 'hotSeat';
  static const lan = 'lan';
  static const online = 'online';
}

/// Screen names for [AnalyticsEvents.screenView].
abstract final class AnalyticsScreens {
  static const home = 'home';
  static const newMatch = 'new_match';
  static const game = 'game';
  static const analysis = 'analysis';
  static const history = 'history';
  static const settings = 'settings';
  static const lan = 'lan';
  static const online = 'online';
  static const diagnostics = 'diagnostics';
}

/// Custom performance-trace names.
///
/// Firebase caps custom traces at 100 per app and 32 chars per name; these are
/// chosen to stay well inside both and to describe the WAIT A USER FEELS, not
/// an implementation detail.
abstract final class PerfTraces {
  /// Process start → first frame rasterized. Recorded as a duration metric
  /// because the clock starts before Firebase itself is initialized.
  static const coldStart = 'cold_start_to_first_frame';

  /// One engine move computation — the "AI is thinking" wait.
  static const engineRankMoves = 'engine_rank_moves';

  /// One engine position evaluation (drives bot cube/resign decisions).
  static const engineEvaluate = 'engine_evaluate';

  /// One engine cube evaluation.
  static const engineCubeInfo = 'engine_cube_info';

  /// Handing a built LAN controller its first synchronized state — the
  /// "connecting…" spinner on both the host and the guest side.
  static const lanConnect = 'lan_match_connect';

  /// The same wait for an online match (Firestore transport readiness).
  static const onlineConnect = 'online_match_connect';
}

/// The metric attached by [AppPerformance.recordDuration].
const String kDurationMetric = 'duration_ms';
