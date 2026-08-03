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
