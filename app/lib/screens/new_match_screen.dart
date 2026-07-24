import 'dart:math';

import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/engine_provider.dart';
import '../game/game_controller.dart';
import '../game/player_agent.dart';
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
  int _matchLength = 5;
  Difficulty _difficulty = Difficulty.medium;
  _SideChoice _side = _SideChoice.white;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.vsComputer ? 'Play vs Computer' : 'Two Players'),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Section(
                      label: 'Match length',
                      child: SegmentedButton<int>(
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
                          onSelectionChanged: (s) =>
                              setState(() => _difficulty = s.first),
                        ),
                      ),
                      const SizedBox(height: 24),
                      _Section(
                        label: 'Your side',
                        child: SegmentedButton<_SideChoice>(
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
    final controller = _buildController();
    Navigator.of(context).push(
      MaterialPageRoute(
        // Key by the controller so a fresh GameScreen State is mounted per
        // match (a new match never reuses stale State) — see GameScreen docs.
        builder: (_) =>
            GameScreen(key: ValueKey(controller), controller: controller),
      ),
    );
  }

  GameController _buildController() {
    if (!widget.vsComputer) {
      return GameController(
        white: LocalHumanAgent(),
        black: LocalHumanAgent(),
        matchLength: _matchLength,
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
    return GameController(
      white: humanIsWhite ? human : ai,
      black: humanIsWhite ? ai : human,
      matchLength: _matchLength,
    );
  }
}

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
