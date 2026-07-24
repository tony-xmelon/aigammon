# backgammon_core (Rules Engine) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `packages/backgammon_core` — a pure Dart, zero-dependency backgammon rules engine: board model, complete legal-move generation, doubling cube, match play with Crawford rule, event-sourced games, and JSON serialization.

**Architecture:** Immutable value types (`BoardState`, `GameState`, `MatchState`) with a recursive move-sequence search for legal-move generation. The generator works in a "normalized" space (the moving player is always positive and moves toward index 0) via board mirroring, halving the rule logic. Games are append-only `GameEvent` logs; `Game.replay` folds events into state. This package is the source of truth for all four play modes (spec §2).

**Tech Stack:** Dart ≥3.4 (sealed classes, records), `package:test`. No other dependencies.

**Prerequisites:** Dart SDK installed (`dart --version` shows ≥3.4). All commands run from `packages/backgammon_core/` unless noted. This is plan 1 of 5 (see spec `docs/superpowers/specs/2026-07-24-aigammon-architecture-design.md`); engine FFI, Flutter UI, tutor, and Firebase are separate plans.

**Conventions used throughout:**
- `points` is a 24-length list from White's perspective; `points[i]` is the point numbered `i+1` for White. Positive = White checkers, negative = Black.
- White moves toward index 0 and bears off from indices 0–5; Black moves toward index 23 and bears off from indices 18–23.
- `CheckerMove.bar == 24` and `CheckerMove.off == -1` are sentinel positions.

---

### Task 1: Package scaffold

**Files:**
- Create: `packages/backgammon_core/pubspec.yaml`
- Create: `packages/backgammon_core/analysis_options.yaml`
- Create: `packages/backgammon_core/lib/backgammon_core.dart`
- Create: `packages/backgammon_core/test/smoke_test.dart`

- [ ] **Step 1: Create package files**

`pubspec.yaml`:
```yaml
name: backgammon_core
description: Pure Dart backgammon rules engine for AIGammon.
version: 0.1.0
publish_to: none

environment:
  sdk: ^3.4.0

dev_dependencies:
  lints: ^4.0.0
  test: ^1.25.0
```

`analysis_options.yaml`:
```yaml
include: package:lints/recommended.yaml
```

`lib/backgammon_core.dart`:
```dart
/// Pure Dart backgammon rules engine.
library;
```

`test/smoke_test.dart`:
```dart
import 'package:test/test.dart';

void main() {
  test('package resolves', () {
    expect(1 + 1, 2);
  });
}
```

- [ ] **Step 2: Fetch dependencies and run the smoke test**

Run: `dart pub get` then `dart test`
Expected: `All tests passed!`

- [ ] **Step 3: Commit**

```bash
git add packages/backgammon_core
git commit -m "feat(core): scaffold backgammon_core package"
```

---

### Task 2: Player and Dice

**Files:**
- Create: `packages/backgammon_core/lib/src/player.dart`
- Create: `packages/backgammon_core/lib/src/dice.dart`
- Modify: `packages/backgammon_core/lib/backgammon_core.dart`
- Test: `packages/backgammon_core/test/player_dice_test.dart`

- [ ] **Step 1: Write the failing test**

`test/player_dice_test.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  test('opponent flips', () {
    expect(Player.white.opponent, Player.black);
    expect(Player.black.opponent, Player.white);
  });

  test('dice validate range and detect doubles', () {
    expect(Dice(3, 3).isDouble, isTrue);
    expect(Dice(3, 1).isDouble, isFalse);
    expect(Dice(6, 5).high, 6);
    expect(Dice(5, 6).high, 6);
    expect(() => Dice(0, 3), throwsArgumentError);
    expect(() => Dice(3, 7), throwsArgumentError);
  });

  test('dice equality', () {
    expect(Dice(3, 1), Dice(3, 1));
    expect(Dice(3, 1), isNot(Dice(1, 3)));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/player_dice_test.dart`
Expected: FAIL — `Player`/`Dice` undefined.

- [ ] **Step 3: Implement**

`lib/src/player.dart`:
```dart
enum Player {
  white,
  black;

  Player get opponent => this == white ? black : white;
}
```

`lib/src/dice.dart`:
```dart
class Dice {
  final int die1;
  final int die2;

  Dice(this.die1, this.die2) {
    if (die1 < 1 || die1 > 6 || die2 < 1 || die2 > 6) {
      throw ArgumentError('dice must be 1-6, got $die1/$die2');
    }
  }

  bool get isDouble => die1 == die2;
  int get high => die1 > die2 ? die1 : die2;
  int get low => die1 < die2 ? die1 : die2;

  @override
  bool operator ==(Object other) =>
      other is Dice && other.die1 == die1 && other.die2 == die2;

  @override
  int get hashCode => Object.hash(die1, die2);

  @override
  String toString() => '$die1$die2';
}
```

Append to `lib/backgammon_core.dart`:
```dart
export 'src/dice.dart';
export 'src/player.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/player_dice_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/backgammon_core
git commit -m "feat(core): add Player and Dice types"
```

---

### Task 3: BoardState

**Files:**
- Create: `packages/backgammon_core/lib/src/board_state.dart`
- Modify: `packages/backgammon_core/lib/backgammon_core.dart`
- Test: `packages/backgammon_core/test/board_state_test.dart`

- [ ] **Step 1: Write the failing test**

`test/board_state_test.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  test('initial position is the standard backgammon setup', () {
    final b = BoardState.initial();
    expect(b.points[23], 2); // White's 24-point
    expect(b.points[12], 5); // White's 13-point
    expect(b.points[7], 3); //  White's 8-point
    expect(b.points[5], 5); //  White's 6-point
    expect(b.points[0], -2); // Black's 24-point
    expect(b.points[11], -5);
    expect(b.points[16], -3);
    expect(b.points[18], -5);
    expect(b.whiteBar, 0);
    expect(b.blackOff, 0);
    expect(b.checkerCount(Player.white), 15);
    expect(b.checkerCount(Player.black), 15);
  });

  test('initial pip count is 167 for both players', () {
    final b = BoardState.initial();
    expect(b.pipCount(Player.white), 167);
    expect(b.pipCount(Player.black), 167);
  });

  test('bar checkers count 25 pips', () {
    final b = BoardState(
      points: List.filled(24, 0),
      whiteBar: 2,
    );
    expect(b.pipCount(Player.white), 50);
  });

  test('mirrored swaps colors and direction, twice is identity', () {
    final b = BoardState.initial();
    final m = b.mirrored();
    expect(m.points[23], 2); // Black's back checkers become White's
    expect(m.points[0], -2);
    expect(m.mirrored(), b);
  });

  test('value equality', () {
    expect(BoardState.initial(), BoardState.initial());
    expect(BoardState.initial(),
        isNot(BoardState(points: List.filled(24, 0))));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/board_state_test.dart`
Expected: FAIL — `BoardState` undefined.

- [ ] **Step 3: Implement**

`lib/src/board_state.dart`:
```dart
import 'package:collection/collection.dart' show ListEquality;

import 'player.dart';

/// Immutable board from White's perspective. `points[i]` is the point
/// numbered `i+1` for White; positive counts are White checkers, negative
/// are Black. White moves toward index 0, Black toward index 23.
class BoardState {
  final List<int> points;
  final int whiteBar;
  final int blackBar;
  final int whiteOff;
  final int blackOff;

  static const _eq = ListEquality<int>();

  BoardState({
    required List<int> points,
    this.whiteBar = 0,
    this.blackBar = 0,
    this.whiteOff = 0,
    this.blackOff = 0,
  }) : points = List.unmodifiable(points) {
    if (points.length != 24) {
      throw ArgumentError('points must have 24 entries');
    }
  }

  factory BoardState.initial() => BoardState(points: const [
        -2, 0, 0, 0, 0, 5, //  1-6  (White's home board)
        0, 3, 0, 0, 0, -5, //  7-12
        5, 0, 0, 0, -3, 0, // 13-18
        -5, 0, 0, 0, 0, 2, // 19-24
      ]);

  int barFor(Player p) => p == Player.white ? whiteBar : blackBar;
  int offFor(Player p) => p == Player.white ? whiteOff : blackOff;

  int checkerCount(Player p) {
    var n = barFor(p) + offFor(p);
    for (final c in points) {
      if (p == Player.white && c > 0) n += c;
      if (p == Player.black && c < 0) n += -c;
    }
    return n;
  }

  int pipCount(Player p) {
    var pips = barFor(p) * 25;
    for (var i = 0; i < 24; i++) {
      final c = points[i];
      if (p == Player.white && c > 0) pips += c * (i + 1);
      if (p == Player.black && c < 0) pips += -c * (24 - i);
    }
    return pips;
  }

  /// The board with colors and direction swapped, so perspective-free code
  /// can always treat the moving player as White.
  BoardState mirrored() => BoardState(
        points: [for (var i = 23; i >= 0; i--) -points[i]],
        whiteBar: blackBar,
        blackBar: whiteBar,
        whiteOff: blackOff,
        blackOff: whiteOff,
      );

  @override
  bool operator ==(Object other) =>
      other is BoardState &&
      _eq.equals(other.points, points) &&
      other.whiteBar == whiteBar &&
      other.blackBar == blackBar &&
      other.whiteOff == whiteOff &&
      other.blackOff == blackOff;

  @override
  int get hashCode =>
      Object.hash(_eq.hash(points), whiteBar, blackBar, whiteOff, blackOff);

  @override
  String toString() =>
      'BoardState(${points.join(",")} wBar:$whiteBar bBar:$blackBar '
      'wOff:$whiteOff bOff:$blackOff)';
}
```

Add `collection: ^1.18.0` under a new `dependencies:` section in `pubspec.yaml` (it ships with the SDK toolchain; still declare it), then run `dart pub get`.

Append to `lib/backgammon_core.dart`:
```dart
export 'src/board_state.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/board_state_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/backgammon_core
git commit -m "feat(core): add immutable BoardState with pip counts and mirroring"
```

---

### Task 4: CheckerMove and Move

**Files:**
- Create: `packages/backgammon_core/lib/src/move.dart`
- Modify: `packages/backgammon_core/lib/backgammon_core.dart`
- Test: `packages/backgammon_core/test/move_test.dart`

- [ ] **Step 1: Write the failing test**

`test/move_test.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  test('checker move equality includes hit flag', () {
    expect(const CheckerMove(7, 4), const CheckerMove(7, 4));
    expect(const CheckerMove(7, 4),
        isNot(const CheckerMove(7, 4, isHit: true)));
  });

  test('sameAs ignores hop order', () {
    final a = Move(const [CheckerMove(7, 4), CheckerMove(5, 4)]);
    final b = Move(const [CheckerMove(5, 4), CheckerMove(7, 4)]);
    expect(a.sameAs(b), isTrue);
    expect(a.sameAs(Move(const [CheckerMove(7, 4)])), isFalse);
  });

  test('empty move is the dance', () {
    expect(Move.none.checkerMoves, isEmpty);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/move_test.dart`
Expected: FAIL — `CheckerMove`/`Move` undefined.

- [ ] **Step 3: Implement**

`lib/src/move.dart`:
```dart
/// One checker moved by one die. Indices are from White's perspective
/// (0-23) regardless of who moves; [bar] and [off] are sentinels.
class CheckerMove {
  static const int bar = 24;
  static const int off = -1;

  final int from;
  final int to;
  final bool isHit;

  const CheckerMove(this.from, this.to, {this.isHit = false});

  @override
  bool operator ==(Object other) =>
      other is CheckerMove &&
      other.from == from &&
      other.to == to &&
      other.isHit == isHit;

  @override
  int get hashCode => Object.hash(from, to, isHit);

  @override
  String toString() {
    final f = from == bar ? 'bar' : '${from + 1}';
    final t = to == off ? 'off' : '${to + 1}';
    return '$f/$t${isHit ? '*' : ''}';
  }
}

/// A full turn: every checker moved for one dice roll, in a playable order.
/// An empty move is a dance (no legal play).
class Move {
  final List<CheckerMove> checkerMoves;

  Move(List<CheckerMove> checkerMoves)
      : checkerMoves = List.unmodifiable(checkerMoves);

  static final Move none = Move(const []);

  /// True when both moves consist of the same hops, in any order.
  /// Hit flags are ignored: the same hop multiset always produces the same
  /// resulting position, so this is the right identity for validation.
  bool sameAs(Move other) {
    if (other.checkerMoves.length != checkerMoves.length) return false;
    List<String> key(Move m) =>
        [for (final c in m.checkerMoves) '${c.from}>${c.to}']..sort();
    final a = key(this);
    final b = key(other);
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() =>
      checkerMoves.isEmpty ? '(no play)' : checkerMoves.join(' ');
}
```

Append to `lib/backgammon_core.dart`:
```dart
export 'src/move.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/move_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/backgammon_core
git commit -m "feat(core): add CheckerMove and Move with order-insensitive identity"
```

---

### Task 5: BoardState.applyMove

**Files:**
- Modify: `packages/backgammon_core/lib/src/board_state.dart`
- Test: `packages/backgammon_core/test/apply_move_test.dart`

- [ ] **Step 1: Write the failing test**

`test/apply_move_test.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  test('white plays 24/23 13/11 from the start', () {
    final b = BoardState.initial().applyMove(
        Player.white, Move(const [CheckerMove(23, 22), CheckerMove(12, 10)]));
    expect(b.points[23], 1);
    expect(b.points[22], 1);
    expect(b.points[12], 4);
    expect(b.points[10], 1);
    expect(b.checkerCount(Player.white), 15);
  });

  test('landing on a lone opponent checker hits it to the bar', () {
    final b = BoardState(points: [
      0, 0, 0, -1, 0, 2, //
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]).applyMove(Player.white, Move(const [CheckerMove(5, 3, isHit: true)]));
    expect(b.points[3], 1);
    expect(b.blackBar, 1);
  });

  test('hit is applied even when the flag is stale', () {
    // applyMove computes hits from the board, not from isHit.
    final b = BoardState(points: [
      0, 0, 0, -1, 0, 2, //
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]).applyMove(Player.white, Move(const [CheckerMove(5, 3)]));
    expect(b.points[3], 1);
    expect(b.blackBar, 1);
  });

  test('entering from the bar and bearing off', () {
    var b = BoardState(
      points: [
        1, 0, 0, 0, 0, 0, //
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      ],
      whiteBar: 1,
    );
    b = b.applyMove(Player.white, Move(const [CheckerMove(CheckerMove.bar, 21)]));
    expect(b.whiteBar, 0);
    expect(b.points[21], 1);
    b = b.applyMove(Player.white, Move(const [CheckerMove(0, CheckerMove.off)]));
    expect(b.whiteOff, 1);
    expect(b.points[0], 0);
  });

  test('black moves increase indices and hit white blots', () {
    final b = BoardState(points: [
      -2, 0, 0, 1, 0, 0, //
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]).applyMove(Player.black, Move(const [CheckerMove(0, 3)]));
    expect(b.points[0], -1);
    expect(b.points[3], -1);
    expect(b.whiteBar, 1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/apply_move_test.dart`
Expected: FAIL — `applyMove` undefined.

- [ ] **Step 3: Implement**

Add to `lib/src/board_state.dart` (inside `BoardState`, plus the import of `move.dart` at the top of the file):
```dart
  /// Applies an assumed-legal [move] for [player]. Hits are recomputed from
  /// the board so application is safe regardless of the isHit flags.
  /// Legality checking lives in MoveGenerator/GameState, not here.
  BoardState applyMove(Player player, Move move) {
    final pts = List.of(points);
    var wBar = whiteBar, bBar = blackBar, wOff = whiteOff, bOff = blackOff;
    final sign = player == Player.white ? 1 : -1;
    for (final cm in move.checkerMoves) {
      if (cm.from == CheckerMove.bar) {
        if (player == Player.white) {
          wBar--;
        } else {
          bBar--;
        }
      } else {
        pts[cm.from] -= sign;
      }
      if (cm.to == CheckerMove.off) {
        if (player == Player.white) {
          wOff++;
        } else {
          bOff++;
        }
      } else {
        if (pts[cm.to] == -sign) {
          pts[cm.to] = 0;
          if (player == Player.white) {
            bBar++;
          } else {
            wBar++;
          }
        }
        pts[cm.to] += sign;
      }
    }
    return BoardState(
      points: pts,
      whiteBar: wBar,
      blackBar: bBar,
      whiteOff: wOff,
      blackOff: bOff,
    );
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/apply_move_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/backgammon_core
git commit -m "feat(core): apply moves to BoardState with recomputed hits"
```

---

### Task 6: MoveGenerator — regular moves, hitting, blocking, maximal dice use

**Files:**
- Create: `packages/backgammon_core/lib/src/move_generator.dart`
- Modify: `packages/backgammon_core/lib/backgammon_core.dart`
- Test: `packages/backgammon_core/test/move_generator_test.dart`

The generator searches all dice orders recursively, keeps only maximal-length
sequences (the "must play as many dice as possible" rule falls out of this),
and dedupes by resulting position. Bar entry and bear-off are stubbed to
"illegal" here and implemented in Tasks 7–8.

- [ ] **Step 1: Write the failing test**

`test/move_generator_test.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

Matcher containsMove(Move expected) => predicate<List<Move>>(
    (moves) => moves.any((m) => m.sameAs(expected)),
    'contains ${expected.toString()}');

void main() {
  test('opening 3-1 includes the golden point play 8/5 6/5', () {
    final moves =
        MoveGenerator.legalMoves(BoardState.initial(), Player.white, Dice(3, 1));
    expect(moves, containsMove(Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])));
    // 24/23 with the 1 then 23/20 with the 3 is also legal
    expect(moves, containsMove(Move(const [CheckerMove(23, 22), CheckerMove(22, 19)])));
  });

  test('blocked points are not landable', () {
    // Black owns index 18; White's checkers on index 23 want 23->18 with a
    // 5 but may not land there. White's checkers on index 9 can still play.
    final board = BoardState(points: [
      0, 0, 0, 0, 0, 0, //
      0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, -2, 0, 0, 0, 0, 2,
    ]);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(5, 5));
    expect(moves, isNotEmpty); // 10/5 plays are available
    for (final m in moves) {
      for (final cm in m.checkerMoves) {
        expect(cm.to, isNot(18));
      }
    }
  });

  test('landing on a blot is marked as a hit', () {
    final board = BoardState(points: [
      0, 0, -1, 0, 0, 1, //
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -2,
    ]);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(3, 2));
    final hit = moves.firstWhere(
        (m) => m.checkerMoves.any((c) => c.to == 2 && c.isHit));
    expect(hit, isNotNull);
  });

  test('must play both dice when possible: lone playable one-die move is excluded', () {
    // White has one checker on 24 (index 23); Black blocks 21 (die 3 direct)
    // but 19 (via 5 then 3, or 3 then 5) is open only through 21 or 19...
    // Simpler canonical case: if some sequence plays both dice, one-die
    // sequences must not be offered.
    final moves =
        MoveGenerator.legalMoves(BoardState.initial(), Player.white, Dice(6, 5));
    expect(moves.every((m) => m.checkerMoves.length == 2), isTrue);
  });

  test('doubles play up to four checkers', () {
    final moves =
        MoveGenerator.legalMoves(BoardState.initial(), Player.white, Dice(1, 1));
    expect(moves.every((m) => m.checkerMoves.length == 4), isTrue);
  });

  test('black moves are returned in real board coordinates', () {
    final moves =
        MoveGenerator.legalMoves(BoardState.initial(), Player.black, Dice(3, 1));
    // Black's golden point: black 8/5 6/5 = indices 16->19, 18->19
    expect(moves, containsMove(Move(const [CheckerMove(16, 19), CheckerMove(18, 19)])));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/move_generator_test.dart`
Expected: FAIL — `MoveGenerator` undefined.

- [ ] **Step 3: Implement**

`lib/src/move_generator.dart`:
```dart
import 'board_state.dart';
import 'dice.dart';
import 'move.dart';
import 'player.dart';

/// Mutable position used only inside the search. Always normalized: the
/// moving player is positive and moves toward index 0.
class _Pos {
  final List<int> points;
  int bar; // moving player's checkers on the bar
  int oppBar;
  int off;

  _Pos(this.points, this.bar, this.oppBar, this.off);

  factory _Pos.of(BoardState b) =>
      _Pos(List.of(b.points), b.whiteBar, b.blackBar, b.whiteOff);

  _Pos clone() => _Pos(List.of(points), bar, oppBar, off);

  String signature() => '${points.join(",")}|$bar|$oppBar|$off';

  /// Attempts to move one checker with [die] from [from] (0-23 or
  /// [CheckerMove.bar]), mutating this position. Returns null if illegal.
  CheckerMove? tryMove(int from, int die) {
    if (bar > 0 && from != CheckerMove.bar) return null;
    if (from == CheckerMove.bar) {
      return null; // bar entry: Task 7
    }
    if (points[from] <= 0) return null;
    final to = from - die;
    if (to < 0) {
      return null; // bear-off: Task 8
    }
    if (points[to] < -1) return null;
    final hit = points[to] == -1;
    if (hit) {
      points[to] = 0;
      oppBar++;
    }
    points[to]++;
    points[from]--;
    return CheckerMove(from, to, isHit: hit);
  }
}

class MoveGenerator {
  /// All distinct legal full-turn moves for [player] with [dice], in real
  /// (White-perspective) coordinates. Implements: play the maximum number
  /// of dice possible; doubles allow four moves. Returns an empty list on a
  /// dance. The higher-die tiebreak is added in Task 9.
  static List<Move> legalMoves(BoardState board, Player player, Dice dice) {
    final normalized = player == Player.white ? board : board.mirrored();
    final orders = dice.isDouble
        ? [List<int>.filled(4, dice.die1)]
        : [
            [dice.die1, dice.die2],
            [dice.die2, dice.die1],
          ];

    var maxLen = 0;
    final byResult = <String, Move>{};

    void search(_Pos pos, List<int> order, int i, List<CheckerMove> seq) {
      var moved = false;
      if (i < order.length) {
        for (var from = CheckerMove.bar; from >= 0; from--) {
          final branch = pos.clone();
          final cm = branch.tryMove(from, order[i]);
          if (cm != null) {
            moved = true;
            search(branch, order, i + 1, [...seq, cm]);
          }
        }
      }
      if (!moved) {
        // Dead end (die unplayable or dice exhausted): candidate turn.
        if (seq.length > maxLen) {
          maxLen = seq.length;
          byResult.clear();
        }
        if (seq.isNotEmpty && seq.length == maxLen) {
          byResult.putIfAbsent(pos.signature(), () => Move(List.of(seq)));
        }
      }
    }

    for (final order in orders) {
      search(_Pos.of(normalized), order, 0, const []);
    }

    return _denormalize(byResult.values.toList(), player);
  }

  static List<Move> _denormalize(List<Move> moves, Player player) {
    if (player == Player.white) return moves;
    Move flip(Move m) => Move([
          for (final cm in m.checkerMoves)
            CheckerMove(
              cm.from == CheckerMove.bar ? CheckerMove.bar : 23 - cm.from,
              cm.to == CheckerMove.off ? CheckerMove.off : 23 - cm.to,
              isHit: cm.isHit,
            ),
        ]);
    return [for (final m in moves) flip(m)];
  }
}
```

Append to `lib/backgammon_core.dart`:
```dart
export 'src/move_generator.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/move_generator_test.dart`
Expected: PASS

- [ ] **Step 5: Run the whole suite and commit**

Run: `dart test`
Expected: all pass.

```bash
git add packages/backgammon_core
git commit -m "feat(core): move generation with maximal-dice search and dedup"
```

---

### Task 7: Bar entry

**Files:**
- Modify: `packages/backgammon_core/lib/src/move_generator.dart`
- Test: `packages/backgammon_core/test/bar_entry_test.dart`

- [ ] **Step 1: Write the failing test**

`test/bar_entry_test.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  BoardState barBoard({List<int>? blackHome}) {
    // White has 1 checker on the bar and 1 on the 13-point (index 12).
    // blackHome fills indices 18-23 (Black's blocking of White's entry).
    final pts = List<int>.filled(24, 0);
    pts[12] = 1;
    final home = blackHome ?? [0, 0, 0, 0, 0, 0];
    for (var i = 0; i < 6; i++) {
      pts[18 + i] = home[i];
    }
    return BoardState(points: pts, whiteBar: 1);
  }

  test('must enter from the bar before any other move', () {
    final moves =
        MoveGenerator.legalMoves(barBoard(), Player.white, Dice(6, 2));
    expect(moves, isNotEmpty);
    for (final m in moves) {
      expect(m.checkerMoves.first.from, CheckerMove.bar);
    }
  });

  test('entry point is 25 minus the die', () {
    final moves =
        MoveGenerator.legalMoves(barBoard(), Player.white, Dice(3, 3));
    // die 3 enters on White's 22-point (index 21)
    expect(moves.first.checkerMoves.first.to, 21);
  });

  test('fully blocked entry is a dance', () {
    final board = barBoard(blackHome: [-2, -2, -2, -2, -2, -2]);
    expect(MoveGenerator.legalMoves(board, Player.white, Dice(6, 2)), isEmpty);
  });

  test('entry can hit a blot', () {
    final board = barBoard(blackHome: [0, 0, 0, 0, 0, -1]);
    // die 1 enters on index 23 where a lone black checker sits
    final moves =
        MoveGenerator.legalMoves(board, Player.white, Dice(1, 5));
    final entries = [
      for (final m in moves) m.checkerMoves.first,
    ].where((c) => c.to == 23);
    expect(entries.every((c) => c.isHit), isTrue);
    expect(entries, isNotEmpty);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/bar_entry_test.dart`
Expected: FAIL — bar moves currently return null, so `moves` is empty where entries are expected.

- [ ] **Step 3: Implement**

In `_Pos.tryMove`, replace the `return null; // bar entry: Task 7` branch:
```dart
    if (from == CheckerMove.bar) {
      if (bar == 0) return null;
      final to = 24 - die;
      if (points[to] < -1) return null;
      final hit = points[to] == -1;
      if (hit) {
        points[to] = 0;
        oppBar++;
      }
      points[to]++;
      bar--;
      return CheckerMove(CheckerMove.bar, to, isHit: hit);
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/bar_entry_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/backgammon_core
git commit -m "feat(core): bar entry with hits and dance detection"
```

---

### Task 8: Bear-off

**Files:**
- Modify: `packages/backgammon_core/lib/src/move_generator.dart`
- Test: `packages/backgammon_core/test/bear_off_test.dart`

- [ ] **Step 1: Write the failing test**

`test/bear_off_test.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  BoardState home(List<int> whiteHome, {int whiteOff = 0, int outside = 0}) {
    // whiteHome fills indices 0-5; outside optionally puts a checker on 12.
    final pts = List<int>.filled(24, 0);
    for (var i = 0; i < 6; i++) {
      pts[i] = whiteHome[i];
    }
    if (outside > 0) pts[12] = outside;
    return BoardState(points: pts, whiteOff: whiteOff);
  }

  test('exact die bears off', () {
    final board = home([0, 0, 0, 0, 0, 2], whiteOff: 13);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(6, 6));
    // Both checkers on the 6-point bear off with sixes.
    expect(
        moves.any((m) =>
            m.checkerMoves.where((c) => c.to == CheckerMove.off).length == 2),
        isTrue);
  });

  test('cannot bear off while a checker is outside the home board', () {
    final board = home([0, 0, 0, 0, 0, 2], whiteOff: 12, outside: 1);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(6, 5));
    for (final m in moves) {
      // The outside checker travels (13/7 with the 6, 13/8 with the 5,
      // etc.); no hop may bear off while index 12 is occupied.
      for (final cm in m.checkerMoves) {
        expect(cm.to, isNot(CheckerMove.off));
      }
    }
  });

  test('overshoot only from the highest occupied point', () {
    final board = home([0, 1, 0, 1, 0, 0], whiteOff: 13);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(6, 6));
    // Die 6 > both points; only the highest (index 3, the 4-point) may
    // bear off first, then index 1.
    final first = moves.first.checkerMoves.first;
    expect(first.from, 3);
    expect(first.to, CheckerMove.off);
  });

  test('smaller die may still move inside the home board', () {
    final board = home([0, 0, 0, 0, 0, 2], whiteOff: 13);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(2, 1));
    // 6/4 6/5 is legal; no bear-off is possible with 2-1 from the 6-point
    // since 6 > die and lower points are empty... actually the checkers sit
    // on the 6-point so dice 2,1 move within the board only.
    expect(
        moves.every(
            (m) => m.checkerMoves.every((c) => c.to != CheckerMove.off)),
        isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/bear_off_test.dart`
Expected: FAIL — bear-off currently returns null (first test finds no `off` moves).

- [ ] **Step 3: Implement**

Add helpers to `_Pos` and replace the `return null; // bear-off: Task 8` branch in `tryMove`:
```dart
  bool get allHome {
    if (bar > 0) return false;
    for (var i = 6; i < 24; i++) {
      if (points[i] > 0) return false;
    }
    return true;
  }

  int get highestPoint {
    for (var i = 23; i >= 0; i--) {
      if (points[i] > 0) return i;
    }
    return -1;
  }
```

In `tryMove`:
```dart
    if (to < 0) {
      if (!allHome) return null;
      final exact = die == from + 1;
      final overshoot = die > from + 1 && from == highestPoint;
      if (!exact && !overshoot) return null;
      points[from]--;
      off++;
      return CheckerMove(from, CheckerMove.off);
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/bear_off_test.dart` then `dart test`
Expected: PASS (full suite green)

- [ ] **Step 5: Commit**

```bash
git add packages/backgammon_core
git commit -m "feat(core): bear-off with exact and overshoot rules"
```

---

### Task 9: Higher-die rule

**Files:**
- Modify: `packages/backgammon_core/lib/src/move_generator.dart`
- Test: `packages/backgammon_core/test/higher_die_test.dart`

- [ ] **Step 1: Write the failing test**

`test/higher_die_test.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  test('when only one die can be played, the higher must be chosen', () {
    // Setup: White has a checker on his 6-point (index 5) and one on
    // index 22 that is fully blocked for both dice (Black owns 17 and 19).
    // Dice 5-3. The 5 plays 6/1 (index 5 -> 0); the 3 plays 6/3
    // (index 5 -> 2). Neither play has a legal continuation: the follow-up
    // would have to bear off, which is illegal while the index-22 checker
    // is outside the home board. So both single-die plays exist, only one
    // die can ever be used, and the higher (the 5, 6/1) is mandatory.
    final pts = List<int>.filled(24, 0);
    pts[5] = 1; // White on his 6-point
    pts[22] = 1; // White checker outside home, blocked for both dice
    pts[17] = -2; // blocks 23/18 (the 5)
    pts[19] = -2; // blocks 23/20 (the 3)
    final board = BoardState(points: pts, whiteOff: 13);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(5, 3));
    expect(moves, hasLength(1));
    expect(moves.single.checkerMoves.single.from, 5);
    expect(moves.single.checkerMoves.single.to, 0); // 6/1 = the 5
  });

  test('rule does not apply when both dice are playable together', () {
    final moves =
        MoveGenerator.legalMoves(BoardState.initial(), Player.white, Dice(5, 3));
    expect(moves.every((m) => m.checkerMoves.length == 2), isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/higher_die_test.dart`
Expected: FAIL — first test gets 2 moves (both single-die plays offered).

- [ ] **Step 3: Implement**

In `MoveGenerator.legalMoves`, after the search loop and before `_denormalize`, insert:
```dart
    if (!dice.isDouble && maxLen == 1) {
      final usesHigh = [
        for (final m in byResult.values)
          if (_dieOf(m.checkerMoves.single) == dice.high) m,
      ];
      if (usesHigh.isNotEmpty) {
        return _denormalize(usesHigh, player);
      }
    }
```

And add the helper to `MoveGenerator`:
```dart
  /// The die a single normalized hop consumed. Bear-off overshoots consume
  /// a die larger than the exact distance; report the distance, and treat
  /// "at least" matches at the call site via dedup (overshoots reaching the
  /// same result collapse to one entry keyed by position).
  static int _dieOf(CheckerMove cm) {
    final from = cm.from == CheckerMove.bar ? 24 : cm.from;
    if (cm.to == CheckerMove.off) return from + 1;
    return from - cm.to;
  }
```

Note: for a single-move bear-off where either die could be used (overshoot),
both orders reach the same position and dedupe to one Move; `_dieOf` reports
the exact pip distance which may be lower than `dice.high`, so the
`usesHigh.isNotEmpty` guard correctly falls back to offering the move.

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/higher_die_test.dart` then `dart test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/backgammon_core
git commit -m "feat(core): enforce higher-die rule for single-die turns"
```

---

### Task 10: GameState — roll, move, game over

**Files:**
- Create: `packages/backgammon_core/lib/src/game_state.dart`
- Modify: `packages/backgammon_core/lib/backgammon_core.dart`
- Test: `packages/backgammon_core/test/game_state_test.dart`

- [ ] **Step 1: Write the failing test**

`test/game_state_test.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  GameState fresh() =>
      GameState.opening(firstPlayer: Player.white, openingDice: Dice(3, 1));

  test('opening state is ready to move with the opening dice', () {
    final s = fresh();
    expect(s.turn, Player.white);
    expect(s.phase, GamePhase.moving);
    expect(s.dice, Dice(3, 1));
    expect(s.cube.value, 1);
    expect(s.cube.owner, isNull);
  });

  test('playing a legal move passes the turn', () {
    final s = fresh()
        .play(Move(const [CheckerMove(7, 4), CheckerMove(5, 4)]));
    expect(s.turn, Player.black);
    expect(s.phase, GamePhase.awaitingRoll);
    expect(s.dice, isNull);
    expect(s.board.points[4], 2);
  });

  test('illegal moves throw', () {
    expect(() => fresh().play(Move(const [CheckerMove(23, 20)])),
        throwsStateError); // only one hop for a 3-1 that has two playable
  });

  test('roll only when awaiting roll', () {
    expect(() => fresh().roll(Dice(2, 2)), throwsStateError);
    final s = fresh()
        .play(Move(const [CheckerMove(7, 4), CheckerMove(5, 4)]))
        .roll(Dice(2, 2));
    expect(s.phase, GamePhase.moving);
    expect(s.turn, Player.black);
  });

  test('bearing off the 15th checker wins: single, gammon, backgammon', () {
    GameState endgame({required int blackOff, int blackInWhiteHome = 0}) {
      final pts = List<int>.filled(24, 0);
      pts[0] = 1; // White's last checker on his 1-point
      if (blackInWhiteHome > 0) pts[3] = -blackInWhiteHome;
      final blackRemaining = 15 - blackOff - blackInWhiteHome;
      if (blackRemaining > 0) pts[20] = -blackRemaining;
      return GameState.testState(
        board: BoardState(
            points: pts, whiteOff: 14, blackOff: blackOff),
        turn: Player.white,
        phase: GamePhase.moving,
        dice: Dice(1, 2),
        cube: const CubeState(value: 2, owner: Player.white),
      );
    }

    final single = endgame(blackOff: 3)
        .play(Move(const [CheckerMove(0, CheckerMove.off)]));
    expect(single.phase, GamePhase.gameOver);
    expect(single.result!.winner, Player.white);
    expect(single.result!.outcome, GameOutcome.single);
    expect(single.result!.points, 2); // cube 2 × 1

    final gammon = endgame(blackOff: 0)
        .play(Move(const [CheckerMove(0, CheckerMove.off)]));
    expect(gammon.result!.outcome, GameOutcome.gammon);
    expect(gammon.result!.points, 4); // cube 2 × 2

    final bg = endgame(blackOff: 0, blackInWhiteHome: 2)
        .play(Move(const [CheckerMove(0, CheckerMove.off)]));
    expect(bg.result!.outcome, GameOutcome.backgammon);
    expect(bg.result!.points, 6); // cube 2 × 3
  });

  test('a dance passes the turn with Move.none', () {
    // White on the bar, Black's home fully closed.
    final pts = List<int>.filled(24, 0);
    for (var i = 18; i < 24; i++) {
      pts[i] = -2;
    }
    pts[0] = -3; // remaining black checkers
    pts[12] = 14; // white checkers elsewhere
    final s = GameState.testState(
      board: BoardState(points: pts, whiteBar: 1),
      turn: Player.white,
      phase: GamePhase.moving,
      dice: Dice(6, 2),
      cube: const CubeState(value: 1, owner: null),
    );
    expect(s.legalMoves, isEmpty);
    expect(() => s.play(Move(const [CheckerMove(12, 10)])), throwsStateError);
    final next = s.play(Move.none);
    expect(next.turn, Player.black);
    expect(next.phase, GamePhase.awaitingRoll);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/game_state_test.dart`
Expected: FAIL — `GameState` undefined.

- [ ] **Step 3: Implement**

`lib/src/game_state.dart`:
```dart
import 'board_state.dart';
import 'dice.dart';
import 'move.dart';
import 'move_generator.dart';
import 'player.dart';

enum GamePhase { awaitingRoll, moving, cubeOffered, resignOffered, gameOver }

enum GameOutcome { single, gammon, backgammon, drop, resignation }

class CubeState {
  final int value;
  final Player? owner; // null = centered

  const CubeState({required this.value, required this.owner});
  const CubeState.initial() : this(value: 1, owner: null);

  @override
  bool operator ==(Object other) =>
      other is CubeState && other.value == value && other.owner == owner;

  @override
  int get hashCode => Object.hash(value, owner);
}

class GameResult {
  final Player winner;
  final int points;
  final GameOutcome outcome;

  const GameResult(
      {required this.winner, required this.points, required this.outcome});
}

/// Immutable game state machine. All mutating verbs return a new state and
/// throw [StateError] on illegal transitions.
class GameState {
  final BoardState board;
  final Player turn;
  final GamePhase phase;
  final Dice? dice;
  final CubeState cube;
  final bool isCrawfordGame;
  final GameResult? result;

  const GameState._({
    required this.board,
    required this.turn,
    required this.phase,
    required this.dice,
    required this.cube,
    required this.isCrawfordGame,
    required this.result,
  });

  /// Start of game: the opening roll decided [firstPlayer], who now plays
  /// [openingDice] (never a double — ties are re-rolled by the caller).
  factory GameState.opening({
    required Player firstPlayer,
    required Dice openingDice,
    bool isCrawfordGame = false,
  }) {
    if (openingDice.isDouble) {
      throw ArgumentError('opening roll cannot be a double');
    }
    return GameState._(
      board: BoardState.initial(),
      turn: firstPlayer,
      phase: GamePhase.moving,
      dice: openingDice,
      cube: const CubeState.initial(),
      isCrawfordGame: isCrawfordGame,
      result: null,
    );
  }

  /// Arbitrary state for tests and analysis tooling.
  factory GameState.testState({
    required BoardState board,
    required Player turn,
    required GamePhase phase,
    Dice? dice,
    CubeState cube = const CubeState.initial(),
    bool isCrawfordGame = false,
  }) =>
      GameState._(
        board: board,
        turn: turn,
        phase: phase,
        dice: dice,
        cube: cube,
        isCrawfordGame: isCrawfordGame,
        result: null,
      );

  GameState _copy({
    BoardState? board,
    Player? turn,
    GamePhase? phase,
    Dice? dice,
    bool clearDice = false,
    CubeState? cube,
    GameResult? result,
  }) =>
      GameState._(
        board: board ?? this.board,
        turn: turn ?? this.turn,
        phase: phase ?? this.phase,
        dice: clearDice ? null : (dice ?? this.dice),
        cube: cube ?? this.cube,
        isCrawfordGame: isCrawfordGame,
        result: result ?? this.result,
      );

  void _require(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  List<Move> get legalMoves => phase == GamePhase.moving
      ? MoveGenerator.legalMoves(board, turn, dice!)
      : const [];

  GameState roll(Dice d) {
    _require(phase == GamePhase.awaitingRoll, 'not awaiting a roll');
    return _copy(dice: d, phase: GamePhase.moving);
  }

  GameState play(Move move) {
    _require(phase == GamePhase.moving, 'not in the moving phase');
    final legal = legalMoves;
    if (legal.isEmpty) {
      _require(move.checkerMoves.isEmpty, 'no legal moves: must pass');
      return _copy(
          turn: turn.opponent, phase: GamePhase.awaitingRoll, clearDice: true);
    }
    _require(legal.any((m) => m.sameAs(move)), 'illegal move: $move');
    final next = board.applyMove(turn, move);
    if (next.offFor(turn) == 15) {
      return _copy(
          board: next, phase: GamePhase.gameOver, result: _winResult(next));
    }
    return _copy(
        board: next,
        turn: turn.opponent,
        phase: GamePhase.awaitingRoll,
        clearDice: true);
  }

  GameResult _winResult(BoardState finalBoard) {
    final loser = turn.opponent;
    var outcome = GameOutcome.single;
    if (finalBoard.offFor(loser) == 0) {
      outcome = _loserTrappedForBackgammon(finalBoard, loser)
          ? GameOutcome.backgammon
          : GameOutcome.gammon;
    }
    final multiplier = switch (outcome) {
      GameOutcome.single => 1,
      GameOutcome.gammon => 2,
      GameOutcome.backgammon => 3,
      _ => throw StateError('unreachable'),
    };
    return GameResult(
        winner: turn, points: cube.value * multiplier, outcome: outcome);
  }

  /// Backgammon: the loser still has a checker on the bar or in the
  /// winner's home board.
  bool _loserTrappedForBackgammon(BoardState b, Player loser) {
    if (b.barFor(loser) > 0) return true;
    // Winner's home board: indices 0-5 when White wins, 18-23 when Black.
    final range = turn == Player.white
        ? [0, 1, 2, 3, 4, 5]
        : [18, 19, 20, 21, 22, 23];
    for (final i in range) {
      final c = b.points[i];
      if (loser == Player.white ? c > 0 : c < 0) return true;
    }
    return false;
  }
}
```

Append to `lib/backgammon_core.dart`:
```dart
export 'src/game_state.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/game_state_test.dart` then `dart test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/backgammon_core
git commit -m "feat(core): GameState with roll/move flow and win detection"
```

---

### Task 11: Doubling cube actions

**Files:**
- Modify: `packages/backgammon_core/lib/src/game_state.dart`
- Test: `packages/backgammon_core/test/cube_test.dart`

- [ ] **Step 1: Write the failing test**

`test/cube_test.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  GameState awaiting({CubeState cube = const CubeState.initial(),
      bool crawford = false}) {
    return GameState.testState(
      board: BoardState.initial(),
      turn: Player.white,
      phase: GamePhase.awaitingRoll,
      cube: cube,
      isCrawfordGame: crawford,
    );
  }

  test('double before rolling; opponent decides', () {
    final s = awaiting().offerDouble();
    expect(s.phase, GamePhase.cubeOffered);
    expect(s.turn, Player.black); // the decider
  });

  test('take doubles the cube and gives ownership to the taker', () {
    final s = awaiting().offerDouble().take();
    expect(s.cube, const CubeState(value: 2, owner: Player.black));
    expect(s.turn, Player.white); // doubler now rolls
    expect(s.phase, GamePhase.awaitingRoll);
  });

  test('drop ends the game at the pre-double stake', () {
    final s = awaiting(cube: const CubeState(value: 2, owner: Player.white))
        .offerDouble()
        .drop();
    expect(s.phase, GamePhase.gameOver);
    expect(s.result!.winner, Player.white);
    expect(s.result!.points, 2);
    expect(s.result!.outcome, GameOutcome.drop);
  });

  test('only the cube owner may redouble', () {
    final owned = awaiting(cube: const CubeState(value: 2, owner: Player.black));
    expect(() => owned.offerDouble(), throwsStateError); // white, not owner
  });

  test('no doubling in the Crawford game', () {
    expect(() => awaiting(crawford: true).offerDouble(), throwsStateError);
  });

  test('cannot double after rolling', () {
    final rolled = awaiting().roll(Dice(3, 1));
    expect(() => rolled.offerDouble(), throwsStateError);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/cube_test.dart`
Expected: FAIL — `offerDouble` undefined.

- [ ] **Step 3: Implement**

Add to `GameState` in `lib/src/game_state.dart`:
```dart
  GameState offerDouble() {
    _require(phase == GamePhase.awaitingRoll, 'can only double before rolling');
    _require(!isCrawfordGame, 'no doubling in the Crawford game');
    _require(cube.owner == null || cube.owner == turn,
        'only the cube owner may double');
    return _copy(phase: GamePhase.cubeOffered, turn: turn.opponent);
  }

  GameState take() {
    _require(phase == GamePhase.cubeOffered, 'no double is pending');
    return _copy(
      cube: CubeState(value: cube.value * 2, owner: turn),
      turn: turn.opponent,
      phase: GamePhase.awaitingRoll,
    );
  }

  GameState drop() {
    _require(phase == GamePhase.cubeOffered, 'no double is pending');
    return _copy(
      phase: GamePhase.gameOver,
      result: GameResult(
        winner: turn.opponent,
        points: cube.value,
        outcome: GameOutcome.drop,
      ),
    );
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/cube_test.dart` then `dart test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/backgammon_core
git commit -m "feat(core): doubling cube offer/take/drop with Crawford guard"
```

---

### Task 12: Resignation

**Files:**
- Modify: `packages/backgammon_core/lib/src/game_state.dart`
- Test: `packages/backgammon_core/test/resign_test.dart`

- [ ] **Step 1: Write the failing test**

`test/resign_test.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  GameState turnOf(Player p, {Dice? dice}) => GameState.testState(
        board: BoardState.initial(),
        turn: p,
        phase: dice == null ? GamePhase.awaitingRoll : GamePhase.moving,
        dice: dice,
        cube: const CubeState(value: 2, owner: Player.black),
      );

  test('offer and accept a gammon resignation', () {
    final s = turnOf(Player.white).offerResign(ResignValue.gammon);
    expect(s.phase, GamePhase.resignOffered);
    expect(s.turn, Player.black); // decider
    final done = s.acceptResign();
    expect(done.phase, GamePhase.gameOver);
    expect(done.result!.winner, Player.black);
    expect(done.result!.points, 4); // cube 2 × gammon 2
    expect(done.result!.outcome, GameOutcome.resignation);
  });

  test('decline returns to the offering player mid-turn', () {
    final s = turnOf(Player.white, dice: Dice(3, 1))
        .offerResign(ResignValue.single)
        .declineResign();
    expect(s.turn, Player.white);
    expect(s.phase, GamePhase.moving); // dice were already rolled
    expect(s.dice, Dice(3, 1));
  });

  test('decline before rolling returns to awaitingRoll', () {
    final s = turnOf(Player.white)
        .offerResign(ResignValue.single)
        .declineResign();
    expect(s.phase, GamePhase.awaitingRoll);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/resign_test.dart`
Expected: FAIL — `ResignValue`/`offerResign` undefined.

- [ ] **Step 3: Implement**

Add to `lib/src/game_state.dart` (top level):
```dart
enum ResignValue {
  single(1),
  gammon(2),
  backgammon(3);

  final int multiplier;
  const ResignValue(this.multiplier);
}

class ResignOffer {
  final Player by;
  final ResignValue value;
  const ResignOffer({required this.by, required this.value});
}
```

Add a `final ResignOffer? resignOffer;` field to `GameState` (thread it
through the private constructor, both factories — where it is null — and
`_copy` with a `clearResignOffer` flag, defaulting to carrying it forward).
Then add the verbs:
```dart
  GameState offerResign(ResignValue value) {
    _require(phase == GamePhase.awaitingRoll || phase == GamePhase.moving,
        'cannot resign now');
    return _copy(
      phase: GamePhase.resignOffered,
      turn: turn.opponent,
      resignOffer: ResignOffer(by: turn, value: value),
    );
  }

  GameState acceptResign() {
    _require(phase == GamePhase.resignOffered, 'no resignation is pending');
    final offer = resignOffer!;
    return _copy(
      phase: GamePhase.gameOver,
      clearResignOffer: true,
      result: GameResult(
        winner: offer.by.opponent,
        points: cube.value * offer.value.multiplier,
        outcome: GameOutcome.resignation,
      ),
    );
  }

  GameState declineResign() {
    _require(phase == GamePhase.resignOffered, 'no resignation is pending');
    final offer = resignOffer!;
    return _copy(
      phase: dice == null ? GamePhase.awaitingRoll : GamePhase.moving,
      turn: offer.by,
      clearResignOffer: true,
    );
  }
```

`_copy` signature gains:
```dart
    ResignOffer? resignOffer,
    bool clearResignOffer = false,
```
with the field assignment:
```dart
        resignOffer:
            clearResignOffer ? null : (resignOffer ?? this.resignOffer),
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/resign_test.dart` then `dart test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/backgammon_core
git commit -m "feat(core): resignation offer/accept/decline"
```

---

### Task 13: MatchState and the Crawford rule

**Files:**
- Create: `packages/backgammon_core/lib/src/match_state.dart`
- Modify: `packages/backgammon_core/lib/backgammon_core.dart`
- Test: `packages/backgammon_core/test/match_state_test.dart`

- [ ] **Step 1: Write the failing test**

`test/match_state_test.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  const win2 = GameResult(
      winner: Player.white, points: 2, outcome: GameOutcome.single);

  test('scores accumulate and the match ends at the match length', () {
    var m = MatchState(matchLength: 3);
    m = m.applyResult(win2);
    expect(m.whiteScore, 2);
    expect(m.isMatchOver, isFalse);
    m = m.applyResult(win2);
    expect(m.isMatchOver, isTrue);
    expect(m.winner, Player.white);
  });

  test('reaching matchLength-1 makes the next game the Crawford game', () {
    var m = MatchState(matchLength: 3);
    expect(m.isCrawfordNext, isFalse);
    m = m.applyResult(win2); // white at 2 of 3
    expect(m.isCrawfordNext, isTrue);
    // Black wins the Crawford game 1 point; doubling returns afterwards.
    m = m.applyResult(const GameResult(
        winner: Player.black, points: 1, outcome: GameOutcome.single));
    expect(m.blackScore, 1);
    expect(m.isCrawfordNext, isFalse);
    expect(m.crawfordPlayed, isTrue);
  });

  test('crawford only triggers once even if the other player also reaches -1',
      () {
    var m = MatchState(matchLength: 3)
        .applyResult(win2) // white 2-0, next is crawford
        .applyResult(const GameResult(
            winner: Player.black, points: 2, outcome: GameOutcome.gammon));
    // black jumped to 2 as well, but crawford was already played
    expect(m.whiteScore, 2);
    expect(m.blackScore, 2);
    expect(m.isCrawfordNext, isFalse);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/match_state_test.dart`
Expected: FAIL — `MatchState` undefined.

- [ ] **Step 3: Implement**

`lib/src/match_state.dart`:
```dart
import 'game_state.dart';
import 'player.dart';

/// Score state of a match, between games. Immutable.
class MatchState {
  final int matchLength;
  final int whiteScore;
  final int blackScore;
  final bool crawfordPlayed;

  const MatchState({
    required this.matchLength,
    this.whiteScore = 0,
    this.blackScore = 0,
    this.crawfordPlayed = false,
  });

  bool get isMatchOver =>
      whiteScore >= matchLength || blackScore >= matchLength;

  Player? get winner => !isMatchOver
      ? null
      : (whiteScore >= matchLength ? Player.white : Player.black);

  /// True when the game about to be played is the Crawford game
  /// (no doubling allowed in it).
  bool get isCrawfordNext {
    if (crawfordPlayed || isMatchOver) return false;
    return whiteScore == matchLength - 1 || blackScore == matchLength - 1;
  }

  MatchState applyResult(GameResult r) {
    final crawfordJustPlayed = isCrawfordNext;
    return MatchState(
      matchLength: matchLength,
      whiteScore: whiteScore + (r.winner == Player.white ? r.points : 0),
      blackScore: blackScore + (r.winner == Player.black ? r.points : 0),
      crawfordPlayed: crawfordPlayed || crawfordJustPlayed,
    );
  }
}
```

Append to `lib/backgammon_core.dart`:
```dart
export 'src/match_state.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/match_state_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/backgammon_core
git commit -m "feat(core): match scoring with Crawford tracking"
```

---

### Task 14: Game events, replay, and JSON serialization

**Files:**
- Create: `packages/backgammon_core/lib/src/game_events.dart`
- Create: `packages/backgammon_core/lib/src/game.dart`
- Modify: `packages/backgammon_core/lib/backgammon_core.dart`
- Test: `packages/backgammon_core/test/game_events_test.dart`

- [ ] **Step 1: Write the failing test**

`test/game_events_test.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  final events = <GameEvent>[
    const OpeningRollEvent(whiteDie: 3, blackDie: 1),
    MoveEvent(Player.white,
        Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
    const RollEvent(Player.black, 6, 5),
    MoveEvent(Player.black,
        Move(const [CheckerMove(0, 6), CheckerMove(6, 11)])),
  ];

  test('replay folds events into the expected state', () {
    final game = Game.replay(events);
    expect(game.state.turn, Player.white);
    expect(game.state.phase, GamePhase.awaitingRoll);
    expect(game.state.board.points[4], 2);
    // Black's leaping checker joins the 5 already on White's 12-point.
    expect(game.state.board.points[11], -6);
  });

  test('illegal events throw during replay', () {
    expect(
      () => Game.replay([
        const OpeningRollEvent(whiteDie: 3, blackDie: 1),
        const RollEvent(Player.white, 6, 5), // must move first, not roll
      ]),
      throwsStateError,
    );
  });

  test('opening tie is rejected', () {
    expect(() => const OpeningRollEvent(whiteDie: 2, blackDie: 2).validate(),
        throwsArgumentError);
  });

  test('every event survives a JSON round-trip', () {
    final all = <GameEvent>[
      ...events,
      const DoubleEvent(Player.white),
      const TakeEvent(Player.black),
      const DropEvent(Player.black),
      const ResignOfferEvent(Player.white, ResignValue.gammon),
      const ResignAcceptEvent(Player.black),
      const ResignDeclineEvent(Player.black),
    ];
    for (final e in all) {
      final back = GameEvent.fromJson(e.toJson());
      expect(back, e, reason: 'round-trip failed for ${e.runtimeType}');
    }
  });

  test('cube events replay', () {
    final game = Game.replay([
      const OpeningRollEvent(whiteDie: 3, blackDie: 1),
      MoveEvent(Player.white,
          Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
      const DoubleEvent(Player.black),
      const TakeEvent(Player.white),
    ]);
    expect(game.state.cube, const CubeState(value: 2, owner: Player.white));
    expect(game.state.turn, Player.black);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/game_events_test.dart`
Expected: FAIL — event types undefined.

- [ ] **Step 3: Implement**

`lib/src/game_events.dart`:
```dart
import 'game_state.dart';
import 'move.dart';
import 'player.dart';

/// One entry in a game's append-only event log. Events carry no derived
/// state; folding them (see Game.replay) reproduces the GameState.
sealed class GameEvent {
  const GameEvent();

  Map<String, dynamic> toJson();

  static GameEvent fromJson(Map<String, dynamic> json) {
    final player = json['player'] != null
        ? Player.values.byName(json['player'] as String)
        : null;
    return switch (json['type'] as String) {
      'openingRoll' => OpeningRollEvent(
          whiteDie: json['whiteDie'] as int,
          blackDie: json['blackDie'] as int),
      'roll' => RollEvent(player!, json['die1'] as int, json['die2'] as int),
      'move' => MoveEvent(player!, _moveFromJson(json['move'] as List)),
      'double' => DoubleEvent(player!),
      'take' => TakeEvent(player!),
      'drop' => DropEvent(player!),
      'resignOffer' => ResignOfferEvent(
          player!, ResignValue.values.byName(json['value'] as String)),
      'resignAccept' => ResignAcceptEvent(player!),
      'resignDecline' => ResignDeclineEvent(player!),
      final t => throw ArgumentError('unknown event type: $t'),
    };
  }

  static Move _moveFromJson(List<dynamic> hops) => Move([
        for (final h in hops)
          CheckerMove(h[0] as int, h[1] as int, isHit: h[2] as bool),
      ]);

  static List<List<Object>> moveToJson(Move m) => [
        for (final c in m.checkerMoves) [c.from, c.to, c.isHit],
      ];
}

class OpeningRollEvent extends GameEvent {
  final int whiteDie;
  final int blackDie;
  const OpeningRollEvent({required this.whiteDie, required this.blackDie});

  void validate() {
    if (whiteDie == blackDie) {
      throw ArgumentError('opening roll ties are re-rolled, not recorded');
    }
  }

  Player get firstPlayer => whiteDie > blackDie ? Player.white : Player.black;

  @override
  Map<String, dynamic> toJson() =>
      {'type': 'openingRoll', 'whiteDie': whiteDie, 'blackDie': blackDie};

  @override
  bool operator ==(Object o) =>
      o is OpeningRollEvent && o.whiteDie == whiteDie && o.blackDie == blackDie;
  @override
  int get hashCode => Object.hash(whiteDie, blackDie);
}

class RollEvent extends GameEvent {
  final Player player;
  final int die1;
  final int die2;
  const RollEvent(this.player, this.die1, this.die2);

  @override
  Map<String, dynamic> toJson() =>
      {'type': 'roll', 'player': player.name, 'die1': die1, 'die2': die2};

  @override
  bool operator ==(Object o) =>
      o is RollEvent && o.player == player && o.die1 == die1 && o.die2 == die2;
  @override
  int get hashCode => Object.hash(player, die1, die2);
}

class MoveEvent extends GameEvent {
  final Player player;
  final Move move;
  const MoveEvent(this.player, this.move);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'move',
        'player': player.name,
        'move': GameEvent.moveToJson(move),
      };

  @override
  bool operator ==(Object o) =>
      o is MoveEvent && o.player == player && o.move.sameAs(move);
  @override
  int get hashCode => Object.hash(player, move.checkerMoves.length);
}

class DoubleEvent extends GameEvent {
  final Player player;
  const DoubleEvent(this.player);
  @override
  Map<String, dynamic> toJson() => {'type': 'double', 'player': player.name};
  @override
  bool operator ==(Object o) => o is DoubleEvent && o.player == player;
  @override
  int get hashCode => Object.hash('double', player);
}

class TakeEvent extends GameEvent {
  final Player player;
  const TakeEvent(this.player);
  @override
  Map<String, dynamic> toJson() => {'type': 'take', 'player': player.name};
  @override
  bool operator ==(Object o) => o is TakeEvent && o.player == player;
  @override
  int get hashCode => Object.hash('take', player);
}

class DropEvent extends GameEvent {
  final Player player;
  const DropEvent(this.player);
  @override
  Map<String, dynamic> toJson() => {'type': 'drop', 'player': player.name};
  @override
  bool operator ==(Object o) => o is DropEvent && o.player == player;
  @override
  int get hashCode => Object.hash('drop', player);
}

class ResignOfferEvent extends GameEvent {
  final Player player;
  final ResignValue value;
  const ResignOfferEvent(this.player, this.value);
  @override
  Map<String, dynamic> toJson() =>
      {'type': 'resignOffer', 'player': player.name, 'value': value.name};
  @override
  bool operator ==(Object o) =>
      o is ResignOfferEvent && o.player == player && o.value == value;
  @override
  int get hashCode => Object.hash(player, value);
}

class ResignAcceptEvent extends GameEvent {
  final Player player;
  const ResignAcceptEvent(this.player);
  @override
  Map<String, dynamic> toJson() =>
      {'type': 'resignAccept', 'player': player.name};
  @override
  bool operator ==(Object o) => o is ResignAcceptEvent && o.player == player;
  @override
  int get hashCode => Object.hash('resignAccept', player);
}

class ResignDeclineEvent extends GameEvent {
  final Player player;
  const ResignDeclineEvent(this.player);
  @override
  Map<String, dynamic> toJson() =>
      {'type': 'resignDecline', 'player': player.name};
  @override
  bool operator ==(Object o) => o is ResignDeclineEvent && o.player == player;
  @override
  int get hashCode => Object.hash('resignDecline', player);
}
```

`lib/src/game.dart`:
```dart
import 'dice.dart';
import 'game_events.dart';
import 'game_state.dart';

/// A single game as an event log plus its folded state. Appending an event
/// validates it against the state machine; replay rebuilds from scratch.
class Game {
  final List<GameEvent> events;
  final GameState state;

  Game._(this.events, this.state);

  factory Game.replay(List<GameEvent> events, {bool isCrawfordGame = false}) {
    if (events.isEmpty || events.first is! OpeningRollEvent) {
      throw StateError('a game starts with an OpeningRollEvent');
    }
    final opening = events.first as OpeningRollEvent..validate();
    var state = GameState.opening(
      firstPlayer: opening.firstPlayer,
      openingDice: Dice(opening.whiteDie, opening.blackDie),
      isCrawfordGame: isCrawfordGame,
    );
    for (final event in events.skip(1)) {
      state = _apply(state, event);
    }
    return Game._(List.unmodifiable(events), state);
  }

  Game append(GameEvent event) =>
      Game._([...events, event], _apply(state, event));

  static GameState _apply(GameState s, GameEvent e) => switch (e) {
        OpeningRollEvent() =>
          throw StateError('opening roll must be the first event'),
        RollEvent(:final player, :final die1, :final die2) => _forPlayer(
            s, player, () => s.roll(Dice(die1, die2))),
        MoveEvent(:final player, :final move) =>
          _forPlayer(s, player, () => s.play(move)),
        DoubleEvent(:final player) =>
          _forPlayer(s, player, () => s.offerDouble()),
        TakeEvent(:final player) => _forPlayer(s, player, () => s.take()),
        DropEvent(:final player) => _forPlayer(s, player, () => s.drop()),
        ResignOfferEvent(:final player, :final value) =>
          _forPlayer(s, player, () => s.offerResign(value)),
        ResignAcceptEvent(:final player) =>
          _forPlayer(s, player, () => s.acceptResign()),
        ResignDeclineEvent(:final player) =>
          _forPlayer(s, player, () => s.declineResign()),
      };

  static GameState _forPlayer(
      GameState s, Player player, GameState Function() action) {
    if (s.turn != player) {
      throw StateError('event out of turn: expected ${s.turn}, got $player');
    }
    return action();
  }
}
```

(Add `import 'player.dart';` to `game.dart` for the `Player` reference.)

Append to `lib/backgammon_core.dart`:
```dart
export 'src/game.dart';
export 'src/game_events.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/game_events_test.dart` then `dart test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/backgammon_core
git commit -m "feat(core): event-sourced Game with replay and JSON round-trip"
```

---

### Task 15: Random-playout property test

**Files:**
- Test: `packages/backgammon_core/test/playout_test.dart`

This is the package's integration safety net: hundreds of full random games
must terminate with all invariants intact. It exercises every rule path the
unit tests cover individually.

- [ ] **Step 1: Write the test**

`test/playout_test.dart`:
```dart
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  test('300 random games terminate with invariants intact', () {
    final rng = Random(20260724);
    Dice rollDice() => Dice(rng.nextInt(6) + 1, rng.nextInt(6) + 1);

    for (var g = 0; g < 300; g++) {
      var opening = rollDice();
      while (opening.isDouble) {
        opening = rollDice();
      }
      var state = GameState.opening(
        firstPlayer:
            opening.die1 > opening.die2 ? Player.white : Player.black,
        openingDice: opening,
      );
      var turns = 0;
      while (state.phase != GamePhase.gameOver) {
        turns++;
        expect(turns, lessThan(2000),
            reason: 'game $g did not terminate');
        expect(state.board.checkerCount(Player.white), 15);
        expect(state.board.checkerCount(Player.black), 15);
        switch (state.phase) {
          case GamePhase.awaitingRoll:
            // Occasionally double when allowed.
            final canDouble = !state.isCrawfordGame &&
                (state.cube.owner == null || state.cube.owner == state.turn);
            if (canDouble && state.cube.value < 8 && rng.nextInt(20) == 0) {
              state = state.offerDouble();
            } else {
              state = state.roll(rollDice());
            }
          case GamePhase.moving:
            final legal = state.legalMoves;
            state = state.play(
                legal.isEmpty ? Move.none : legal[rng.nextInt(legal.length)]);
          case GamePhase.cubeOffered:
            state = rng.nextInt(4) == 0 ? state.drop() : state.take();
          case GamePhase.resignOffered:
          case GamePhase.gameOver:
            fail('unexpected phase ${state.phase}');
        }
      }
      final r = state.result!;
      expect(r.points, greaterThan(0));
      if (r.outcome != GameOutcome.drop) {
        expect(state.board.offFor(r.winner), 15);
      }
    }
  });
}
```

- [ ] **Step 2: Run the test**

Run: `dart test test/playout_test.dart`
Expected: PASS in well under a minute. If any invariant trips, debug with the
seed — the failure is deterministic.

- [ ] **Step 3: Run the entire suite with analyzer**

Run: `dart analyze && dart test`
Expected: no analyzer issues, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add packages/backgammon_core
git commit -m "test(core): random-playout property test for full-game invariants"
```

---

## Post-plan follow-ups (explicitly deferred)

- **gnubg fixture cross-validation** (spec §8): a tooling task in Plan 2's
  test phase — generate positions + legal-move sets with gnubg on a desktop
  machine and check them into `test/fixtures/`. The property test above is
  the v1 gate; gnubg fixtures harden it.
- **Position ID export** (spec §2): needed when engine debugging starts —
  scheduled as part of Plan 2 (engine integration), where it earns its keep.
- **Match equity / Janowski math** (spec §3): lives with the engine adapter
  in Plan 2, not in backgammon_core.
