import 'package:aigammon_app/data/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AnimationSpeed.timings preset mapping', () {
    test('off maps to the all-zero preset (disabled)', () {
      final t = AnimationSpeed.off.timings;
      expect(t, AnimationTimings.off);
      expect(t.hop, Duration.zero);
      expect(t.interHop, Duration.zero);
      expect(t.diceFrame, Duration.zero);
      expect(t.diceFrames, 0);
      expect(t.diceSettlePause, Duration.zero);
      expect(t.enabled, isFalse);
    });

    test('normal maps to the trackable default preset', () {
      final t = AnimationSpeed.normal.timings;
      expect(t, AnimationTimings.normal);
      expect(t.hop, const Duration(milliseconds: 350));
      expect(t.interHop, const Duration(milliseconds: 120));
      expect(t.diceFrame, const Duration(milliseconds: 140));
      expect(t.diceFrames, 6);
      expect(t.diceSettlePause, const Duration(milliseconds: 500));
      expect(t.enabled, isTrue);
    });

    test('fast maps to the snappier preset', () {
      final t = AnimationSpeed.fast.timings;
      expect(t, AnimationTimings.fast);
      expect(t.hop, const Duration(milliseconds: 120));
      expect(t.interHop, const Duration(milliseconds: 40));
      expect(t.diceFrame, const Duration(milliseconds: 60));
      expect(t.diceFrames, 5);
      expect(t.diceSettlePause, const Duration(milliseconds: 200));
      expect(t.enabled, isTrue);
    });

    test('fast is strictly snappier than normal across every field', () {
      const fast = AnimationTimings.fast;
      const normal = AnimationTimings.normal;
      expect(fast.hop, lessThan(normal.hop));
      expect(fast.interHop, lessThan(normal.interHop));
      expect(fast.diceFrame, lessThan(normal.diceFrame));
      expect(fast.diceSettlePause, lessThan(normal.diceSettlePause));
    });

    test('diceBeatEnabled tracks the tumbling frames, not the hop travel', () {
      expect(AnimationTimings.off.diceBeatEnabled, isFalse,
          reason: 'speed "None" implies no dice beat');
      expect(AnimationTimings.normal.diceBeatEnabled, isTrue);
      expect(AnimationTimings.fast.diceBeatEnabled, isTrue);
    });

    test('withoutDiceBeat strips the beat and keeps the checker travel', () {
      final t = AnimationTimings.normal.withoutDiceBeat();
      expect(t.diceBeatEnabled, isFalse);
      expect(t.diceFrames, 0);
      expect(t.diceFrame, Duration.zero);
      expect(t.diceSettlePause, Duration.zero,
          reason: 'no beat means nothing to settle from');
      // Checker animation is a separate concern (animationSpeed) and untouched.
      expect(t.hop, AnimationTimings.normal.hop);
      expect(t.interHop, AnimationTimings.normal.interHop);
      expect(t.enabled, isTrue);
    });

    test('AppSettings.timings applies the dice-roll-animation toggle', () {
      // ON by default: the full preset, beat included.
      expect(AppSettings.defaults.diceRollAnimation, isTrue);
      expect(AppSettings.defaults.timings.diceBeatEnabled, isTrue);
      expect(AppSettings.defaults.showPassDevice, isFalse,
          reason: 'the hot-seat cover screen is opt-IN');

      // OFF: same checker pacing, no beat.
      final off =
          AppSettings.defaults.copyWith(diceRollAnimation: false).timings;
      expect(off.diceBeatEnabled, isFalse);
      expect(off.hop, AnimationTimings.normal.hop);
      expect(off, AnimationTimings.normal.withoutDiceBeat());

      // Redundant but harmless with speed "None", which has no beat anyway.
      expect(
        AppSettings.defaults
            .copyWith(animationSpeed: AnimationSpeed.off, diceRollAnimation: false)
            .timings,
        AnimationTimings.off,
      );
    });

    test('AppSettings.timings forwards its animationSpeed preset', () {
      expect(AppSettings.defaults.timings, AnimationTimings.normal);
      expect(
        AppSettings.defaults.copyWith(animationSpeed: AnimationSpeed.off).timings,
        AnimationTimings.off,
      );
      expect(
        AppSettings.defaults
            .copyWith(animationSpeed: AnimationSpeed.fast)
            .timings,
        AnimationTimings.fast,
      );
    });

    test('AnimationTimings has value equality', () {
      expect(
        const AnimationTimings(
          hop: Duration(milliseconds: 350),
          interHop: Duration(milliseconds: 120),
          diceFrame: Duration(milliseconds: 140),
          diceFrames: 6,
          diceSettlePause: Duration(milliseconds: 500),
        ),
        AnimationTimings.normal,
      );
      expect(AnimationTimings.normal, isNot(AnimationTimings.fast));
    });
  });
}
