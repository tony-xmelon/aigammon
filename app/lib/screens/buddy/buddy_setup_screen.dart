import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../analytics/analytics_events.dart';
import '../../analytics/analytics_screen_view.dart';
import '../../buddy/buddy_session.dart';
import '../../buddy/speaker.dart';
import '../../data/app_settings.dart';
import '../../data/settings_repository.dart';
import '../setup_options.dart';
import 'calibration_screen.dart';

/// Everything the user chose before the camera opened.
@immutable
class BuddySetup {
  const BuddySetup({
    required this.matchLength,
    required this.cubeless,
    required this.difficulty,
    required this.buddySide,
    required this.seat,
    required this.phrasing,
  });

  final int matchLength;
  final bool cubeless;
  final Difficulty difficulty;

  /// The side the engine plays. The user plays the other one — and physically
  /// moves both.
  final Player buddySide;

  /// Where the user sits. Confirmed again during calibration, against the
  /// picture; see [CalibrationOutcome.seat].
  ///
  /// No `orientation` getter beside it, for the reason
  /// [CalibrationRequest.seat] gives: the frame is `orientationFor(userSide,
  /// seat)` and it is only worth having once the seat has been confirmed, so it
  /// is computed where it is used rather than carried here.
  final BuddySeat seat;

  final BuddyPhrasing phrasing;

  Player get userSide => buddySide.opponent;

  BuddySetup copyWith({
    int? matchLength,
    bool? cubeless,
    Difficulty? difficulty,
    Player? buddySide,
    BuddySeat? seat,
    BuddyPhrasing? phrasing,
  }) =>
      BuddySetup(
        matchLength: matchLength ?? this.matchLength,
        cubeless: cubeless ?? this.cubeless,
        difficulty: difficulty ?? this.difficulty,
        buddySide: buddySide ?? this.buddySide,
        seat: seat ?? this.seat,
        phrasing: phrasing ?? this.phrasing,
      );
}

/// What happens once there is both a set of choices and a learned board.
///
/// Required rather than defaulted, because the destination is not this
/// screen's to decide: Task 13's game screen is what a match starts on, and
/// until it exists the caller says what to do instead.
typedef BuddyLaunch = void Function(
  BuildContext context,
  BuddySetup setup,
  CalibrationOutcome outcome,
);

/// The setup screen for a match against a real board.
///
/// Three of its five questions are the digital game's, asked with the digital
/// game's own controls (see `setup_options.dart`) — a user who has set up a
/// match against the computer has set this up too. The two that are new are the
/// two a camera creates: where the user is sitting, which is what turns a
/// picture into a numbered board and what tells the two opening dice apart, and
/// how Buddy words a play out loud.
///
/// It is also the front of the chain: Start pushes the guided calibration flow,
/// and [launch] is called once with both halves of what a session needs.
class BuddySetupScreen extends ConsumerStatefulWidget {
  const BuddySetupScreen({super.key, required this.launch});

  final BuddyLaunch launch;

  @override
  ConsumerState<BuddySetupScreen> createState() => _BuddySetupScreenState();
}

class _BuddySetupScreenState extends ConsumerState<BuddySetupScreen> {
  /// The three that have a persisted default start from it; edits here are
  /// per-match and are not written back, exactly as on `NewMatchScreen`.
  ///
  /// [_phrasing] joined them at schema v9. It was a hard-coded `terse` here
  /// while Settings had nothing to say about Buddy at all, and the two would
  /// otherwise be a preference that the screen it applies to ignores.
  late int _matchLength;
  late Difficulty _difficulty;
  late BuddyPhrasing _phrasing;

  bool _cubeless = false;
  Player _buddySide = Player.black;
  BuddySeat _seat = BuddySeat.near;

  @override
  void initState() {
    super.initState();
    final settings =
        ref.read(settingsProvider).valueOrNull ?? AppSettings.defaults;
    _matchLength = settings.defaultMatchLength;
    _difficulty = settings.defaultDifficulty;
    _phrasing = settings.buddyPhrasing;
  }

  BuddySetup get _setup => BuddySetup(
        matchLength: _matchLength,
        cubeless: _cubeless,
        difficulty: _difficulty,
        buddySide: _buddySide,
        seat: _seat,
        phrasing: _phrasing,
      );

  @override
  // See [HomeScreen] for why every screen splits build/_build.
  Widget build(BuildContext context) => AnalyticsScreenView(
        name: AnalyticsScreens.buddySetup,
        child: _build(context),
      );

  Widget _build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Play with Buddy')),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MatchLengthOptions(
                      value: _matchLength,
                      onChanged: (v) => setState(() => _matchLength = v),
                    ),
                    const SizedBox(height: 24),
                    DifficultyOptions(
                      value: _difficulty,
                      onChanged: (v) => setState(() => _difficulty = v),
                    ),
                    const SizedBox(height: 24),
                    SetupSection(
                      label: 'Buddy plays',
                      child: SegmentedButton<Player>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                              value: Player.white, label: Text('White')),
                          ButtonSegment(
                              value: Player.black, label: Text('Black')),
                        ],
                        selected: {_buddySide},
                        onSelectionChanged: (s) =>
                            setState(() => _buddySide = s.first),
                      ),
                    ),
                    const SizedBox(height: 24),
                    SetupSection(
                      label: 'Your seat',
                      child: SegmentedButton<BuddySeat>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                              value: BuddySeat.near,
                              label: Text('By the phone')),
                          ButtonSegment(
                              value: BuddySeat.far, label: Text('Opposite')),
                        ],
                        selected: {_seat},
                        onSelectionChanged: (s) =>
                            setState(() => _seat = s.first),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Which side of the board you are on. It is how Buddy '
                      'numbers the points, and how it tells your opening die '
                      'from its own.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 24),
                    SetupSection(
                      label: 'How Buddy talks',
                      child: SegmentedButton<BuddyPhrasing>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                              value: BuddyPhrasing.terse, label: Text('Terse')),
                          ButtonSegment(
                              value: BuddyPhrasing.friendly,
                              label: Text('Friendly')),
                        ],
                        selected: {_phrasing},
                        onSelectionChanged: (s) =>
                            setState(() => _phrasing = s.first),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _phrasing == BuddyPhrasing.terse
                          ? '"13/8, 24/22" — notation, the way two players at a '
                              'board actually talk.'
                          : '"Move one checker from 13 to 8, and one from 24 to '
                              '22."',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    CubelessSwitch(
                      value: _cubeless,
                      onChanged: (v) => setState(() => _cubeless = v),
                    ),
                    const SizedBox(height: 40),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _calibrate,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 18),
                        ),
                        child: const Text('Calibrate the board'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _calibrate() {
    final setup = _setup;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => CalibrationScreen(
          request: CalibrationRequest(
            userSide: setup.userSide,
            seat: setup.seat,
          ),
          onCalibrated: (outcome) {
            // The seat is asked here and CONFIRMED there, against a picture of
            // the board — so what comes back wins, and the setup that goes on
            // to build a session is the reconciled one rather than the guess.
            Navigator.of(routeContext).pop();
            widget.launch(
              context,
              setup.copyWith(seat: outcome.seat),
              outcome,
            );
          },
        ),
      ),
    );
  }
}
