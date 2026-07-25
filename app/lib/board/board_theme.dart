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
    required this.checkerBorder,
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

  /// Ring drawn around every checker.
  final Color checkerBorder;

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

  /// Warm felt-brown board, cream/maroon points, ivory/ebony checkers.
  static const BoardTheme light = BoardTheme(
    boardColor: Color(0xFF6B4A2B), // walnut felt
    pointDark: Color(0xFF7B1E22), // maroon
    pointLight: Color(0xFFEBD9B4), // cream
    barColor: Color(0xFF4A3018), // darker wood
    whiteChecker: Color(0xFFF5ECD8), // ivory
    blackChecker: Color(0xFF241C16), // ebony
    checkerBorder: Color(0xFF120C08),
    highlightSource: Color(0xCCFFD24A), // dim amber source-checker ring
    highlightDestination: Color(0xFF5FD98C), // opaque green edge ring
    highlightDestinationFill: Color(0xFF357A52), // opaque uniform green fill
    selectedOutline: Color(0xFFFFD24A), // amber selected-checker ring
    diceColor: Color(0xFFF7F2E7),
    dicePipColor: Color(0xFF1A1A1A),
    cubeColor: Color(0xFFF2ECDC),
    textColor: Color(0xFFF5ECD8),
  );

  /// Muted low-light palette.
  static const BoardTheme dark = BoardTheme(
    boardColor: Color(0xFF23303A), // slate felt
    pointDark: Color(0xFF3A4650), // steel
    pointLight: Color(0xFF8A97A3), // pewter
    barColor: Color(0xFF16202A),
    whiteChecker: Color(0xFFDCE3EA), // pale
    blackChecker: Color(0xFF11171C), // near-black
    checkerBorder: Color(0xFF05090C),
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
