/// The capture plan, written out for a person with a phone and a board.
///
/// The audience is not a developer. It is whoever is going to spend an hour
/// setting up positions and taking photographs, and every sentence is judged on
/// whether it can be followed without asking anybody a question. Hence the
/// board diagrams (a person cannot set up `[-2, 0, 0, 0, 0, 5, ...]`), hence
/// the warnings repeated per session rather than stated once at the top, and
/// hence the plain naming of what each shot is for — a shot taken without
/// knowing why is the one that gets taken carelessly.
library;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';

import 'capture_plan.dart';

/// The whole checklist, as markdown.
String renderChecklist(List<CaptureSession> sessions, {int seed = kCorpusSeed}) {
  final shots = flatten(sessions);
  final out = StringBuffer()
    ..writeln('# Buddy Mode — board capture checklist')
    ..writeln()
    ..writeln('Generated from seed $seed by '
        '`tool/generate_capture_checklist.dart`. **Do not edit by hand** — '
        'every shot has a matching `NNN.expected.json` beside this file that '
        'was generated from the same plan, and editing one without the other '
        'is how a corpus starts lying.')
    ..writeln()
    ..writeln('${shots.length} photographs, in ${sessions.length} sessions. '
        'Budget about ten minutes a session.')
    ..writeln();

  _writeHowTo(out);

  for (final session in sessions) {
    _writeSession(out, session);
  }

  _writeAfterwards(out, sessions);
  return out.toString();
}

void _writeHowTo(StringBuffer out) {
  out
    ..writeln('## Before you start')
    ..writeln()
    ..writeln('- **Any normal camera app.** No app build, no special mode. '
        'Shoot at the highest quality the phone offers.')
    ..writeln('- **Two different physical boards.** Different colours if you '
        'can — the whole point is that nothing in the pipeline knows what a '
        'backgammon board looks like. If the two boards are near-identical, '
        'say so when you hand the photographs over; it is a real limit on '
        'what the numbers mean.')
    ..writeln('- **Set up with the home boards to the RIGHT** for both '
        'players. A board set up the other way round is a mirror image, and '
        'nothing downstream can undo that.')
    ..writeln('- **The whole playing field must be in every picture**, both '
        'bear-off trays included, with a little room to spare.')
    ..writeln('- **Nothing on the felt but what the shot asks for.** No cube, '
        'no cups, no hands, no phone shadow across the middle.')
    ..writeln('- **Name the files by shot number**: `001.jpg`, `002.jpg`, and '
        'so on, in the order below. Everything downstream is keyed on that '
        'number.')
    ..writeln()
    ..writeln('### The one rule that matters most')
    ..writeln()
    ..writeln('A **session** is one board, one light, one camera position. Its '
        'first shot is the calibration shot, and every later shot in that '
        'session is read through it. So: **once a session\'s first photo is '
        'taken, do not move the phone or the board until the session ends.** '
        'Nudging the phone between shots invalidates the rest of the session '
        'and there is no way to tell from the photographs that it happened.')
    ..writeln()
    ..writeln('Between sessions, move everything freely — a new camera '
        'position is exactly what the next session wants.')
    ..writeln()
    ..writeln('### Reading the diagrams')
    ..writeln()
    ..writeln('Point numbers run round the board as they always do. `5W` '
        'means five White checkers, `3B` three Black, `·` an empty point. The '
        'top row is the far side of the board from you, the bottom row the '
        'near side.')
    ..writeln();
}

void _writeSession(StringBuffer out, CaptureSession session) {
  out
    ..writeln('---')
    ..writeln()
    ..writeln('## Session ${session.name} '
        '(shots ${session.shots.first.id}–${session.shots.last.id})')
    ..writeln()
    ..writeln('- **Board:** ${session.conditions.board}')
    ..writeln('- **Light:** ${_lightingWords(session.conditions.lighting)}')
    ..writeln('- **Camera:** ${session.conditions.angle}')
    ..writeln('- **Your seat:** ${_seatWords(session.orientation)}')
    ..writeln();

  for (final shot in session.shots) {
    _writeShot(out, shot);
  }
}

void _writeShot(StringBuffer out, CorpusShot shot) {
  out
    ..writeln('### ${shot.id} — ${shot.title}')
    ..writeln();
  for (final line in shot.instructions) {
    out.writeln('- $line');
  }
  out.writeln();
  if (shot.kind == ShotKind.position || shot.kind == ShotKind.dice) {
    if (shot.board != BoardState.initial()) {
      out
        ..writeln('```text')
        ..write(describeBoard(shot.board))
        ..writeln('```')
        ..writeln();
    }
  }
  if (shot.expectsRefusal) {
    out
      ..writeln('> Expected to be **unreadable**: ${shot.refusalReason}.')
      ..writeln()
      ..writeln('> The corpus scores this shot on whether Buddy refuses it. A '
          'confident answer here is a worse failure than any wrong count '
          'elsewhere, because the user has no way to know it happened.')
      ..writeln();
  }
}

void _writeAfterwards(StringBuffer out, List<CaptureSession> sessions) {
  final calibrationShots =
      sessions.map((s) => s.calibrationShot.id).join(', ');
  out
    ..writeln('---')
    ..writeln()
    ..writeln('## When the photographs are taken')
    ..writeln()
    ..writeln('1. Put every file in one folder, named `001.jpg` … '
        '`${flatten(sessions).last.id}.jpg`.')
    ..writeln('2. Run the prep tool:')
    ..writeln()
    ..writeln('   ```')
    ..writeln('   dart run tool/prepare_corpus.dart --in <that folder>')
    ..writeln('   ```')
    ..writeln()
    ..writeln('   It shrinks each photo to at most 1280 px on its long side, '
        'writes it to `test/corpus/real/`, copies the sidecar beside it, and '
        'prints the total size against the '
        '${(kCorpusByteBudget / 1024 / 1024).round()} MB budget.')
    ..writeln()
    ..writeln('3. **The one manual step: the corners.** Perception is given '
        'the four corners of the playing field — in the app the user drags '
        'them onto a preview, and the corpus has to supply the same thing. '
        'The prep tool writes a `corners.json` template listing the shots that '
        'need corners; there are only ${sessions.length} of them, the '
        'calibration shot of each session ($calibrationShots), plus any shot '
        'marked unreadable that carries its own corners.')
    ..writeln()
    ..writeln('   Open each of those prepared JPEGs in any image viewer that '
        'shows pixel coordinates, read off the four corners of the playing '
        'field — **outer** corners, where the felt-and-tray field meets the '
        'wooden surround — and fill them in **clockwise from the top left as '
        'the photograph shows them**. Then run the prep tool again; it folds '
        'them into the sidecars.')
    ..writeln()
    ..writeln('4. Run the harness:')
    ..writeln()
    ..writeln('   ```')
    ..writeln('   dart test test/corpus_harness_test.dart')
    ..writeln('   ```')
    ..writeln()
    ..writeln('   It prints a scoreboard per metric and per slice — palette, '
        'lighting, board half, seating — and fails if a spec target is '
        'missed. That scoreboard is the Task 6 gate.')
    ..writeln()
    ..writeln('## If something goes wrong mid-session')
    ..writeln()
    ..writeln('Re-shoot the **whole session** rather than the one photograph. '
        'A session is a single camera position, and a re-take from a slightly '
        'different one is a shot whose sidecar is quietly wrong — which is '
        'worse for the corpus than a missing session.')
    ..writeln();
}

/// A position drawn the way it sits on the table, for a person to copy.
///
/// The layout is the standard diagram under `whiteHomeNear`: 13–18 across the
/// top left, 19–24 across the top right, 12–7 along the bottom left and 6–1
/// along the bottom right, with the bar down the middle. Seating does not
/// change it — the numbers are the game's, not the camera's, and a person
/// sitting on the other side reads the same diagram from the other side of the
/// table.
String describeBoard(BoardState board) {
  String cell(int pointNumber) {
    final count = board.points[pointNumber - 1];
    if (count == 0) return '  ·';
    final side = count > 0 ? 'W' : 'B';
    return '${count.abs().toString().padLeft(2)}$side';
  }

  String row(List<int> left, List<int> right) =>
      '${left.map(cell).join(' ')}  ║ ${right.map(cell).join(' ')}';

  String heading(List<int> left, List<int> right) =>
      '${left.map((n) => n.toString().padLeft(3)).join(' ')}  ║ '
      '${right.map((n) => n.toString().padLeft(3)).join(' ')}';

  const topLeft = <int>[13, 14, 15, 16, 17, 18];
  const topRight = <int>[19, 20, 21, 22, 23, 24];
  const bottomLeft = <int>[12, 11, 10, 9, 8, 7];
  const bottomRight = <int>[6, 5, 4, 3, 2, 1];

  // Six three-character cells joined by single spaces.
  const columnRun = 6 * 3 + 5;
  final out = StringBuffer()
    ..writeln('     ${heading(topLeft, topRight)}   far side')
    ..writeln('     ${row(topLeft, topRight)}')
    ..writeln('     ${'-' * columnRun}  ║ ${'-' * columnRun}')
    ..writeln('     ${row(bottomLeft, bottomRight)}')
    ..writeln('     ${heading(bottomLeft, bottomRight)}   near side');

  final extras = <String>[
    if (board.whiteBar > 0) '${board.whiteBar} White on the bar',
    if (board.blackBar > 0) '${board.blackBar} Black on the bar',
    if (board.whiteOff > 0) '${board.whiteOff} White borne off',
    if (board.blackOff > 0) '${board.blackOff} Black borne off',
  ];
  out.writeln(extras.isEmpty
      ? '     bar and trays empty'
      : '     ${extras.join(', ')}');
  return out.toString();
}

String _lightingWords(String lighting) => switch (lighting) {
      'daylight' => 'daylight — near a window, no lamp on',
      'lamp' => 'a lamp — curtains closed, one warm light source',
      'dim' => 'dim — one lamp across the room, or evening light. Still '
          'comfortably playable by eye, just poor',
      _ => lighting,
    };

String _seatWords(BoardOrientation orientation) =>
    orientation == BoardOrientation.whiteHomeNear
        ? 'the side where WHITE bears off into the tray on your right '
            '(White\'s 1-point is the bottom-right column)'
        : 'the OTHER side of the table — the side where BLACK bears off into '
            'the tray on your right';
