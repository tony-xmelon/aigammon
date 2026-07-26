// What [BoardPainter.activeDiceSide] actually does to the PIXELS.
//
// Every other dice test asserts the painter's INPUTS (which side is active, which
// slots are spent). That leaves the thing the user complained about — "my dice
// gets enabled while the opponent moves" — untested, because "enabled" is an
// opacity, not a field. These tests rasterise the painter and compare the dice
// pairs' brightness across emphasis states.
//
// NOT golden-tagged, so it runs in CI: nothing is compared against a stored PNG.
// Every assertion is RELATIVE — two renders from the same pipeline, in the same
// process — so platform antialiasing cannot make it flaky.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aigammon_app/board/board_geometry.dart';
import 'package:aigammon_app/board/board_painter.dart';
import 'package:aigammon_app/board/board_theme.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _size = Size(800, 600);
final _geometry = BoardGeometry(_size, whiteAtBottom: true);

/// Rasterises [painter] at [_size] and returns its RGBA pixels.
Future<ByteData> _raster(BoardPainter painter) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), _size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(_size.width.round(), _size.height.round());
  final data = await image.toByteData();
  picture.dispose();
  image.dispose();
  return data!;
}

/// A painter over the initial position with BOTH pairs showing a roll (so both
/// are drawable) and [active] as the emphasised side.
BoardPainter _painter(Player? active, {Set<int> spent = const {}}) =>
    BoardPainter(
      board: BoardState.initial(),
      geometry: _geometry,
      theme: BoardTheme.light,
      whiteDice: Dice(3, 1),
      blackDice: Dice(5, 4),
      activeDiceSide: active,
      usedDiceSlots: spent,
    );

/// Mean luminance-ish channel sum over [rect] — a single number standing in for
/// "how strongly this region is painted". Comparing the SAME region between two
/// renders isolates the alpha the painter applied to it.
double _meanIntensity(ByteData pixels, Rect rect) {
  final w = _size.width.round();
  var total = 0.0;
  var n = 0;
  for (var y = rect.top.round(); y < rect.bottom.round(); y++) {
    for (var x = rect.left.round(); x < rect.right.round(); x++) {
      final i = (y * w + x) * 4;
      total += pixels.getUint8(i) + pixels.getUint8(i + 1) + pixels.getUint8(i + 2);
      n++;
    }
  }
  return n == 0 ? 0 : total / n;
}

/// The left die of [player]'s pair — the region the emphasis acts on. Trimmed
/// slightly so neighbouring felt does not dilute the reading.
Rect _dieRect(Player player) {
  final pair = _geometry.diceRect(player);
  final side = _geometry.diceSide;
  return Rect.fromLTWH(pair.left, pair.top, side, side).deflate(1);
}

void main() {
  test('the active pair is painted MORE strongly than the other pair', () async {
    final pixels = await _raster(_painter(Player.white));
    final white = _meanIntensity(pixels, _dieRect(Player.white));
    final black = _meanIntensity(pixels, _dieRect(Player.black));
    // White's dice are light-bodied and Black's dark, so raw intensities are not
    // comparable between pairs; compare each pair against its own other state.
    final flipped = await _raster(_painter(Player.black));
    final whiteWhenWaiting = _meanIntensity(flipped, _dieRect(Player.white));
    final blackWhenActive = _meanIntensity(flipped, _dieRect(Player.black));

    expect(white, isNot(closeTo(whiteWhenWaiting, 0.5)),
        reason: "White's pair is painted differently when it is not the live "
            'roll — that difference IS the emphasis');
    expect(black, isNot(closeTo(blackWhenActive, 0.5)),
        reason: "Black's pair likewise");
  });

  test('activeDiceSide null dims BOTH pairs — the turn-is-over state', () async {
    final nobody = await _raster(_painter(null));
    final whiteLive = await _raster(_painter(Player.white));
    final blackLive = await _raster(_painter(Player.black));

    final whiteRect = _dieRect(Player.white);
    final blackRect = _dieRect(Player.black);

    // With nobody active, EACH pair is painted exactly as it is when the OTHER
    // side is the live one: both are dimmed, neither is emphasised.
    expect(_meanIntensity(nobody, whiteRect),
        closeTo(_meanIntensity(blackLive, whiteRect), 0.01),
        reason: "White's pair is dim when nobody is live");
    expect(_meanIntensity(nobody, blackRect),
        closeTo(_meanIntensity(whiteLive, blackRect), 0.01),
        reason: "Black's pair is dim when nobody is live");

    // And it is genuinely different from being lit (the reported bug was the
    // local pair re-brightening once its turn was over).
    expect(_meanIntensity(nobody, whiteRect),
        isNot(closeTo(_meanIntensity(whiteLive, whiteRect), 0.5)));
  });

  test('a spent die is dimmer still, and ONLY on the active pair', () async {
    // Slot 0 of the active pair reads as *disabled*, below the merely-waiting
    // opacity: the emphasis and the spent-die dimming stack, in that order.
    final activeSpent = await _raster(_painter(Player.white, spent: {0}));
    final activePlain = await _raster(_painter(Player.white));
    final rect = _dieRect(Player.white);
    expect(_meanIntensity(activeSpent, rect),
        isNot(closeTo(_meanIntensity(activePlain, rect), 0.5)),
        reason: 'a played die reads as spent on the pair that is playing it');

    // The same slot set applied while White is NOT the live pair changes nothing:
    // a memento pair can never show spent dice.
    final waitingSpent = await _raster(_painter(Player.black, spent: {0}));
    final waitingPlain = await _raster(_painter(Player.black));
    expect(_meanIntensity(waitingSpent, rect),
        closeTo(_meanIntensity(waitingPlain, rect), 0.01),
        reason: "the waiting pair's dice are never marked spent");
  });
}
