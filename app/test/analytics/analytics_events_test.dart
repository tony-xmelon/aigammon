import 'package:aigammon_app/analytics/analytics_events.dart';
import 'package:aigammon_app/analytics/analytics_screen_view.dart';
import 'package:aigammon_app/analytics/app_analytics.dart';
import 'package:engine_bindings/engine_bindings.dart' show Difficulty;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_observability.dart';

/// The event SCHEMA. These assertions are deliberately literal — they spell the
/// wire names out rather than referring to the constants — because the whole
/// point of the constants is that the wire names never move. A test written in
/// terms of `AnalyticsEvents.matchStarted` would happily follow a rename that
/// silently splits the console's history in two.
void main() {
  late RecordingAnalytics analytics;

  setUp(() => analytics = RecordingAnalytics());

  group('event vocabulary', () {
    test('match started, vs the computer, carries every dimension', () {
      analytics.logMatchStarted(
        mode: AnalyticsModes.vsComputer,
        matchLength: 5,
        difficulty: Difficulty.expert,
        cubeless: false,
        tutor: true,
      );

      expect(analytics.names, ['match_started']);
      expect(analytics.paramsOf('match_started'), {
        'mode': 'vsComputer',
        'match_length': 5,
        'difficulty': 'expert',
        'cubeless': false,
        'tutor': true,
      });
    });

    test('match started, hot-seat, reports no difficulty', () {
      analytics.logMatchStarted(
        mode: AnalyticsModes.hotSeat,
        matchLength: 3,
        cubeless: true,
      );

      final params = analytics.paramsOf('match_started');
      expect(params['mode'], 'hotSeat');
      // Present-but-null, not absent: the Firebase implementation is what drops
      // nulls, so "no AI level here" travels as far as the sink boundary.
      expect(params['difficulty'], isNull);
    });

    test('match completed names the winner from the local perspective', () {
      analytics.logMatchCompleted(
        mode: AnalyticsModes.online,
        matchLength: 7,
        localWon: false,
        winnerScore: 7,
        loserScore: 4,
      );

      expect(analytics.paramsOf('match_completed'), {
        'mode': 'online',
        'match_length': 7,
        'winner': 'opponent',
        'score_winner': 7,
        'score_loser': 4,
      });
    });

    test('a shared-device match reports neither side as the winner', () {
      analytics.logMatchCompleted(
        mode: AnalyticsModes.hotSeat,
        matchLength: 1,
        localWon: null,
        winnerScore: 1,
        loserScore: 0,
      );

      expect(analytics.paramsOf('match_completed')['winner'], 'shared_device');
    });

    test('tutor, resign and cube actions', () {
      analytics
        ..logTutorHintUsed(mode: AnalyticsModes.vsComputer)
        ..logResignOffered(mode: AnalyticsModes.lan, value: 'gammon')
        ..logCubeOffered(mode: AnalyticsModes.lan, cubeValue: 2)
        ..logCubeAnswered(
            mode: AnalyticsModes.lan, action: 'drop', cubeValue: 4)
        ..logFeedbackOpened();

      expect(analytics.names, [
        'tutor_hint_used',
        'resign_offered',
        'cube_offered',
        'cube_answered',
        'feedback_opened',
      ]);
      expect(analytics.paramsOf('resign_offered'),
          {'mode': 'lan', 'resign_value': 'gammon'});
      expect(analytics.paramsOf('cube_offered'),
          {'mode': 'lan', 'cube_value': 2});
      expect(analytics.paramsOf('cube_answered'),
          {'mode': 'lan', 'cube_action': 'drop', 'cube_value': 4});
    });
  });

  group('the Buddy vocabulary', () {
    // Literal wire names here, as everywhere in this file: the constants exist
    // so the spellings never move, and a test written in terms of them would
    // follow a rename straight into a split history.

    test('a session start carries every dimension the field tuning needs', () {
      analytics.logBuddySessionStarted(
        matchLength: 5,
        difficulty: 'expert',
        cubeless: false,
        seat: 'near',
        phrasing: 'friendly',
        micHint: true,
      );

      expect(analytics.names, ['buddy_session_started']);
      expect(analytics.paramsOf('buddy_session_started'), {
        'mode': 'buddy',
        'match_length': 5,
        'difficulty': 'expert',
        'cubeless': false,
        'buddy_seat': 'near',
        'buddy_phrasing': 'friendly',
        'mic_hint': true,
      });
    });

    test('the mode says buddy, so the console can ask one question of five',
        () {
      // The vocabulary rule: these strings mirror what MatchRepository already
      // files a Buddy match under, so "matches by mode" answered against the
      // history database and against Firebase agree.
      expect(AnalyticsModes.buddy, 'buddy');
    });

    test('a session end carries the aggregate, not a stream of frames', () {
      analytics.logBuddySessionEnded(
        completed: false,
        readabilityRedRate: 0.125,
        micState: BuddyMicStates.refused,
        micHints: 0,
      );

      expect(analytics.paramsOf('buddy_session_ended'), {
        'mode': 'buddy',
        'buddy_completed': false,
        'readability_red_rate': 0.125,
        'mic_state': 'refused',
        'mic_hints': 0,
      });
    });

    test('calibrations, recalibrations and fallbacks', () {
      analytics
        ..logBuddyCalibration(ok: false, recalibration: false)
        ..logBuddyCalibration(ok: true, recalibration: true)
        ..logBuddyRecalibrationEntered(calibrationLost: true)
        ..logBuddyFallbackUsed(BuddyFallbacks.dicePad)
        ..logBuddyFallbackUsed(BuddyFallbacks.candidatePicker)
        ..logBuddyFallbackUsed(BuddyFallbacks.tapCorrect);

      expect(analytics.names, [
        'buddy_calibration_attempted',
        'buddy_calibration_attempted',
        'buddy_recalibration_entered',
        'buddy_fallback_used',
        'buddy_fallback_used',
        'buddy_fallback_used',
      ]);
      expect(analytics.countOf('buddy_calibration_attempted'), 2);
      expect(analytics.paramsOf('buddy_recalibration_entered'),
          {'calibration_lost': true});
      expect(
        [
          for (final e in analytics.events)
            if (e.name == 'buddy_fallback_used') e.parameters['buddy_fallback']
        ],
        ['dice_pad', 'candidate_picker', 'tap_correct'],
      );
    });

    test('every Buddy vocabulary value is snake_case and distinct', () {
      // These are wire strings that end up as console dimensions, so `dicePad`
      // would be wrong in a way nothing else would ever catch.
      const values = [
        BuddyFallbacks.dicePad,
        BuddyFallbacks.candidatePicker,
        BuddyFallbacks.tapCorrect,
        BuddyMicStates.off,
        BuddyMicStates.unused,
        BuddyMicStates.unavailable,
        BuddyMicStates.refused,
        BuddyMicStates.listening,
      ];
      expect(values.toSet().length, values.length);
      for (final value in values) {
        expect(RegExp(r'^[a-z][a-z_]*$').hasMatch(value), isTrue,
            reason: 'not a wire string: "$value"');
      }
    });
  });

  group('names stay inside Firebase limits', () {
    // Firebase rejects an event or parameter whose name is over 40 chars,
    // starts with a digit or underscore, or contains anything but
    // alphanumerics and underscores — and it rejects it SILENTLY, at ingestion.
    // A custom trace name is capped at 100. Checking the whole vocabulary here
    // is cheaper than discovering one missing event in the console a week after
    // release.
    final valid = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$');

    test('every event and parameter name is legal', () {
      const names = [
        AnalyticsEvents.screenView,
        AnalyticsEvents.matchStarted,
        AnalyticsEvents.matchCompleted,
        AnalyticsEvents.tutorHintUsed,
        AnalyticsEvents.resignOffered,
        AnalyticsEvents.cubeOffered,
        AnalyticsEvents.cubeAnswered,
        AnalyticsEvents.feedbackOpened,
        AnalyticsParams.screenName,
        AnalyticsParams.mode,
        AnalyticsParams.matchLength,
        AnalyticsParams.difficulty,
        AnalyticsParams.cubeless,
        AnalyticsParams.tutor,
        AnalyticsParams.winner,
        AnalyticsParams.scoreWinner,
        AnalyticsParams.scoreLoser,
        AnalyticsParams.resignValue,
        AnalyticsParams.cubeValue,
        AnalyticsParams.cubeAction,
        AnalyticsEvents.buddySessionStarted,
        AnalyticsEvents.buddySessionEnded,
        AnalyticsEvents.buddyCalibrationAttempted,
        AnalyticsEvents.buddyRecalibrationEntered,
        AnalyticsEvents.buddyFallbackUsed,
        AnalyticsParams.buddySeat,
        AnalyticsParams.buddyPhrasing,
        AnalyticsParams.micHint,
        AnalyticsParams.micState,
        AnalyticsParams.micHints,
        AnalyticsParams.buddyCompleted,
        AnalyticsParams.readabilityRedRate,
        AnalyticsParams.calibrationOk,
        AnalyticsParams.recalibration,
        AnalyticsParams.calibrationLost,
        AnalyticsParams.buddyFallback,
      ];
      for (final name in names) {
        expect(valid.hasMatch(name), isTrue, reason: 'illegal name "$name"');
        expect(name.length, lessThanOrEqualTo(40), reason: name);
      }
    });

    test('every trace name is legal', () {
      const traces = [
        PerfTraces.coldStart,
        PerfTraces.engineRankMoves,
        PerfTraces.engineEvaluate,
        PerfTraces.engineCubeInfo,
        PerfTraces.lanConnect,
        PerfTraces.onlineConnect,
      ];
      for (final name in traces) {
        expect(valid.hasMatch(name), isTrue, reason: 'illegal trace "$name"');
        expect(name.length, lessThanOrEqualTo(100), reason: name);
      }
    });

    test('the screen names are distinct and legal', () {
      const screens = [
        AnalyticsScreens.home,
        AnalyticsScreens.newMatch,
        AnalyticsScreens.game,
        AnalyticsScreens.analysis,
        AnalyticsScreens.history,
        AnalyticsScreens.settings,
        AnalyticsScreens.lan,
        AnalyticsScreens.online,
        AnalyticsScreens.diagnostics,
        AnalyticsScreens.buddySetup,
        AnalyticsScreens.buddyCalibration,
        AnalyticsScreens.buddyGame,
      ];
      expect(screens.toSet().length, screens.length);
      for (final name in screens) {
        expect(valid.hasMatch(name), isTrue, reason: 'illegal screen "$name"');
      }
    });
  });

  group('AnalyticsScreenView', () {
    testWidgets('reports once on mount and not again on rebuild', (t) async {
      final notifier = ValueNotifier<int>(0);
      addTearDown(notifier.dispose);

      await t.pumpWidget(ProviderScope(
        overrides: [appAnalyticsProvider.overrideWithValue(analytics)],
        child: MaterialApp(
          home: AnalyticsScreenView(
            name: AnalyticsScreens.settings,
            child: ValueListenableBuilder<int>(
              valueListenable: notifier,
              builder: (_, v, _) => Text('$v', textDirection: TextDirection.ltr),
            ),
          ),
        ),
      ));

      expect(analytics.names, ['screen_view']);
      expect(analytics.paramsOf('screen_view'), {'screen_name': 'settings'});

      // A rebuild of the subtree is not a new visit.
      notifier.value = 1;
      await t.pump();
      expect(analytics.countOf('screen_view'), 1);
    });

    testWidgets('does not require a real analytics backend', (t) async {
      // No override at all: the default provider is the no-op, so any screen
      // can be pumped by a test that has never heard of analytics.
      await t.pumpWidget(const ProviderScope(
        child: MaterialApp(
          home: AnalyticsScreenView(
            name: AnalyticsScreens.home,
            child: SizedBox.shrink(),
          ),
        ),
      ));
      // Mounting without throwing IS the assertion; the finder proves the
      // subtree actually built rather than being silently skipped.
      expect(find.byType(SizedBox), findsOneWidget);
    });
  });
}
