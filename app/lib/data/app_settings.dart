import 'package:engine_bindings/engine_bindings.dart' show Difficulty;
import 'package:flutter/material.dart' show ThemeMode;

/// Checker + dice animation speed. Maps to an [AnimationTimings] preset via
/// [timings].
enum AnimationSpeed {
  /// Animations disabled — checkers snap instantly, dice show the settled roll
  /// with no tumble ([AnimationTimings.off], all zero).
  off,

  /// The production default, tuned to be TRACKABLE: a leisurely per-hop travel
  /// with a pause between hops, a slow dice tumble, and a settle pause before
  /// the opponent's move plays ([AnimationTimings.normal]).
  normal,

  /// Snappier across the board for players who find [normal] too slow
  /// ([AnimationTimings.fast]).
  fast;

  /// The [AnimationTimings] preset this speed maps to (fed to the board + the
  /// game screen's dice-roll beat).
  AnimationTimings get timings => switch (this) {
        AnimationSpeed.off => AnimationTimings.off,
        AnimationSpeed.normal => AnimationTimings.normal,
        AnimationSpeed.fast => AnimationTimings.fast,
      };
}

/// The full set of durations that pace the opponent-move + dice-roll
/// animations, derived from [AnimationSpeed] via [AnimationSpeed.timings].
///
/// Threaded from the persisted settings through [AppSettings.timings] into the
/// game screen (which owns the dice-roll beat) and the board (which owns the
/// checker travel). The [normal] preset is deliberately leisurely so a human can
/// TRACK both the tumbling dice and the travelling checker; there is no total
/// cap on a multi-hop move (a four-hop double plays out fully rather than being
/// squeezed into a fixed budget).
///
/// Fields:
/// * [hop] — one checker's travel time for a single hop.
/// * [interHop] — the stationary pause BETWEEN consecutive hops of a move (the
///   checker rests at each intermediate landing before continuing).
/// * [diceFrame] — how long each tumbling dice frame is shown during the beat.
/// * [diceFrames] — how many tumbling frames the beat cycles through.
/// * [diceSettlePause] — after the dice settle to the real roll, the pause held
///   before the opponent's move animation is allowed to begin (so the dice are
///   readable before the checker moves).
class AnimationTimings {
  const AnimationTimings({
    required this.hop,
    required this.interHop,
    required this.diceFrame,
    required this.diceFrames,
    required this.diceSettlePause,
  });

  /// Everything off: checkers snap, dice show the settled roll instantly.
  static const AnimationTimings off = AnimationTimings(
    hop: Duration.zero,
    interHop: Duration.zero,
    diceFrame: Duration.zero,
    diceFrames: 0,
    diceSettlePause: Duration.zero,
  );

  /// The trackable production default.
  static const AnimationTimings normal = AnimationTimings(
    hop: Duration(milliseconds: 350),
    interHop: Duration(milliseconds: 120),
    diceFrame: Duration(milliseconds: 140),
    diceFrames: 6,
    diceSettlePause: Duration(milliseconds: 500),
  );

  /// Snappier across the board.
  static const AnimationTimings fast = AnimationTimings(
    hop: Duration(milliseconds: 120),
    interHop: Duration(milliseconds: 40),
    diceFrame: Duration(milliseconds: 60),
    diceFrames: 5,
    diceSettlePause: Duration(milliseconds: 200),
  );

  /// Per-hop checker travel time.
  final Duration hop;

  /// Stationary pause between consecutive hops of the same move.
  final Duration interHop;

  /// Duration each tumbling dice frame is shown during the roll beat.
  final Duration diceFrame;

  /// Number of tumbling frames cycled during the roll beat.
  final int diceFrames;

  /// Pause held (after the dice settle) before the opponent's move animates.
  final Duration diceSettlePause;

  /// Whether any animation runs at all (the [off] preset is fully disabled).
  bool get enabled => hop > Duration.zero;

  /// Whether the dice-roll BEAT runs: there must be at least one tumbling frame
  /// and a positive time to show it for. False for the [off] preset (so "None"
  /// speed implies no beat) and for any preset put through [withoutDiceBeat] (the
  /// "Dice roll animation" setting turned off), in which case rolls settle
  /// instantly while checker travel keeps whatever pacing was chosen.
  bool get diceBeatEnabled => diceFrames > 0 && diceFrame > Duration.zero;

  /// This preset with the dice beat stripped out — no tumbling frames, no settle
  /// pause — and the checker travel untouched. How the "Dice roll animation"
  /// toggle is applied (see [AppSettings.timings]), so that everything downstream
  /// keeps reading a single [AnimationTimings] and cannot disagree about whether
  /// the beat is on.
  AnimationTimings withoutDiceBeat() => AnimationTimings(
        hop: hop,
        interHop: interHop,
        diceFrame: Duration.zero,
        diceFrames: 0,
        diceSettlePause: Duration.zero,
      );

  @override
  bool operator ==(Object other) =>
      other is AnimationTimings &&
      other.hop == hop &&
      other.interHop == interHop &&
      other.diceFrame == diceFrame &&
      other.diceFrames == diceFrames &&
      other.diceSettlePause == diceSettlePause;

  @override
  int get hashCode =>
      Object.hash(hop, interHop, diceFrame, diceFrames, diceSettlePause);

  @override
  String toString() => 'AnimationTimings(hop: $hop, interHop: $interHop, '
      'diceFrame: $diceFrame, diceFrames: $diceFrames, '
      'diceSettlePause: $diceSettlePause)';
}

/// The user's persisted app-wide preferences (schema v2 `Settings` row).
///
/// A plain value type with structural equality (so Riverpod/stream consumers
/// only rebuild on a genuine change) and a [copyWith] for autosave edits.
/// Enums are stored in the database by their [Enum.name]; [tutorOverride] is a
/// nullable tri-state (null = fall back to the per-mode default).
class AppSettings {
  const AppSettings({
    required this.themeMode,
    required this.animationSpeed,
    required this.defaultMatchLength,
    required this.defaultDifficulty,
    required this.tutorOverride,
    this.showHighlights = true,
    this.enableDrag = true,
    this.enableCombinedTaps = true,
    this.showScoring = true,
    this.diceRollAnimation = true,
    this.showPassDevice = false,
    this.rotateBoardHotSeat = false,
    this.dragHintShown = false,
  });

  /// The out-of-the-box defaults, matching the `Settings` table's column
  /// defaults (theme: system, animation: normal, length: 5, difficulty:
  /// medium, tutor override: none, highlights/drag/combined-taps/scoring and the
  /// dice-roll animation on, the hot-seat pass-device cover OFF, the hot-seat
  /// board rotation OFF (the tabletop layout), drag-hint not yet shown).
  static const AppSettings defaults = AppSettings(
    themeMode: ThemeMode.system,
    animationSpeed: AnimationSpeed.normal,
    defaultMatchLength: 5,
    defaultDifficulty: Difficulty.medium,
    tutorOverride: null,
  );

  /// Light / dark / follow-system for the whole app.
  final ThemeMode themeMode;

  /// Checker-movement animation speed.
  final AnimationSpeed animationSpeed;

  /// The match length pre-selected on the new-match screen (1/3/5/7).
  final int defaultMatchLength;

  /// The AI difficulty pre-selected on the new-match screen.
  final Difficulty defaultDifficulty;

  /// Tutor tri-state: null = use the per-mode default (see new-match screen),
  /// true = always start ON, false = always start OFF.
  final bool? tutorOverride;

  /// Whether the board paints selection rings and destination highlights.
  final bool showHighlights;

  /// Whether drag-to-move is enabled (ON by default as of schema v4; tap-to-move
  /// always works too).
  final bool enableDrag;

  /// Whether combined (multi-hop, same-checker) landing taps are enabled.
  final bool enableCombinedTaps;

  /// Whether the HUD shows the running match score.
  final bool showScoring;

  /// Whether each roll TUMBLES before it settles (schema v5, ON by default).
  ///
  /// Off means every roll — yours and the opponent's — appears settled at once:
  /// no tumbling faces, no settle pause, and no move-entry hold behind either.
  /// Checker travel is unaffected; that is what [animationSpeed] controls (and
  /// [AnimationSpeed.off] implies this off too, since a preset with no frames has
  /// no beat to run). Applied through [timings], so no consumer has to know about
  /// this flag — see [AnimationTimings.withoutDiceBeat].
  final bool diceRollAnimation;

  /// Whether the hot-seat "Pass the device" cover screen is shown between turns
  /// (schema v6). OFF by default, per the reported "do not show the pass the
  /// device screen, or at least make it a setting, disabled by default": with it
  /// off the turn simply hands over and the board's flip is the cue. Read only
  /// in a hot-seat match; every other mode ignores it.
  final bool showPassDevice;

  /// Whether a hot-seat match flips the board between turns so the active player
  /// is at the bottom (schema v7). OFF by default — the TABLETOP layout the
  /// reported feedback asked for: "when playing person vs person, the default
  /// should be not flipping the board. People will share the device at each
  /// side, place action buttons for each player, and keep the board fixed".
  ///
  /// Off, the board is pinned White-at-bottom and BOTH players get an action bar
  /// at their own edge (the top one rendered upside-down for them). On restores
  /// the pre-v7 paradigm: one bottom action bar, and the board rotating to
  /// whoever is on turn. Read only in a hot-seat match; every other mode ignores
  /// it. Independent of [showPassDevice], which works with either.
  final bool rotateBoardHotSeat;

  /// Whether the one-time drag/tap discoverability hint has already been shown.
  final bool dragHintShown;

  /// The [AnimationTimings] preset for the current [animationSpeed], with the
  /// dice beat stripped out when [diceRollAnimation] is off.
  AnimationTimings get timings => diceRollAnimation
      ? animationSpeed.timings
      : animationSpeed.timings.withoutDiceBeat();

  AppSettings copyWith({
    ThemeMode? themeMode,
    AnimationSpeed? animationSpeed,
    int? defaultMatchLength,
    Difficulty? defaultDifficulty,
    // A sentinel is needed to distinguish "leave unchanged" from "set to null".
    Object? tutorOverride = _unset,
    bool? showHighlights,
    bool? enableDrag,
    bool? enableCombinedTaps,
    bool? showScoring,
    bool? diceRollAnimation,
    bool? showPassDevice,
    bool? rotateBoardHotSeat,
    bool? dragHintShown,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      animationSpeed: animationSpeed ?? this.animationSpeed,
      defaultMatchLength: defaultMatchLength ?? this.defaultMatchLength,
      defaultDifficulty: defaultDifficulty ?? this.defaultDifficulty,
      tutorOverride: identical(tutorOverride, _unset)
          ? this.tutorOverride
          : tutorOverride as bool?,
      showHighlights: showHighlights ?? this.showHighlights,
      enableDrag: enableDrag ?? this.enableDrag,
      enableCombinedTaps: enableCombinedTaps ?? this.enableCombinedTaps,
      showScoring: showScoring ?? this.showScoring,
      diceRollAnimation: diceRollAnimation ?? this.diceRollAnimation,
      showPassDevice: showPassDevice ?? this.showPassDevice,
      rotateBoardHotSeat: rotateBoardHotSeat ?? this.rotateBoardHotSeat,
      dragHintShown: dragHintShown ?? this.dragHintShown,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.themeMode == themeMode &&
      other.animationSpeed == animationSpeed &&
      other.defaultMatchLength == defaultMatchLength &&
      other.defaultDifficulty == defaultDifficulty &&
      other.tutorOverride == tutorOverride &&
      other.showHighlights == showHighlights &&
      other.enableDrag == enableDrag &&
      other.enableCombinedTaps == enableCombinedTaps &&
      other.showScoring == showScoring &&
      other.diceRollAnimation == diceRollAnimation &&
      other.showPassDevice == showPassDevice &&
      other.rotateBoardHotSeat == rotateBoardHotSeat &&
      other.dragHintShown == dragHintShown;

  @override
  int get hashCode => Object.hash(
      themeMode,
      animationSpeed,
      defaultMatchLength,
      defaultDifficulty,
      tutorOverride,
      showHighlights,
      enableDrag,
      enableCombinedTaps,
      showScoring,
      diceRollAnimation,
      showPassDevice,
      rotateBoardHotSeat,
      dragHintShown);

  @override
  String toString() => 'AppSettings(themeMode: $themeMode, '
      'animationSpeed: $animationSpeed, '
      'defaultMatchLength: $defaultMatchLength, '
      'defaultDifficulty: $defaultDifficulty, '
      'tutorOverride: $tutorOverride, '
      'showHighlights: $showHighlights, '
      'enableDrag: $enableDrag, '
      'enableCombinedTaps: $enableCombinedTaps, '
      'showScoring: $showScoring, '
      'diceRollAnimation: $diceRollAnimation, '
      'showPassDevice: $showPassDevice, '
      'rotateBoardHotSeat: $rotateBoardHotSeat, '
      'dragHintShown: $dragHintShown)';
}

/// Sentinel marking an un-passed [AppSettings.copyWith] argument (so a caller
/// can set [AppSettings.tutorOverride] back to null explicitly).
const Object _unset = Object();
