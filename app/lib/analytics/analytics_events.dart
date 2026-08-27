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

  // --- Buddy Mode ------------------------------------------------------------
  //
  // The spec's field-tuning metrics, and they are field-tuning metrics rather
  // than usage counts: Buddy Mode ships with a dozen constants that could not
  // be measured on a development machine (see the "Provisional" blocks in
  // `lib/buddy/camera_frame_source.dart` and `dice_sound_trigger.dart`), and
  // these five events are what turns a phone in somebody's kitchen into
  // evidence about them.
  //
  // Two of them fire once a session and three fire per occurrence. Nothing
  // fires per FRAME: readability is assessed four times a second, and the one
  // number worth having about it — how much of a session the light was red for
  // — travels as a rate on [buddySessionEnded] rather than as a stream of
  // events nobody could afford to send.

  /// A Buddy match began — a calibration is installed and the game screen is
  /// mounting.
  ///
  /// **Not "the camera is open".** This fires from `initState`, before the open
  /// it kicks off has come back, so a session whose camera never opened at all
  /// is counted here. That is the denominator worth having: it is how many
  /// times a user got as far as starting a match, and what became of each one
  /// is what [buddySessionEnded]'s completion rate answers — a camera that
  /// failed shows up there as a session that ended without completing.
  ///
  /// Params: [AnalyticsParams.mode], [AnalyticsParams.matchLength],
  /// [AnalyticsParams.difficulty], [AnalyticsParams.cubeless],
  /// [AnalyticsParams.buddySeat], [AnalyticsParams.buddyPhrasing],
  /// [AnalyticsParams.micHint].
  static const buddySessionStarted = 'buddy_session_started';

  /// A Buddy match ended, whether it was decided or merely left.
  /// Params: [AnalyticsParams.mode], [AnalyticsParams.buddyCompleted],
  /// [AnalyticsParams.readabilityRedRate], [AnalyticsParams.micState],
  /// [AnalyticsParams.micHints].
  static const buddySessionEnded = 'buddy_session_ended';

  /// The guided corner flow tried to learn a board — the single most important
  /// number in the mode, because a calibration that fails is a mode that does
  /// not start. Params: [AnalyticsParams.calibrationOk],
  /// [AnalyticsParams.recalibration].
  static const buddyCalibrationAttempted = 'buddy_calibration_attempted';

  /// The aim is being fixed mid-match: either the user asked, or the light said
  /// the calibration was gone. Params: [AnalyticsParams.calibrationLost].
  static const buddyRecalibrationEntered = 'buddy_recalibration_entered';

  /// A perceptual input was answered by hand instead. Not a failure event —
  /// tapping a roll in is a shipping path, not a fallback from one — but the
  /// RATE is what says how much of the mode perception is actually carrying.
  /// Params: [AnalyticsParams.buddyFallback].
  static const buddyFallbackUsed = 'buddy_fallback_used';
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

  // --- Buddy Mode ------------------------------------------------------------

  /// `near` | `far` — which side of the board the user sat at, as the camera
  /// saw it. A `BuddySeat.name`.
  static const buddySeat = 'buddy_seat';

  /// `terse` | `friendly` — how Buddy worded plays for this match. A
  /// `BuddyPhrasing.name`.
  static const buddyPhrasing = 'buddy_phrasing';

  /// Whether the dice-sound attention hint was ENABLED for this session (the
  /// v9 setting). Not whether it ever ran — see [micState].
  static const micHint = 'mic_hint';

  /// One of [BuddyMicStates]: what actually became of the microphone.
  static const micState = 'mic_state';

  /// How many attention hints the microphone raised over the session. Read
  /// against [micState]: `listening` with a count of zero is a detector that
  /// heard nothing, which is a different finding from one that never ran.
  static const micHints = 'mic_hints';

  /// Whether the match was DECIDED, as opposed to left part-played. The
  /// denominator for every "did the mode survive a whole match" question.
  static const buddyCompleted = 'buddy_completed';

  /// The fraction of a session the readability light was red, 0..1.
  ///
  /// Aggregated over the session and sent once, over at most ONE assessment
  /// per `kReadabilitySampleInterval` — the frame gate's ordinary cadence —
  /// rather than over every frame that happened to be published. That makes it
  /// **independent of the attention nudge**: the microphone triples the
  /// publication rate for a second and a half after each throw, landing on the
  /// hand withdrawing over the board, so a per-frame denominator would report
  /// a worse-lit room for [micState] `listening` than for the same room with
  /// the hint off. As it stands this can be read straight across every
  /// [micState] without segmenting on it — though the event carries [micState]
  /// regardless, because it costs nothing and a question nobody has asked yet
  /// may still want the split.
  ///
  /// Frames the session never assessed (there was no calibration) are outside
  /// it altogether, so this is "how often could the camera not read a board it
  /// was pointed at" rather than "how often was there no answer".
  static const readabilityRedRate = 'readability_red_rate';

  /// Whether the calibration attempt produced a usable board.
  static const calibrationOk = 'calibration_ok';

  /// Whether this attempt was a RE-calibration (mid-match) rather than the one
  /// that starts a session. The two have very different success rates to
  /// expect: one is a user aiming carefully at a set-up board, the other is a
  /// user rescuing a match with checkers all over it.
  static const recalibration = 'recalibration';

  /// Whether the calibration was ALREADY dead when the flow was entered (the
  /// light demanded it) rather than the user choosing to re-aim a working one.
  static const calibrationLost = 'calibration_lost';

  /// One of [BuddyFallbacks].
  static const buddyFallback = 'buddy_fallback';
}

/// The values [AnalyticsParams.buddyFallback] may take.
///
/// Snake_case constants rather than an enum's `.name`, because these are wire
/// strings and `dicePad` is not the spelling the console should carry — see
/// this file's header on why a name that lands wrong lands wrong forever.
abstract final class BuddyFallbacks {
  /// A roll was typed on the pad instead of read off the felt.
  static const dicePad = 'dice_pad';

  /// Two legal plays left the same position and the user chose between them.
  static const candidatePicker = 'candidate_picker';

  /// A play was tapped out on the belief mirror because the camera did not see
  /// it happen.
  static const tapCorrect = 'tap_correct';
}

/// The values [AnalyticsParams.micState] may take.
abstract final class BuddyMicStates {
  /// The v9 setting was off — either the user turned it off, or a past refusal
  /// latched it. Nothing was asked for.
  static const off = 'off';

  /// Enabled, but the session never got as far as needing it (it ends before
  /// the first throw is waited for).
  static const unused = 'unused';

  /// Asked for, and the platform had nothing to give: no microphone, no
  /// plugin, or a flat refusal from the OS layer.
  static const unavailable = 'unavailable';

  /// Asked for, and the user said no. This is the one that latches the setting.
  static const refused = 'refused';

  /// It ran. [AnalyticsParams.micHints] says how much it had to say.
  static const listening = 'listening';
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

  /// A match played on a real board through the camera. Mirrors the literal
  /// `BuddyGameScreen` passes to `MatchRepository.startMatch`, so the mode
  /// carried by the Buddy events answers to the same word the history database
  /// files those matches under.
  static const buddy = 'buddy';
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

  /// The three Buddy Mode screens. Separate entries rather than one `buddy`,
  /// because the funnel between them is the question worth asking: how many
  /// people who open the setup screen reach a calibration, and how many of
  /// those reach a match.
  static const buddySetup = 'buddy_setup';
  static const buddyCalibration = 'buddy_calibration';
  static const buddyGame = 'buddy_game';
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
