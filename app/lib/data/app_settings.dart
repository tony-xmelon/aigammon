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
    this.dragHintShown = false,
  });

  /// The out-of-the-box defaults, matching the `Settings` table's column
  /// defaults (theme: system, animation: normal, length: 5, difficulty:
  /// medium, tutor override: none, highlights/drag/combined-taps/scoring on,
  /// drag-hint not yet shown).
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

  /// Whether the one-time drag/tap discoverability hint has already been shown.
  final bool dragHintShown;

  /// The [AnimationTimings] preset for the current [animationSpeed].
  AnimationTimings get timings => animationSpeed.timings;

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
      'dragHintShown: $dragHintShown)';
}

/// Sentinel marking an un-passed [AppSettings.copyWith] argument (so a caller
/// can set [AppSettings.tutorOverride] back to null explicitly).
const Object _unset = Object();
