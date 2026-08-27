import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

// -----------------------------------------------------------------------------
// What this is, and — more importantly — what it is not.
//
// It is an ATTENTION HINT. When it fires, the frame gate is told to look at the
// board sooner than its own throttle would have; that is the whole of its
// effect. It answers no question, it decides nothing, and it can be absent,
// refused by the operating system, or switched off in Settings without changing
// a single thing about how a match plays. `FrameGate.attend` is the entire
// interface between this file and the rest of Buddy Mode, and
// `camera_frame_source_test.dart` holds the proof that a gate nobody attends is
// byte-for-byte the gate that existed before this file did.
//
// That is why the detector may be WRONG cheaply. A false fire costs one early
// look at a board that has not changed — a frame conversion, ~10ms on a worker
// isolate — and the refractory below bounds how often even a pathological room
// can spend one. A missed fire costs nothing at all: the gate's own 250ms
// cadence is what the mode shipped with, and it is still there underneath.
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// The provisional numbers.
//
// Six constants describe a sound this machine has never heard. There is no
// backgammon board here, no phone, and no microphone, so every one of them is
// derived from published properties of speech and of impact sounds rather than
// measured, and each ships with the arithmetic that produced it — the same
// contract the frame gate's constants ship under, and for the same reason:
// Task 15's on-device protocol needs something to disagree WITH.
//
// All six are in DECIBELS RELATIVE TO FULL SCALE and in wall-time windows, so
// they mean the same thing on both platforms and at any sample rate. That is
// the reason `PcmAmplitudeMeter` computes its own RMS rather than taking the
// plugin's amplitude reading, which is documented in neither units nor cadence
// and differs between the Android and iOS implementations.
// -----------------------------------------------------------------------------

/// How far over the room a hop has to jump to start a candidate transient.
///
/// **Provisional.** Twelve decibels is a four-fold jump in amplitude inside one
/// [kAmplitudeHopSamples] hop — 16ms at [kMicSampleRate]. The derivation:
///
///  * *Room tone* (must be BELOW this): the difference between a quiet room's
///    loudest and quietest moments is a couple of decibels; a fan cycling or a
///    chair creaking is under six.
///  * *A die hitting a board* (must be ABOVE this): an impact transient reaches
///    its peak within a millisecond or two, so essentially the whole of its
///    rise lands inside one hop. Published impact-noise measurements put a
///    small object dropped on a hard surface 25–40dB over a domestic room tone
///    at a metre.
///
/// Twelve sits at twice the loudest thing a still room does and less than half
/// of what a throw does. What moves it is a phone mic with automatic gain
/// control that cannot be switched off, which compresses exactly this
/// difference — see [RecordMicAmplitudeSource], which asks for it off.
const double kDiceAttackDecibels = 12.0;

/// How close to the pre-transient room a hop has to fall for the transient to
/// count as OVER.
///
/// **Provisional.** Six decibels is half the attack: a burst that has given
/// back three quarters of its amplitude has finished. Deliberately not "back to
/// the floor exactly", because dice come to rest in a room that is still
/// ringing slightly and because the running floor itself drifts upward during a
/// loud moment (see [kRoomFloorTimeConstant]).
const double kDiceQuietDecibels = 6.0;

/// How long a transient has to come and go inside.
///
/// **Provisional, and the one constant that carries the whole discrimination.**
/// It is what separates dice from a voice, and the separation is not close:
///
///  * *Dice* (must fit INSIDE this): two dice thrown by hand rattle for a
///    tenth of a second or so and are done; even a die that bounces off the rim
///    has stopped inside a quarter of one.
///  * *Speech* (must NOT fit): a stressed English vowel runs 150–300ms on its
///    own, and the raised envelope of a spoken phrase runs for seconds. A voice
///    that had gone quiet 250ms after starting would be a single syllable said
///    in isolation.
///
/// 250ms is at the top of the dice range and the bottom of the speech one, and
/// what it fails to reject is impulses that are not dice at all — a knock, a
/// clap, a snare drum. Those are accepted losses: see this file's header for
/// what a wrong fire actually costs.
const Duration kDiceDecayWindow = Duration(milliseconds: 250);

/// The shortest gap between two hints.
///
/// **Not provisional** — it is a budget, not a measurement. One throw is one
/// look, and a room that produces impulses continuously (a drummer, a building
/// site) must not be able to hold the gate at its fast cadence indefinitely.
/// Longer than [kDiceDecayWindow] by design, so the bounce of a single throw
/// cannot be counted twice; short enough that the two dice of an opening throw
/// landing separately still leaves the second one able to fire.
const Duration kDiceRefractory = Duration(milliseconds: 700);

/// How fast the running estimate of the room follows the room.
///
/// **Provisional.** The floor is an exponential moving average with this time
/// constant, so it reaches ~63% of a step change in this long and ~95% in three
/// times it. The two bounds:
///
///  * *Fast enough* that a television switched on stops being twelve decibels
///    of news within a few seconds rather than firing on every drum beat for
///    the rest of the match.
///  * *Slow enough* that a throw does not raise the floor out from under
///    itself: 250ms of clatter at this time constant moves the floor by about
///    a sixth of the burst's height, and the fire test is against a SNAPSHOT
///    taken before the attack anyway.
const Duration kRoomFloorTimeConstant = Duration(milliseconds: 1500);

/// How loud a transient has to be in absolute terms, whatever the room.
///
/// **Provisional.** Twelve decibels over a very quiet room is still a very
/// quiet sound: a page turning at -55dBFS clears [kDiceAttackDecibels] against
/// a -70dBFS floor and is not a throw. The derivation: phone microphones are
/// calibrated so that ordinary conversation at a metre lands around -30dBFS and
/// a quiet room's tone around -55 to -65. Dice on a board at the distance a
/// phone is propped for this mode are louder than conversation. -45dBFS is well
/// under the quietest plausible throw and well over the loudest rustle.
const double kDiceFloorDecibels = -45.0;

/// The sample rate the microphone is asked for.
///
/// The lowest rate every platform implements, and eight times more than the
/// detector needs: nothing here looks at frequency, only at how the energy of
/// the signal moves over tens of milliseconds. A lower rate costs less of
/// everything and there is no accuracy to trade for it.
const int kMicSampleRate = 16000;

/// Samples per amplitude reading: 256 at [kMicSampleRate] is 16ms.
///
/// Sets the detector's time resolution, and it is bounded on both sides.
/// Shorter, and one RMS reading starts to describe the waveform rather than the
/// envelope. Longer, and a 16ms attack starts to be averaged in with the quiet
/// before it, which is the one feature the whole signature turns on.
const int kAmplitudeHopSamples = 256;

// -----------------------------------------------------------------------------
// Pure: everything down to the plugin edge runs in `flutter test` with no
// microphone attached.
// -----------------------------------------------------------------------------

/// One reading of how loud the room is, on the audio's own clock.
///
/// [at] comes from counting SAMPLES, not from a wall clock — see
/// [PcmAmplitudeMeter]. A detector timed off the scheduler would read a delayed
/// delivery as a sudden silence, which is exactly the shape it is looking for.
@immutable
class AmplitudeSample {
  const AmplitudeSample({required this.level, required this.at});

  /// The same reading written in decibels — the units every constant in this
  /// file is in, and the readable way for a test to write a script.
  factory AmplitudeSample.decibels(double db, Duration at) =>
      AmplitudeSample(level: math.pow(10, db / 20).toDouble(), at: at);

  /// Linear RMS, 0..1, where 1 is full scale.
  final double level;

  final Duration at;

  /// Decibels relative to full scale. Floored rather than allowed to reach
  /// negative infinity: digital silence is a real input (a muted microphone
  /// delivers it forever) and it must be a number the arithmetic can carry.
  double get decibels => 20 * math.log(math.max(level, 1e-9)) / math.ln10;

  @override
  String toString() => 'AmplitudeSample(${decibels.toStringAsFixed(1)}dB @ $at)';
}

/// The transient detector: amplitude in, "look at the board now" out.
///
/// **Impulse versus sustained, and nothing cleverer.** A candidate transient
/// starts when a hop jumps [attackDecibels] over the running room floor from a
/// hop that was still in it; it FIRES if it falls back within
/// [quietDecibels] of that floor inside [decayWindow], and is abandoned if it
/// does not. Dice fit; a voice, a television and a passing car do not, because
/// all three hold their energy for longer than a quarter of a second. That the
/// same test admits a knock at the door is stated in [kDiceDecayWindow] and is
/// the accepted half of the trade.
///
/// The fire is at the END of the transient rather than the start, which is not
/// a detail: the moment worth looking at the board is the moment the dice have
/// come to rest, and it is also the moment the frame gate's own scene-quiet run
/// can begin. See `FrameGate.attend`.
class DiceSoundTrigger {
  DiceSoundTrigger({
    this.attackDecibels = kDiceAttackDecibels,
    this.quietDecibels = kDiceQuietDecibels,
    this.decayWindow = kDiceDecayWindow,
    this.refractory = kDiceRefractory,
    this.floorTimeConstant = kRoomFloorTimeConstant,
    this.minimumDecibels = kDiceFloorDecibels,
  });

  final double attackDecibels;
  final double quietDecibels;
  final Duration decayWindow;
  final Duration refractory;
  final Duration floorTimeConstant;
  final double minimumDecibels;

  double? _floorDb;
  double? _lastDb;
  Duration? _lastAt;
  Duration? _burstStart;
  double _burstFloorDb = 0;
  Duration? _firedAt;
  int _fired = 0;

  /// Hints raised since the last [reset].
  int get fired => _fired;

  /// The running estimate of the room, or null before the first sample. Public
  /// for the tests and for a diagnostics screen; nothing decides on it.
  double? get roomFloorDecibels => _floorDb;

  /// Feeds one reading. True exactly on the hop that completes a transient.
  bool offer(AmplitudeSample sample) {
    final db = sample.decibels;
    final floor = _floorDb;
    if (floor == null) {
      // The first reading is the only estimate of the room there is. Seeding
      // the floor with it rather than with a constant is what lets the detector
      // work in a quiet room and a noisy one without being told which it is in.
      _floorDb = db;
      _lastDb = db;
      _lastAt = sample.at;
      return false;
    }

    var hint = false;
    final burst = _burstStart;
    if (burst != null) {
      if (sample.at - burst > decayWindow) {
        // Still loud a quarter of a second later. Whatever this is, it is not
        // two dice on a board.
        _burstStart = null;
      } else if (db <= _burstFloorDb + quietDecibels) {
        _burstStart = null;
        _firedAt = sample.at;
        _fired++;
        hint = true;
      }
    } else if (_isAttack(db, floor, sample.at)) {
      _burstStart = sample.at;
      // The floor as it was BEFORE the burst, because the running one is about
      // to be dragged upward by the burst itself.
      _burstFloorDb = floor;
    }

    _advanceFloor(db, sample.at);
    _lastDb = db;
    _lastAt = sample.at;
    return hint;
  }

  /// Everything forgotten: the room, the refractory and the count.
  ///
  /// Called when the microphone stops and starts again, because the room on the
  /// other side of that gap is not the room this estimate describes.
  void reset() {
    _floorDb = null;
    _lastDb = null;
    _lastAt = null;
    _burstStart = null;
    _firedAt = null;
    _fired = 0;
  }

  bool _isAttack(double db, double floor, Duration at) {
    final firedAt = _firedAt;
    if (firedAt != null && at - firedAt < refractory) return false;
    // Absolute, not relative: twelve decibels over a very quiet room is still a
    // very quiet sound. See [kDiceFloorDecibels].
    if (db < minimumDecibels) return false;
    // The hop before has to have been IN the room, which is what makes the
    // whole rise sharp rather than merely large — a fade-in reaches the same
    // level without ever passing this.
    if ((_lastDb ?? floor) > floor + quietDecibels) return false;
    return db >= floor + attackDecibels;
  }

  void _advanceFloor(double db, Duration at) {
    final lastAt = _lastAt;
    final dt = lastAt == null ? Duration.zero : at - lastAt;
    // A reading that did not advance the clock cannot advance an estimate that
    // is defined in terms of it. (Streams do deliver out of order across a
    // restart, and a negative dt would move the floor the wrong way.)
    if (dt <= Duration.zero) return;
    final alpha =
        1 - math.exp(-dt.inMicroseconds / floorTimeConstant.inMicroseconds);
    _floorDb = _floorDb! + alpha * (db - _floorDb!);
  }
}

/// Raw 16-bit PCM in, one RMS reading per [hopSamples] out.
///
/// **The clock is the sample count.** Each reading is timestamped at the
/// position of its first sample in the stream, so the detector's windows are
/// measured in audio rather than in delivery: a chunk that arrives late, or two
/// chunks that arrive together, describe exactly the same 16ms hops either way.
///
/// Nothing is retained. A chunk becomes a handful of doubles and is dropped;
/// the only state kept between calls is the part-hop at the end of one chunk
/// and the stray byte of a sample split across two, which is why this is a
/// class rather than a function.
class PcmAmplitudeMeter {
  PcmAmplitudeMeter({
    this.sampleRate = kMicSampleRate,
    this.hopSamples = kAmplitudeHopSamples,
  });

  final int sampleRate;
  final int hopSamples;

  /// Squares accumulated toward the hop in progress.
  double _sum = 0;
  int _count = 0;

  /// Samples emitted, which is also the timestamp of the next hop.
  int _emitted = 0;

  /// The low byte of a sample whose high byte is in the next chunk.
  int? _straggler;

  List<AmplitudeSample> add(Uint8List chunk) {
    final out = <AmplitudeSample>[];
    var i = 0;
    var pending = _straggler;
    _straggler = null;
    while (i < chunk.length) {
      final int low;
      final int high;
      if (pending != null) {
        low = pending;
        pending = null;
        high = chunk[i];
        i += 1;
      } else if (i + 1 < chunk.length) {
        low = chunk[i];
        high = chunk[i + 1];
        i += 2;
      } else {
        _straggler = chunk[i];
        break;
      }
      // Little-endian signed 16-bit, normalized to -1..1.
      var value = (high << 8) | low;
      if (value >= 0x8000) value -= 0x10000;
      final normalized = value / 32768.0;
      _sum += normalized * normalized;
      _count++;
      if (_count == hopSamples) {
        out.add(AmplitudeSample(
          level: math.sqrt(_sum / _count),
          at: Duration(microseconds: _emitted * 1000000 ~/ sampleRate),
        ));
        _emitted += hopSamples;
        _sum = 0;
        _count = 0;
      }
    }
    return out;
  }
}

/// How asking for the microphone ended.
///
/// Four answers rather than a bool, because the SESSION reports which one it
/// got (see the buddy telemetry) and because only one of them is worth
/// remembering: a refusal is the user's answer and is latched into the
/// settings, while "unavailable" is a fact about the device that will be just
/// as true next time without anybody being asked twice.
enum MicOpening {
  /// The microphone is running and hints will follow.
  listening,

  /// The operating system asked the user and the user said no.
  refused,

  /// There is no microphone, no plugin, or the platform refused outright.
  unavailable,
}

/// The microphone, behind three methods — the seam a widget test overrides.
///
/// The same shape as `BuddyCamera`, and for the same reason: everything above
/// this line is arithmetic a desktop can run, and everything below it is a
/// plugin channel that a test process has nothing on the other end of.
abstract interface class MicAmplitudeSource {
  /// Starts listening, asking for permission if it has not been asked yet.
  /// Never throws in normal use; [DiceSoundListener] catches the abnormal case
  /// anyway, because a microphone must not be able to end a match.
  Future<MicOpening> open();

  /// One reading per [kAmplitudeHopSamples] of audio.
  Stream<AmplitudeSample> get amplitudes;

  /// Stops listening and releases the device.
  Future<void> close();
}

/// The microphone on a platform that has none. Mirrors `SilentBuddyTts`, and
/// `NoopAnalytics` before it: every call succeeds, nothing happens, no channel
/// is touched.
@immutable
class SilentMicSource implements MicAmplitudeSource {
  const SilentMicSource();

  @override
  Stream<AmplitudeSample> get amplitudes => const Stream<AmplitudeSample>.empty();

  @override
  Future<MicOpening> open() async => MicOpening.unavailable;

  @override
  Future<void> close() async {}
}

/// Source plus detector plus one callback: the whole of the wiring.
///
/// **The callback is the only thing that leaves this file.** It is
/// `FrameGate.attend` in production and a counter in tests, and nothing about
/// the match is reachable from here — no game state, no session, no phase. A
/// listener that never starts, is refused, or hears nothing calls it zero
/// times, which is precisely what makes the whole feature inert.
class DiceSoundListener {
  DiceSoundListener({
    required this.source,
    required this.onLookNow,
    DiceSoundTrigger? trigger,
  }) : _trigger = trigger ?? DiceSoundTrigger();

  /// Where the numbers come from. A plugin in production, a list in a test.
  final MicAmplitudeSource source;

  /// What a transient is worth: `FrameGate.attend`, and nothing else.
  final VoidCallback onLookNow;

  final DiceSoundTrigger _trigger;

  StreamSubscription<AmplitudeSample>? _amplitudes;
  MicOpening? _state;
  bool _starting = false;

  /// How the microphone answered, or null before it was asked.
  MicOpening? get state => _state;

  /// Hints raised in this listener's lifetime — the count the session reports.
  int get hintsFired => _trigger.fired;

  /// Asks for the microphone once. Repeat calls answer with what the first one
  /// got rather than opening a second device.
  Future<MicOpening> start() async {
    final already = _state;
    if (already != null || _starting) return already ?? MicOpening.unavailable;
    _starting = true;
    try {
      final opening = await source.open();
      _state = opening;
      if (opening == MicOpening.listening) {
        _trigger.reset();
        _amplitudes = source.amplitudes.listen(
          _onSample,
          // A microphone that fails mid-match is a microphone that stops
          // hinting. It is not an error anybody needs to see.
          onError: (Object error) {
            if (kDebugMode) debugPrint('microphone stream failed: $error');
          },
          cancelOnError: true,
        );
      }
      return opening;
    } catch (error) {
      // Broad on purpose. A desktop with no implementation raises a
      // MissingPluginException, a device mid-teardown raises something else,
      // and "there are no hints" is the same answer either way.
      if (kDebugMode) debugPrint('microphone unavailable: $error');
      _state = MicOpening.unavailable;
      return MicOpening.unavailable;
    } finally {
      _starting = false;
    }
  }

  Future<void> stop() async {
    await _amplitudes?.cancel();
    _amplitudes = null;
    try {
      await source.close();
    } catch (error) {
      if (kDebugMode) debugPrint('microphone close failed: $error');
    }
  }

  void _onSample(AmplitudeSample sample) {
    if (_amplitudes == null) return;
    if (_trigger.offer(sample)) onLookNow();
  }
}

// -----------------------------------------------------------------------------
// The plugin edge. Nothing below here runs in `flutter test`.
// -----------------------------------------------------------------------------

/// Whether this platform has a microphone Buddy Mode should reach for.
///
/// The same shape and the same reason as `isBuddySpeechSupportedPlatform` in
/// `speaker.dart`: `defaultTargetPlatform` rather than `dart:io`, so it is
/// overridable in a widget test. Buddy Mode as a whole is mobile-only, so this
/// is not a desktop feature being withheld.
bool get isBuddyMicSupportedPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// [MicAmplitudeSource] over `package:record`.
///
/// Deliberately thin, and deliberately the only untested code in this file: it
/// asks for permission, opens a PCM stream, and pipes it through
/// [PcmAmplitudeMeter]. Every decision — what counts as a transient, how often
/// one may fire, what the room sounds like — is above the edge where a test can
/// reach it.
///
/// **Nothing is recorded.** `startStream` hands over raw samples in memory;
/// each chunk becomes a handful of RMS numbers and is dropped, and no file is
/// ever opened. The three audio-processing options are switched OFF for a
/// reason rather than left at their defaults: automatic gain control, echo
/// cancellation and noise suppression all exist to flatten sudden changes in
/// level, and a sudden change in level is the entire signal this reads.
class RecordMicAmplitudeSource implements MicAmplitudeSource {
  final AudioRecorder _recorder = AudioRecorder();
  final PcmAmplitudeMeter _meter = PcmAmplitudeMeter();
  final StreamController<AmplitudeSample> _out =
      StreamController<AmplitudeSample>.broadcast();

  StreamSubscription<Uint8List>? _pcm;

  @override
  Stream<AmplitudeSample> get amplitudes => _out.stream;

  @override
  Future<MicOpening> open() async {
    if (!isBuddyMicSupportedPlatform) return MicOpening.unavailable;
    // This is the in-context ask: it happens on the game screen, the first time
    // a throw is actually being waited for, so the operating system's dialog
    // arrives with the reason for it on screen behind it.
    if (!await _recorder.hasPermission()) return MicOpening.refused;
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: kMicSampleRate,
      numChannels: 1,
      autoGain: false,
      echoCancel: false,
      noiseSuppress: false,
    ));
    _pcm = stream.listen((chunk) {
      if (_out.isClosed) return;
      for (final sample in _meter.add(chunk)) {
        _out.add(sample);
      }
    });
    return MicOpening.listening;
  }

  @override
  Future<void> close() async {
    await _pcm?.cancel();
    _pcm = null;
    try {
      await _recorder.cancel();
    } catch (_) {
      // Cancelling a recorder the platform already tore down throws, and there
      // is nothing left to release if it does.
    }
    await _recorder.dispose();
    if (!_out.isClosed) await _out.close();
  }
}
