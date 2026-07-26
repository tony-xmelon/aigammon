import 'dart:math';

import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../board/board_view.dart';
import '../data/app_settings.dart';
import '../data/match_repository.dart';
import '../data/persistence_hooks.dart';
import '../data/settings_repository.dart';
import '../engine/engine_provider.dart';
import '../game/game_controller.dart';
import '../game/player_agent.dart';
import '../tutor/tutor_service.dart';
import 'game_screen.dart';

/// The human's chosen side when playing vs the computer. [random] is resolved
/// to White or Black at match start.
enum _SideChoice { white, black, random }

/// Match-setup screen. Configures match length (and, vs computer, AI difficulty
/// and the human's side), then builds a [GameController] and pushes the
/// [GameScreen] as a route.
class NewMatchScreen extends ConsumerStatefulWidget {
  const NewMatchScreen({super.key, required this.vsComputer});

  /// True for a human-vs-AI match; false for a two-player hot-seat match.
  final bool vsComputer;

  @override
  ConsumerState<NewMatchScreen> createState() => _NewMatchScreenState();
}

class _NewMatchScreenState extends ConsumerState<NewMatchScreen> {
  /// Initial selector values come from the persisted [settingsProvider] (read
  /// once in [initState]); the user's edits here are per-match and do not write
  /// back to settings.
  late int _matchLength;
  late Difficulty _difficulty;
  _SideChoice _side = _SideChoice.white;

  /// Hot-seat only: rotate the board so the active player is at the bottom.
  bool _rotateForBlack = true;

  /// Per-match: play without the doubling cube. Offered for both local modes
  /// (vs-computer and hot-seat); online is server-mediated and does not expose
  /// it. Threaded into the [GameController] as `cubeless`.
  bool _cubeless = false;

  /// Whether live tutor mode is enabled. When the settings tutor override is
  /// unset it defaults per [_defaultTutor] and tracks difficulty changes until
  /// the user touches the toggle ([_tutorTouched]); when the override is set it
  /// starts forced on/off and no longer auto-tracks difficulty.
  late bool _tutorEnabled;
  bool _tutorTouched = false;

  /// The settings tutor override (null = use the per-mode default). Captured in
  /// [initState] so difficulty changes only re-derive the default when unset.
  bool? _settingsTutorOverride;

  @override
  void initState() {
    super.initState();
    final settings =
        ref.read(settingsProvider).valueOrNull ?? AppSettings.defaults;
    _matchLength = settings.defaultMatchLength;
    _difficulty = settings.defaultDifficulty;
    _settingsTutorOverride = settings.tutorOverride;
    _tutorEnabled = _settingsTutorOverride ?? _defaultTutor(_difficulty);
  }

  /// The default tutor state: ON for a vs-computer easy/medium match, OFF for
  /// hard/expert and for hot-seat.
  bool _defaultTutor(Difficulty d) =>
      widget.vsComputer && (d == Difficulty.easy || d == Difficulty.medium);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.vsComputer ? 'Play vs Computer' : 'Two Players'),
      ),
      body: SafeArea(
        // Top-aligned under the app bar: a setup form reads as a list of
        // decisions, so it starts where the eye already is. (Centring it left a
        // dead band the height of the app bar again on a phone.) The Center is
        // inside the scroll view, so it only centres HORIZONTALLY — the column
        // keeps its intrinsic height at the top of the viewport.
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
                    _Section(
                      label: 'Match length',
                      child: SegmentedButton<int>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: 1, label: Text('1')),
                          ButtonSegment(value: 3, label: Text('3')),
                          ButtonSegment(value: 5, label: Text('5')),
                          ButtonSegment(value: 7, label: Text('7')),
                        ],
                        selected: {_matchLength},
                        onSelectionChanged: (s) =>
                            setState(() => _matchLength = s.first),
                      ),
                    ),
                    if (widget.vsComputer) ...[
                      const SizedBox(height: 24),
                      _Section(
                        label: 'Difficulty',
                        child: SegmentedButton<Difficulty>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                                value: Difficulty.easy, label: Text('Easy')),
                            ButtonSegment(
                                value: Difficulty.medium, label: Text('Medium')),
                            ButtonSegment(
                                value: Difficulty.hard, label: Text('Hard')),
                            ButtonSegment(
                                value: Difficulty.expert, label: Text('Expert')),
                          ],
                          selected: {_difficulty},
                          onSelectionChanged: (s) => setState(() {
                            _difficulty = s.first;
                            // Live-update the default until the user overrides
                            // the toggle — but only when settings don't force a
                            // fixed tutor default.
                            if (!_tutorTouched &&
                                _settingsTutorOverride == null) {
                              _tutorEnabled = _defaultTutor(_difficulty);
                            }
                          }),
                        ),
                      ),
                      const SizedBox(height: 24),
                      _Section(
                        label: 'Your side',
                        child: SegmentedButton<_SideChoice>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                                value: _SideChoice.white, label: Text('White')),
                            ButtonSegment(
                                value: _SideChoice.black, label: Text('Black')),
                            ButtonSegment(
                                value: _SideChoice.random,
                                label: Text('Random')),
                          ],
                          selected: {_side},
                          onSelectionChanged: (s) =>
                              setState(() => _side = s.first),
                        ),
                      ),
                    ],
                    if (!widget.vsComputer) ...[
                      const SizedBox(height: 24),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Rotate board for Black'),
                        value: _rotateForBlack,
                        onChanged: (v) => setState(() => _rotateForBlack = v),
                      ),
                    ],
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Tutor mode'),
                      subtitle: const Text(
                          'Live hints, move marks, and cube advice'),
                      value: _tutorEnabled,
                      onChanged: (v) => setState(() {
                        _tutorEnabled = v;
                        _tutorTouched = true;
                      }),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Play without cube'),
                      subtitle: const Text('No doubling cube this match'),
                      value: _cubeless,
                      onChanged: (v) => setState(() => _cubeless = v),
                    ),
                    const SizedBox(height: 40),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _startMatch,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 18),
                        ),
                        child: const Text('Start match'),
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

  void _startMatch() {
    final (controller, orientation, matchIdFuture) = _buildController();
    // Build a tutor over the same engine facade when enabled; null = off.
    final tutor = _tutorEnabled
        ? TutorService(ref.read(engineFacadeProvider))
        : null;
    // Checker animation speed and the gameplay option toggles come from the
    // persisted settings.
    final settings =
        ref.read(settingsProvider).valueOrNull ?? AppSettings.defaults;
    Navigator.of(context).push(
      MaterialPageRoute(
        // Key by the controller so a fresh GameScreen State is mounted per
        // match (a new match never reuses stale State) — see GameScreen docs.
        builder: (_) => GameScreen(
          key: ValueKey(controller),
          controller: controller,
          orientation: orientation,
          tutor: tutor,
          // The header's detail row names the level you chose ("vs AI · Easy ·
          // Pips …"). Only meaningful against the computer.
          opponentDetail:
              widget.vsComputer ? _difficultyLabel(_difficulty) : null,
          persistedMatchId: matchIdFuture,
          timings: settings.timings,
          interactionOptions: BoardInteractionOptions(
            showHighlights: settings.showHighlights,
            enableDrag: settings.enableDrag,
            enableCombinedTaps: settings.enableCombinedTaps,
          ),
          showScoring: settings.showScoring,
          // Hot-seat hand-over cover; off by default (see the setting).
          showPassDevice: settings.showPassDevice,
          // One-time drag/tap hint: shown on the first human move when drag is on
          // and it has not been shown before. Persist the flag fire-and-forget.
          dragHintShown: settings.dragHintShown,
          onDragHintShown: () => ref
              .read(settingsRepositoryProvider)
              .save(settings.copyWith(dragHintShown: true)),
        ),
      ),
    );
  }

  /// Builds the controller, picks the board orientation, and returns the
  /// persisted match id future (threaded into [GameScreen.persistedMatchId] for
  /// the post-match "Match summary" link). Orientation: hot-seat follows the
  /// active player when "Rotate board for Black" is on (else White stays fixed at
  /// the bottom); vs-AI pins the human's side at the bottom.
  (GameController, BoardOrientationMode, Future<int>) _buildController() {
    if (!widget.vsComputer) {
      final (persistence, matchIdFuture) = _persistenceFor(
        mode: 'hotSeat',
        whiteType: 'human',
        blackType: 'human',
      );
      return (
        GameController(
          white: LocalHumanAgent(),
          black: LocalHumanAgent(),
          matchLength: _matchLength,
          cubeless: _cubeless,
          persistence: persistence,
        ),
        _rotateForBlack
            ? BoardOrientationMode.followActive
            : BoardOrientationMode.fixedWhite,
        matchIdFuture,
      );
    }

    final facade = ref.read(engineFacadeProvider);
    final human = LocalHumanAgent();
    final ai = AiAgent(facade, _difficulty);
    final humanIsWhite = switch (_side) {
      _SideChoice.white => true,
      _SideChoice.black => false,
      _SideChoice.random => Random().nextBool(),
    };
    final aiType = 'ai:${_difficulty.name}';
    final (persistence, matchIdFuture) = _persistenceFor(
      mode: 'vsComputer',
      whiteType: humanIsWhite ? 'human' : aiType,
      blackType: humanIsWhite ? aiType : 'human',
    );
    return (
      GameController(
        white: humanIsWhite ? human : ai,
        black: humanIsWhite ? ai : human,
        matchLength: _matchLength,
        cubeless: _cubeless,
        persistence: persistence,
      ),
      humanIsWhite
          ? BoardOrientationMode.fixedWhite
          : BoardOrientationMode.fixedBlack,
      matchIdFuture,
    );
  }

  /// Creates the match row (fire-and-forget insert) and wraps the repository in
  /// a [RepositoryPersistence] bound to that row's id. The insert runs in the
  /// background; the controller's hooks await the id before recording games, and
  /// the returned future also feeds [GameScreen.persistedMatchId].
  (MatchPersistence, Future<int>) _persistenceFor({
    required String mode,
    required String whiteType,
    required String blackType,
  }) {
    final repo = ref.read(matchRepositoryProvider);
    final matchIdFuture = repo.startMatch(
      matchLength: _matchLength,
      mode: mode,
      whiteType: whiteType,
      blackType: blackType,
    );
    return (RepositoryPersistence(repo, matchIdFuture), matchIdFuture);
  }
}

/// The display name of a difficulty, matching this screen's own segment labels
/// so the header's "vs AI · Easy" reads back exactly what was picked here.
String _difficultyLabel(Difficulty d) => switch (d) {
      Difficulty.easy => 'Easy',
      Difficulty.medium => 'Medium',
      Difficulty.hard => 'Hard',
      Difficulty.expert => 'Expert',
    };

/// A labelled setup row: a caption above its control.
class _Section extends StatelessWidget {
  const _Section({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        child,
      ],
    );
  }
}
