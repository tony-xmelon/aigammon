import 'package:engine_bindings/src/isolate_error.dart';
import 'package:test/test.dart';

/// `EngineService` registers ONE port for both `addErrorListener` and
/// `addOnExitListener`, so the decoder has to tell a crash from an orderly
/// `dispose()`. Getting that wrong either loses every isolate crash (the whole
/// point of the hook) or reports a crash on every clean shutdown, which trains
/// the user to ignore the diagnostics screen.
void main() {
  test('decodes an error with its stack', () {
    final decoded = decodeIsolateError(['Bad state: boom', '#0 someFrame']);
    expect(decoded, isNotNull);
    expect(decoded!.error, 'Bad state: boom');
    expect(decoded.stack.toString(), contains('someFrame'));
  });

  test('decodes an error whose stack is absent', () {
    final decoded = decodeIsolateError(['Bad state: boom', null]);
    expect(decoded!.error, 'Bad state: boom');
    expect(decoded.stack, isNull);
  });

  test('an empty stack string is treated as no stack', () {
    expect(decodeIsolateError(['boom', ''])!.stack, isNull);
  });

  test('the clean-exit signal is NOT an error', () {
    expect(decodeIsolateError(null), isNull);
  });

  test('a malformed or unexpected message is ignored, not reported', () {
    expect(decodeIsolateError(const []), isNull);
    expect(decodeIsolateError('a bare string'), isNull);
    expect(decodeIsolateError(const [null, '#0 frame']), isNull);
  });
}
