/// The controls a match-setup screen is built out of.
///
/// Lifted out of `NewMatchScreen` when Buddy Mode's setup screen arrived, which
/// asks three of the same questions — how long the match is, how hard the
/// engine plays, whether the cube is in — and then two of its own. Two screens
/// that ask the same question have to ask it the same way: the same segment
/// labels, the same lengths on offer, the same wording under the cube switch.
/// A user who has met one of these screens has met the other.
library;

import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/material.dart';

/// A labelled setup row: a caption above its control.
class SetupSection extends StatelessWidget {
  const SetupSection({super.key, required this.label, required this.child});

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

/// 1, 3, 5 or 7 points.
class MatchLengthOptions extends StatelessWidget {
  const MatchLengthOptions({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => SetupSection(
        label: 'Match length',
        child: SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 1, label: Text('1')),
            ButtonSegment(value: 3, label: Text('3')),
            ButtonSegment(value: 5, label: Text('5')),
            ButtonSegment(value: 7, label: Text('7')),
          ],
          selected: {value},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      );
}

/// How hard the engine plays.
class DifficultyOptions extends StatelessWidget {
  const DifficultyOptions({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final Difficulty value;
  final ValueChanged<Difficulty> onChanged;

  @override
  Widget build(BuildContext context) => SetupSection(
        label: 'Difficulty',
        child: SegmentedButton<Difficulty>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: Difficulty.easy, label: Text('Easy')),
            ButtonSegment(value: Difficulty.medium, label: Text('Medium')),
            ButtonSegment(value: Difficulty.hard, label: Text('Hard')),
            ButtonSegment(value: Difficulty.expert, label: Text('Expert')),
          ],
          selected: {value},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      );
}

/// Per-match: play without the doubling cube.
class CubelessSwitch extends StatelessWidget {
  const CubelessSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Play without cube'),
        subtitle: const Text('No doubling cube this match'),
        value: value,
        onChanged: onChanged,
      );
}

/// The display name of a difficulty, matching [DifficultyOptions]'s own segment
/// labels so a header's "vs AI · Easy" reads back exactly what was picked.
String difficultyLabel(Difficulty d) => switch (d) {
      Difficulty.easy => 'Easy',
      Difficulty.medium => 'Medium',
      Difficulty.hard => 'Hard',
      Difficulty.expert => 'Expert',
    };
