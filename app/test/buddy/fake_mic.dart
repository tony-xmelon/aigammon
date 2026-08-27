import 'dart:async';

import 'package:aigammon_app/buddy/dice_sound_trigger.dart';

/// A microphone that is a list of numbers.
///
/// One double, in its own file, because three suites need it — the detector's
/// own tests, the frame gate's inertness proof, and the game screen's wiring —
/// and a double that exists three times drifts in whichever two copies a fix
/// was not applied to. (The same reasoning that put `FakeBuddyCamera` in
/// `fake_calibration_seams.dart`; this is not that file because the calibration
/// seams are a different subject.)
class FakeMicSource implements MicAmplitudeSource {
  FakeMicSource({this.opening = MicOpening.listening, this.throwOnOpen = false});

  /// What [open] answers.
  final MicOpening opening;

  /// Whether [open] throws instead of answering — a desktop with no plugin
  /// behind the channel, which is a `MissingPluginException` rather than a
  /// polite refusal.
  final bool throwOnOpen;

  final _controller = StreamController<AmplitudeSample>.broadcast();

  int opens = 0;
  bool closed = false;

  @override
  Stream<AmplitudeSample> get amplitudes => _controller.stream;

  @override
  Future<MicOpening> open() async {
    opens++;
    if (throwOnOpen) throw StateError('no microphone here');
    return opening;
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) await _controller.close();
  }

  void emit(AmplitudeSample sample) {
    if (!_controller.isClosed) _controller.add(sample);
  }

  /// Pushes a whole script and lets the stream deliver it.
  Future<void> play(List<AmplitudeSample> script) async {
    for (final sample in script) {
      emit(sample);
    }
    await Future<void>.delayed(Duration.zero);
  }
}

/// Room tone with the couple of decibels of wobble a real one has — a
/// microphone that is genuinely live and has nothing whatsoever to say.
List<AmplitudeSample> quietRoom({
  int count = 400,
  Duration from = Duration.zero,
  Duration hop = const Duration(milliseconds: 16),
}) =>
    <AmplitudeSample>[
      for (var i = 0; i < count; i++)
        AmplitudeSample.decibels(-60 + (i % 5) - 2, from + hop * i),
    ];

/// Quiet room, then one impulse that decays back into it — the shape a throw
/// makes, and the only script in these suites that is supposed to fire.
List<AmplitudeSample> diceClatter({
  double room = -60,
  double peak = -28,
  int hops = 8,
  int roomHops = 60,
  int tailHops = 20,
  Duration hop = const Duration(milliseconds: 16),
}) {
  final script = quietRoom(count: roomHops, hop: hop)
      .map((s) => AmplitudeSample.decibels(room, s.at))
      .toList();
  var at = script.last.at + hop;
  for (var i = 0; i < hops; i++) {
    script.add(
        AmplitudeSample.decibels(peak + (room - peak) * (i / hops), at));
    at += hop;
  }
  for (var i = 0; i < tailHops; i++) {
    script.add(AmplitudeSample.decibels(room, at));
    at += hop;
  }
  return script;
}
