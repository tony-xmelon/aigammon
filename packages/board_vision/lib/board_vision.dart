/// The perception core of AIGammon's Buddy Mode (Plan 19).
///
/// Frames in, typed answers about a **physical** backgammon board out. The
/// package is deliberately pure Dart with no camera, no plugin and no
/// `dart:ui`: the app owns the camera and hands over [Frame]s, and everything
/// here builds and runs on a desktop against the committed corpus — the same
/// discipline the rules and transport packages follow.
///
/// The architectural bet the whole design rests on is that perception is never
/// asked an open question. The app holds the authoritative game state, so the
/// queries are small and discrete — "which of these seven legal plays
/// happened?", "are the settled dice 6 and 3?", "does point 6 still hold the
/// four checkers I expect?" — and matching an observation against an
/// enumerated answer space is what makes a classical-CV backbone viable. See
/// `docs/superpowers/specs/2026-08-02-buddy-mode-design.md`.
library;

export 'src/board_geometry.dart';
export 'src/board_vision_base.dart';
export 'src/calibration.dart';
export 'src/color_model.dart';
export 'src/dice_reader.dart';
export 'src/frame.dart';
export 'src/geometry_types.dart';
export 'src/homography.dart';
export 'src/occupancy.dart';
export 'src/roi_atlas.dart';
export 'src/roi_sampler.dart';
export 'src/targets.dart';
