import 'package:engine_bindings/engine_bindings.dart' show Difficulty;
import 'package:flutter/material.dart' show ThemeMode;

/// Per-hop checker animation speed. Maps to a [Duration] via [hopDuration].
enum AnimationSpeed {
  /// Animations disabled — checkers snap instantly ([Duration.zero]).
  off,

  /// The production default: 150ms per hop.
  normal,

  /// Snappier: 75ms per hop.
  fast;

  /// The per-hop [Duration] this speed maps to (fed to the board's animation).
  Duration get hopDuration => switch (this) {
        AnimationSpeed.off => Duration.zero,
        AnimationSpeed.normal => const Duration(milliseconds: 150),
        AnimationSpeed.fast => const Duration(milliseconds: 75),
      };
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
  });

  /// The out-of-the-box defaults, matching the `Settings` table's column
  /// defaults (theme: system, animation: normal, length: 5, difficulty:
  /// medium, tutor override: none).
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

  /// The per-hop animation [Duration] for the current [animationSpeed].
  Duration get hopDuration => animationSpeed.hopDuration;

  AppSettings copyWith({
    ThemeMode? themeMode,
    AnimationSpeed? animationSpeed,
    int? defaultMatchLength,
    Difficulty? defaultDifficulty,
    // A sentinel is needed to distinguish "leave unchanged" from "set to null".
    Object? tutorOverride = _unset,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      animationSpeed: animationSpeed ?? this.animationSpeed,
      defaultMatchLength: defaultMatchLength ?? this.defaultMatchLength,
      defaultDifficulty: defaultDifficulty ?? this.defaultDifficulty,
      tutorOverride: identical(tutorOverride, _unset)
          ? this.tutorOverride
          : tutorOverride as bool?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.themeMode == themeMode &&
      other.animationSpeed == animationSpeed &&
      other.defaultMatchLength == defaultMatchLength &&
      other.defaultDifficulty == defaultDifficulty &&
      other.tutorOverride == tutorOverride;

  @override
  int get hashCode => Object.hash(themeMode, animationSpeed, defaultMatchLength,
      defaultDifficulty, tutorOverride);

  @override
  String toString() => 'AppSettings(themeMode: $themeMode, '
      'animationSpeed: $animationSpeed, '
      'defaultMatchLength: $defaultMatchLength, '
      'defaultDifficulty: $defaultDifficulty, '
      'tutorOverride: $tutorOverride)';
}

/// Sentinel marking an un-passed [AppSettings.copyWith] argument (so a caller
/// can set [AppSettings.tutorOverride] back to null explicitly).
const Object _unset = Object();
