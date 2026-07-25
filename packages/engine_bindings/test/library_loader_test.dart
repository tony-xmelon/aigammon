import 'package:engine_bindings/src/ffi/library_loader.dart';
import 'package:test/test.dart';

/// Pure strategy-selection tests. These never touch real FFI — they only
/// exercise [libraryLoadStrategyFor] with injected platform flags, so they run
/// in the default `dart test` profile with no native library present.
void main() {
  group('libraryLoadStrategyFor', () {
    test('iOS statically links → resolve from process', () {
      expect(
        libraryLoadStrategyFor(isIOS: true, isMacOS: false),
        LibraryLoadStrategy.process,
      );
    });

    test('macOS statically links → resolve from process', () {
      expect(
        libraryLoadStrategyFor(isIOS: false, isMacOS: true),
        LibraryLoadStrategy.process,
      );
    });

    test('Windows/Linux/Android → open a shared library by path', () {
      // Neither Apple flag set is how every non-Apple platform presents.
      expect(
        libraryLoadStrategyFor(isIOS: false, isMacOS: false),
        LibraryLoadStrategy.open,
      );
    });

    test('Apple flags take precedence even if both are set', () {
      // Defensive: real Platform never sets both, but the OR must not regress.
      expect(
        libraryLoadStrategyFor(isIOS: true, isMacOS: true),
        LibraryLoadStrategy.process,
      );
    });
  });
}
