import 'board_verifier.dart';

/// What to do about one region the board and the game disagree on.
///
/// **Which side is likelier wrong is a question with a measured answer**, and
/// it is not the same answer every time. The pipeline's error structure is
/// lopsided in ways the corpus pinned: colour is right 0.954 of the time and
/// counts 0.784; tall stacks read short and short ones read long; a man
/// standing where nothing should be is something felt and shadow do not
/// produce. So a discrepancy is not simply "check the board" — for a whole
/// class of them the honest advice is "the camera is probably wrong, carry on".
enum DriftResolution {
  /// The **board** is likelier wrong. Something on the table is not where the
  /// game says, and moving it is what fixes this.
  moveTheCheckers,

  /// The **camera** is likelier wrong. The game's own state is the better
  /// record and the session should keep it.
  trustTheGame,

  /// Neither side is clearly right. This is the one that goes to the spec's
  /// side-by-side resolve screen for the user to settle.
  askTheUser,

  /// Nothing in the picture can settle it, ever — a bear-off tray on a board
  /// that has no wells. Not a disagreement and not an agreement; shown so the
  /// user knows what was and was not checked.
  cannotBeSeen,
}

/// One region's discrepancy, with what to do about it.
class DriftFinding {
  final RegionVerification region;
  final DriftResolution resolution;

  /// A sentence for the resolve screen, written to be shown as it stands.
  /// Always follows [RegionVerification.message] — what was seen — with what
  /// the pipeline's own error structure says about it.
  final String suggestion;

  const DriftFinding({
    required this.region,
    required this.resolution,
    required this.suggestion,
  });

  @override
  String toString() => 'DriftFinding(${resolution.name}: $suggestion)';
}

/// The discrepancy set plus what to do about each — the spec's drift-recovery
/// answer, and what the side-by-side "camera says / game says" screen renders.
///
/// A thin, typed layer over [BoardDiscrepancies] on purpose. The verifier's job
/// is to say what the picture shows; this one's is to say which side of a
/// disagreement to doubt, and keeping them apart means the routing can be
/// argued about — and re-measured — without touching the measurement.
class DriftReport {
  final BoardDiscrepancies discrepancies;

  /// One per contradiction, strongest first, plus one per region this board
  /// cannot show that the game expects something in.
  final List<DriftFinding> findings;

  DriftReport._(this.discrepancies, List<DriftFinding> findings)
      : findings = List<DriftFinding>.unmodifiable(findings);

  /// Routes every discrepancy in [discrepancies].
  factory DriftReport.of(BoardDiscrepancies discrepancies) => DriftReport._(
        discrepancies,
        <DriftFinding>[
          for (final region in discrepancies.discrepancies) _route(region),
          // An unobservable region is worth showing only when the game expects
          // something in it. "The tray this board does not have is empty" is
          // noise on a resolve screen; "the two men the game says you bore off
          // cannot be seen" is the reason the count on screen may look wrong.
          for (final region in discrepancies.unobservable)
            if (region.expected > 0) _route(region),
        ],
      );

  /// Whether there is anything to resolve at all.
  bool get agrees => discrepancies.agrees;

  /// Whether any finding genuinely needs the user to settle it, as opposed to
  /// being something the session can act on by itself.
  bool get needsUser =>
      findings.any((f) => f.resolution == DriftResolution.askTheUser);

  String get message => discrepancies.message;

  static DriftFinding _route(RegionVerification region) {
    if (region.verdict == RegionVerdict.unobservable) {
      return DriftFinding(
        region: region,
        resolution: DriftResolution.cannotBeSeen,
        suggestion: '${region.message}. Nothing here can confirm it either '
            'way, so the game\'s own record stands.',
      );
    }
    final (resolution, why) = switch (region.kind!) {
      // Colour is the pipeline's strongest signal — 0.954 measured against
      // 0.784 for colour and count together — so a region showing the wrong
      // player's men is very nearly always the board.
      DiscrepancyKind.wrongColour => (
          DriftResolution.moveTheCheckers,
          'The camera is right about colour far more often than about anything '
              'else, so it is likely the board that is wrong here.',
        ),
      // Felt and shadow do not produce a whole checker's worth of run. A man
      // standing where the game says nothing is a man somebody put there — or
      // the board and the game came apart a turn ago.
      DiscrepancyKind.unexpectedlyOccupied => (
          DriftResolution.moveTheCheckers,
          'Something is standing there that the game does not know about — a '
              'checker left behind, or a move it did not see.',
        ),
      // Nothing at all where men are expected, and this one is a coin-toss at
      // every height.
      //
      // **"A whole stack does not vanish into a misread" was the obvious
      // routing and the bed falsified it.** On the classic palette with a lamp
      // down the table — the gradient measured off the real frame's 19-point —
      // a Black FIVE-stack leaves a run of 0.03 where a checker is 0.09 deep,
      // and four of the starting position's black stacks disappear at once. So
      // a tall stack missing from the picture is not proof that it is missing
      // from the board, and routing it to the user's hands would send them to
      // move fifteen checkers that are exactly where they should be. Both
      // heights go to the user, which is what the side-by-side screen is for.
      DiscrepancyKind.unexpectedlyEmpty => (
          DriftResolution.askTheUser,
          region.expected <= BoardVerifier.shortStack
              ? 'A dark point can swallow a lone checker, so this is as likely '
                  'to be a misread as a missing man.'
              : 'A whole stack missing from the picture is either a board that '
                  'is wrong or a corner the camera cannot read — and from here '
                  'those look the same.',
        ),
      // The measured far-half undercount, and the case the whole routing
      // exists for: on the real corpus a five-stack reads 1.57 checkers short
      // on average and a six-stack 4.05, every one of them in the direction the
      // perspective predicts.
      DiscrepancyKind.wrongCount => _routeCount(region),
    };
    return DriftFinding(
      region: region,
      resolution: resolution,
      suggestion: '${region.message}. $why',
    );
  }

  static (DriftResolution, String) _routeCount(RegionVerification region) {
    if (region.expected <= BoardVerifier.shortStack) {
      return (
        DriftResolution.moveTheCheckers,
        'A stack this short is one the camera counts well, so it is likely '
            'the board that is wrong here.',
      );
    }
    final out = (region.observedHeight - region.expected).abs();
    if (out <= 1) {
      return (
        DriftResolution.trustTheGame,
        'Tall stacks read short from this seat — a checker or so out is what '
            'the camera does here, not what the board is doing. Keep the '
            'game\'s count.',
      );
    }
    return (
      DriftResolution.askTheUser,
      'That is further out than the camera\'s usual undercount on a stack this '
          'tall, so it is worth looking at the board.',
    );
  }

  @override
  String toString() => 'DriftReport(${findings.length} to resolve: $message)';
}
