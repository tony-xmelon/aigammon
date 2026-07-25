import 'dart:ui' show Color;

/// Immutable palette for rendering a backgammon board. Two presets are
/// provided ([light], [dark]); construct a custom instance for other looks.
class BoardTheme {
  const BoardTheme({
    required this.boardColor,
    required this.pointDark,
    required this.pointLight,
    required this.barColor,
    required this.whiteChecker,
    required this.blackChecker,
    required this.whiteCheckerBorder,
    required this.blackCheckerBorder,
    required this.highlightSource,
    required this.highlightDestination,
    required this.highlightDestinationFill,
    required this.selectedOutline,
    required this.diceColor,
    required this.dicePipColor,
    required this.cubeColor,
    required this.textColor,
  });

  /// Felt background of the playing surface.
  final Color boardColor;

  /// The two alternating triangle colours.
  final Color pointDark;
  final Color pointLight;

  /// The central bar strip.
  final Color barColor;

  /// Checker fills.
  final Color whiteChecker;
  final Color blackChecker;

  /// Ring drawn around each checker — PER PLAYER so the rim can invert against
  /// the fill: a light checker wears a DARK rim, a dark checker a LIGHT rim.
  /// This is what keeps a checker's silhouette legible on any surface (a dark
  /// checker on dark felt is defined by its light rim, and vice versa).
  final Color whiteCheckerBorder;
  final Color blackCheckerBorder;

  /// Ring drawn around a selectable (but not-yet-picked-up) source's TOP
  /// CHECKER. A checker-anchored halo, not a triangle tint, so its result never
  /// varies with the underlying point colour.
  final Color highlightSource;

  /// Destination highlight, drawn on the target TRIANGLE. [highlightDestination]
  /// is the (opaque) edge ring; [highlightDestinationFill] is the OPAQUE uniform
  /// fill that neutralises the underlying point colour, so a highlighted
  /// destination renders identically over a dark or a light point.
  final Color highlightDestination;
  final Color highlightDestinationFill;

  /// Ring drawn around the currently picked-up source's TOP CHECKER.
  final Color selectedOutline;

  /// Dice body and pip colours.
  final Color diceColor;
  final Color dicePipColor;

  /// Doubling-cube body colour.
  final Color cubeColor;

  /// Colour for count labels, cube value, and other text.
  final Color textColor;

  /// Warm tan felt, rich crimson / cream points, ivory / ebony checkers with
  /// inverted rims. Tuned so every checker's silhouette clears WCAG 3:1 against
  /// every surface and the crimson points visibly pop off the felt (see
  /// board_contrast_test.dart).
  static const BoardTheme light = BoardTheme(
    boardColor: Color(0xFFB8814D), // warm tan felt
    pointDark: Color(0xFFC62A2F), // rich crimson
    pointLight: Color(0xFFF0DEBC), // cream
    barColor: Color(0xFF4A3218), // dark walnut
    whiteChecker: Color(0xFFF7EEDA), // ivory
    blackChecker: Color(0xFF1E1712), // ebony
    whiteCheckerBorder: Color(0xFF241608), // deep espresso rim on ivory
    blackCheckerBorder: Color(0xFFF2E4C6), // warm off-white rim on ebony
    highlightSource: Color(0xCCFFD24A), // dim amber source-checker ring
    highlightDestination: Color(0xFF5FD98C), // opaque green edge ring
    highlightDestinationFill: Color(0xFF357A52), // opaque uniform green fill
    selectedOutline: Color(0xFFFFD24A), // amber selected-checker ring
    diceColor: Color(0xFFF7F2E7),
    dicePipColor: Color(0xFF1A1A1A),
    cubeColor: Color(0xFFF2ECDC),
    textColor: Color(0xFFF5ECD8),
  );

  /// Muted low-light palette. Same silhouette-first rules as [light]: the crimson
  /// points are raised clear of the slate felt, and the dark checkers wear a
  /// light rim so they never vanish into the board (see board_contrast_test.dart).
  static const BoardTheme dark = BoardTheme(
    boardColor: Color(0xFF2A3742), // slate felt
    pointDark: Color(0xFF8A4248), // warm muted crimson
    pointLight: Color(0xFFA6B2BE), // pewter
    barColor: Color(0xFF121B24),
    whiteChecker: Color(0xFFE4EBF2), // pale
    blackChecker: Color(0xFF0D1216), // near-black
    whiteCheckerBorder: Color(0xFF05090C), // near-black rim on pale checker
    blackCheckerBorder: Color(0xFFB8C6D2), // light pewter rim on dark checker
    highlightSource: Color(0xCCFFC53D), // dim amber source-checker ring
    highlightDestination: Color(0xFF62E2A0), // opaque green edge ring
    highlightDestinationFill: Color(0xFF2F6B4A), // opaque uniform green fill
    selectedOutline: Color(0xFFFFC53D),
    diceColor: Color(0xFFE8ECF0),
    dicePipColor: Color(0xFF14181C),
    cubeColor: Color(0xFFDDE3EA),
    textColor: Color(0xFFE6ECF2),
  );
}
