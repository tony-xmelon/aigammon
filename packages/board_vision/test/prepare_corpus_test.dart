import 'dart:convert';
import 'dart:io';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import '../tool/prepare_corpus.dart';
import 'corpus/capture_plan.dart';
import 'corpus/corpus_io.dart';
import 'synthetic/board_renderer.dart';

/// The prep tool stands between a person with a phone and a corpus CI can
/// score, and everything it gets wrong is expensive: a photograph resized twice
/// invalidates hand-tapped corners, a sidecar that does not follow its image
/// makes the corpus lie, and a budget nobody checks is a repository nobody can
/// clone.
///
/// It is driven here with renderer output standing in for photographs — bigger
/// than the corpus allows, so the shrinking is actually exercised.
void main() {
  group('preparing a folder of photographs', () {
    late Directory source;
    late Directory destination;

    setUp(() {
      source = Directory.systemTemp.createTempSync('prep_in');
      destination = Directory.systemTemp.createTempSync('prep_out');
    });

    tearDown(() {
      source.deleteSync(recursive: true);
      destination.deleteSync(recursive: true);
    });

    /// A "photograph" of shot [id], deliberately larger than the corpus allows.
    void photograph(String id, {int width = 2560, int height = 1920}) {
      final shot = renderShot(
        board: BoardState.initial(),
        outWidth: width,
        outHeight: height,
        degradation: kCorpusDegradation,
      );
      File('${source.path}/$id.jpg')
          .writeAsBytesSync(encodeCorpusJpeg(imageOfFrame(shot.frame)));
    }

    test('a photograph is shrunk to the committed size and keeps its shape',
        () {
      photograph('001');
      final report = prepareCorpus(source: source, destination: destination);

      expect(report.written, contains('001'));
      final prepared =
          img.decodeImage(File('${destination.path}/001.jpg').readAsBytesSync())!;
      expect(prepared.width, kMaxCorpusDimension);
      expect(prepared.height, kMaxCorpusDimension * 1920 ~/ 2560);
      expect(prepared.width / prepared.height, closeTo(2560 / 1920, 0.01));
    });

    test('a photograph already small enough is not blown up', () {
      photograph('001', width: 800, height: 600);
      prepareCorpus(source: source, destination: destination);
      final prepared =
          img.decodeImage(File('${destination.path}/001.jpg').readAsBytesSync())!;
      expect(prepared.width, 800);
      expect(prepared.height, 600);
    });

    test('the sidecar comes with it, and is the plan\'s', () {
      photograph('003');
      prepareCorpus(source: source, destination: destination);

      final planned =
          flatten(buildCapturePlan()).firstWhere((s) => s.id == '003');
      final copied = CorpusShot.fromJson(
        jsonDecode(File('${destination.path}/003.expected.json')
            .readAsStringSync()) as Map<String, dynamic>,
      );
      expect(copied.board, planned.board);
      expect(copied.kind, planned.kind);
      expect(copied.calibrateFrom, planned.calibrateFrom);
      expect(copied.replayedBoard, planned.board,
          reason: 'the ground truth still replays through the rules engine');
    });

    test('a shot with no photograph is reported, not invented', () {
      photograph('001');
      final report = prepareCorpus(source: source, destination: destination);
      expect(report.missing.length, 32);
      expect(report.missing, contains('002'));
      expect(File('${destination.path}/002.jpg').existsSync(), isFalse);
      expect(report.summary, contains('32 shots have no photograph'));
    });

    test('it says how big the corpus got, against the budget', () {
      photograph('001');
      final report = prepareCorpus(source: source, destination: destination);
      expect(report.bytes, greaterThan(0));
      expect(report.overBudget, isFalse);
      expect(report.summary, contains('of the budget'));
    });

    test('over budget is a warning with advice, not a silent pass', () {
      photograph('001');
      // The budget is the spec's, so it cannot be lowered to make a point; the
      // report's own arithmetic is what is checked here.
      const huge = PrepareReport(
        written: <String>['001'],
        missing: <String>[],
        needCorners: <String>[],
        bytes: kCorpusByteBudget + 1,
      );
      expect(huge.overBudget, isTrue);
      expect(huge.summary, contains('WARNING'));
      expect(huge.summary, contains('Drop the weakest shots'));
    });
  });

  group('the corners, which are the one thing a person has to do', () {
    late Directory source;
    late Directory destination;

    setUp(() {
      source = Directory.systemTemp.createTempSync('prep_in');
      destination = Directory.systemTemp.createTempSync('prep_out');
      final shot = renderShot(board: BoardState.initial());
      for (final id in const <String>['001', '002']) {
        File('${source.path}/$id.jpg')
            .writeAsBytesSync(encodeCorpusJpeg(imageOfFrame(shot.frame)));
      }
    });

    tearDown(() {
      source.deleteSync(recursive: true);
      destination.deleteSync(recursive: true);
    });

    test('a calibration shot without corners is named, and its sidecar says '
        'so', () {
      final report = prepareCorpus(source: source, destination: destination);
      expect(report.needCorners, <String>['001'],
          reason: 'only the shot its session calibrates from needs them');

      final sidecar = CorpusShot.fromJson(
        jsonDecode(File('${destination.path}/001.expected.json')
            .readAsStringSync()) as Map<String, dynamic>,
      );
      expect(sidecar.corners, isNull,
          reason: 'null is the honest answer, and the harness skips on it');
    });

    test('tapped corners land in the sidecar', () {
      const tapped = BoardQuad(
        topLeft: Pt(120, 88),
        topRight: Pt(1150, 80),
        bottomRight: Pt(1210, 860),
        bottomLeft: Pt(60, 880),
      );
      final report = prepareCorpus(
        source: source,
        destination: destination,
        corners: <String, BoardQuad>{'001': tapped},
      );
      expect(report.needCorners, isEmpty);

      final sidecar = CorpusShot.fromJson(
        jsonDecode(File('${destination.path}/001.expected.json')
            .readAsStringSync()) as Map<String, dynamic>,
      );
      expect(sidecar.corners, tapped);
    });

    test('corners.json round-trips through the reader', () {
      final file = File('${source.path}/corners.json')
        ..writeAsStringSync(jsonEncode(<String, dynamic>{
          '001': <List<double>>[
            <double>[10, 20],
            <double>[900, 15],
            <double>[950, 700],
            <double>[5, 720],
          ],
          '007': null,
        }));
      final corners = readCorners(file);
      expect(corners.keys, <String>['001'],
          reason: 'a null entry is "not done yet", not a quad');
      expect(corners['001']!.topLeft, const Pt(10, 20));
      expect(corners['001']!.bottomLeft, const Pt(5, 720));
    });

    test('a corner list of the wrong length is refused', () {
      final file = File('${source.path}/corners.json')
        ..writeAsStringSync(jsonEncode(<String, dynamic>{
          '001': <List<double>>[
            <double>[10, 20],
            <double>[900, 15],
          ],
        }));
      expect(() => readCorners(file), throwsFormatException);
      expect(() => readFoldingCorners(file), throwsFormatException);
    });

    test('eight points in corners.json are a folding board, four are not', () {
      // One file, one job for the person holding the phone: point at the
      // board. A board that folds needs four more taps — the seams where the
      // hinge meets the far and near edges — so its entry is eight points
      // instead of four, and each reader takes only the entries that are its
      // own.
      final file = File('${source.path}/corners.json')
        ..writeAsStringSync(jsonEncode(<String, dynamic>{
          '001': <List<double>>[
            <double>[10, 20],
            <double>[900, 15],
            <double>[950, 700],
            <double>[5, 720],
            <double>[440, 17],
            <double>[480, 17],
            <double>[450, 710],
            <double>[500, 709],
          ],
          '011': <List<double>>[
            <double>[10, 20],
            <double>[900, 15],
            <double>[950, 700],
            <double>[5, 720],
          ],
        }));

      final folding = readFoldingCorners(file);
      expect(folding.keys, <String>['001'],
          reason: 'a four-point entry is an ordinary board, not a folding one');
      expect(folding['001']!.topLeft, const Pt(10, 20));
      expect(folding['001']!.hingeFarLeft, const Pt(440, 17));
      expect(folding['001']!.hingeNearRight, const Pt(500, 709));

      expect(readCorners(file).keys, <String>['011'],
          reason: 'and the eight-point entry belongs to the other reader, '
              'which is what stops one board being prepared as two');
    });

    test('eight tapped points land in the sidecar, outer four included', () {
      final tapped = foldingCornersOf(
        kFoldingTent,
        barWidth: kFoldingBarWidth,
        aspect: kTopDownHeight / kTopDownWidth,
        principal: const Pt(kFrameWidth / 2, kFrameHeight / 2),
      );
      final report = prepareCorpus(
        source: source,
        destination: destination,
        foldingCorners: <String, FoldingCorners>{'001': tapped},
      );
      expect(report.needCorners, isEmpty,
          reason: 'eight points are more than four, not fewer');

      final sidecar = CorpusShot.fromJson(
        jsonDecode(File('${destination.path}/001.expected.json')
            .readAsStringSync()) as Map<String, dynamic>,
      );
      expect(sidecar.foldingCorners, tapped);
      expect(sidecar.corners, tapped.outer,
          reason: 'the outer four are written too, so anything that only '
              'understands a quad still gets the board\'s outline rather than '
              'a null');
    });

    test('measured board widths land in the sidecar, by session', () {
      // The other thing a person measures off a calibration frame, and the
      // reason it goes through the tool rather than being hand-edited into a
      // sidecar: this tool rewrites every sidecar from the live plan on each
      // run, so anything typed into one directly would be wiped the next time
      // somebody re-prepared the corpus.
      const measured = BoardProportions(trayWidth: 0, barWidth: 0.031);
      prepareCorpus(
        source: source,
        destination: destination,
        proportions: const <String, BoardProportions>{'A-daylight': measured},
      );

      CorpusShot sidecarOf(String id) => CorpusShot.fromJson(
            jsonDecode(File('${destination.path}/$id.expected.json')
                .readAsStringSync()) as Map<String, dynamic>,
          );
      // 001 and 002 are both the A-daylight session, so both carry it: the
      // shape is a property of the board, and a session is one board.
      expect(sidecarOf('001').proportions, measured);
      expect(sidecarOf('001').session, 'A-daylight');
      expect(sidecarOf('002').proportions, measured);
    });

    test('a board that folds carries its eight points and no widths', () {
      // Two answers to one question is the failure being prevented: the eight
      // points already say how wide the hinge is, so a sidecar carrying
      // measured widths as well would leave the harness to pick. Worth a test
      // of its own because the obvious way to write it does not work — passing
      // null to a `copyWith` means "leave it alone", not "clear it", so a
      // session measured before it was tapped as a folding case would have
      // kept both and nothing would have said so.
      const measured = BoardProportions(trayWidth: 0.08, barWidth: 0.08);
      final tapped = foldingCornersOf(
        kFoldingTent,
        barWidth: kFoldingBarWidth,
        aspect: kTopDownHeight / kTopDownWidth,
        principal: const Pt(kFrameWidth / 2, kFrameHeight / 2),
      );
      prepareCorpus(
        source: source,
        destination: destination,
        foldingCorners: <String, FoldingCorners>{'001': tapped},
        proportions: const <String, BoardProportions>{'A-daylight': measured},
      );

      CorpusShot sidecarOf(String id) => CorpusShot.fromJson(
            jsonDecode(File('${destination.path}/$id.expected.json')
                .readAsStringSync()) as Map<String, dynamic>,
          );
      expect(sidecarOf('001').foldingCorners, tapped);
      expect(sidecarOf('001').proportions, isNull,
          reason: 'the eight points derive the widths, so the widths must not '
              'be written beside them');
      // The half of it the tool cannot demonstrate on its own, because the
      // plan never puts widths on a shot: clearing has to be asked for, and
      // asking with a null does nothing at all.
      final measuredShot =
          flatten(buildCapturePlan()).first.copyWith(proportions: measured);
      expect(measuredShot.copyWith(proportions: null).proportions, measured,
          reason: 'null is "leave it alone" in every copyWith, this one '
              'included — which is exactly the trap');
      expect(measuredShot.copyWith(clearProportions: true).proportions, isNull);
      // The other shot of the same session was not tapped as a folding case,
      // so it keeps the session's measurement — which is the discriminator
      // that says this is about the shot's own eight points and not about the
      // measurement being dropped everywhere.
      expect(sidecarOf('002').proportions, measured);
    });

    test('a session nobody measured says so by saying nothing', () {
      prepareCorpus(source: source, destination: destination);
      final sidecar = CorpusShot.fromJson(
        jsonDecode(File('${destination.path}/001.expected.json')
            .readAsStringSync()) as Map<String, dynamic>,
      );
      expect(sidecar.proportions, isNull,
          reason: 'absent means a board of the usual shape, which is what the '
              'harness then reads it as');
    });

    test('proportions.json round-trips through the reader', () {
      final file = File('${source.path}/proportions.json')
        ..writeAsStringSync(jsonEncode(<String, dynamic>{
          'A-daylight': <String, dynamic>{'trayWidth': 0, 'barWidth': 0.031},
          'A-lamp': null,
        }));
      final read = readProportions(file);
      expect(read.keys, <String>['A-daylight'],
          reason: 'a null entry is "not measured yet", not a board');
      expect(read['A-daylight']!.trayWidth, 0);
      expect(read['A-daylight']!.hasTrays, isFalse);
    });

    test('measurements that do not describe a board are refused', () {
      final file = File('${source.path}/proportions.json')
        ..writeAsStringSync(jsonEncode(<String, dynamic>{
          'A-daylight': <String, dynamic>{'trayWidth': 0.45, 'barWidth': 0.2},
        }));
      expect(() => readProportions(file), throwsFormatException);
    });

    test('the template names every shot that still needs tapping', () {
      final template = cornersTemplate(<String>['001', '006', '011']);
      expect(jsonDecode(template), <String, dynamic>{
        '001': null,
        '006': null,
        '011': null,
      });
    });
  });

  group('a prepared corpus is one the harness can read', () {
    test('a prepared synthetic shot decodes and calibrates', () {
      // The end-to-end shape of Task 6: a photograph goes through the prep
      // tool, its corners are tapped, and the harness reads it through exactly
      // the same decode the synthetic corpus uses. Standing in for the
      // photograph with a render is the only part of this that is not real.
      final source = Directory.systemTemp.createTempSync('prep_in');
      final destination = Directory.systemTemp.createTempSync('prep_out');
      addTearDown(() {
        source.deleteSync(recursive: true);
        destination.deleteSync(recursive: true);
      });

      final shot = renderShot(
        board: BoardState.initial(),
        quad: kCorpusSteepQuad,
        degradation: kCorpusDegradation,
      );
      File('${source.path}/001.jpg')
          .writeAsBytesSync(encodeCorpusJpeg(imageOfFrame(shot.frame)));

      prepareCorpus(
        source: source,
        destination: destination,
        // Not resized (1280 already), so the ground-truth quad is still true
        // of the prepared image — which is exactly the property a person
        // reading corners off the prepared jpeg relies on.
        corners: <String, BoardQuad>{'001': shot.groundTruthQuad},
      );

      final sidecar = loadSidecars(destination).firstWhere((s) => s.id == '001');
      final frame = decodeCorpusImage(File('${destination.path}/001.jpg'));
      final result = BoardVision.calibrate(
        frame: frame,
        corners: sidecar.corners!,
        orientation: sidecar.orientation,
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(
        BoardVision(result.calibration!).confirmStartingPosition(frame).agrees,
        isTrue,
      );
    });
  });
}
