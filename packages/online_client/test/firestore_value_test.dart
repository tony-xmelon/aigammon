import 'package:online_client/online_client.dart';
import 'package:test/test.dart';

void main() {
  group('toFirestoreValue', () {
    test('encodes scalars with the right type wrapper', () {
      expect(toFirestoreValue(null), {'nullValue': null});
      expect(toFirestoreValue(true), {'booleanValue': true});
      expect(toFirestoreValue(3), {'integerValue': '3'});
      expect(toFirestoreValue(2.5), {'doubleValue': 2.5});
      expect(toFirestoreValue('hi'), {'stringValue': 'hi'});
    });

    test('encodes DateTime as an RFC3339 timestampValue in UTC', () {
      final dt = DateTime.utc(2026, 7, 25, 12, 30, 0);
      expect(toFirestoreValue(dt), {'timestampValue': '2026-07-25T12:30:00.000Z'});
    });

    test('encodes nested lists and maps', () {
      final encoded = toFirestoreValue({
        'a': 1,
        'b': [true, 'x'],
      });
      expect(encoded, {
        'mapValue': {
          'fields': {
            'a': {'integerValue': '1'},
            'b': {
              'arrayValue': {
                'values': [
                  {'booleanValue': true},
                  {'stringValue': 'x'},
                ],
              },
            },
          },
        },
      });
    });

    test('throws on an unsupported type', () {
      expect(() => toFirestoreValue(Symbol('nope')), throwsArgumentError);
    });
  });

  group('round-trips', () {
    test('nested map with ints, bools, null, strings, lists', () {
      final original = {
        'type': 'roll',
        'player': 'white',
        'die1': 3,
        'die2': 5,
        'nested': {
          'flag': false,
          'items': [1, 2, 3],
          'nothing': null,
        },
      };
      final decoded = fromFirestoreValue(toFirestoreValue(original));
      expect(decoded, original);
    });

    test('empty list and empty map', () {
      expect(fromFirestoreValue(toFirestoreValue(<Object?>[])), <Object?>[]);
      expect(fromFirestoreValue(toFirestoreValue(<String, Object?>{})),
          <String, Object?>{});
    });

    test('double survives the round trip', () {
      expect(fromFirestoreValue(toFirestoreValue(1.25)), 1.25);
    });

    test('DateTime decodes to the same instant (UTC)', () {
      final dt = DateTime.utc(2026, 1, 2, 3, 4, 5);
      final decoded = fromFirestoreValue(toFirestoreValue(dt)) as DateTime;
      expect(decoded.isUtc, isTrue);
      expect(decoded, dt);
    });

    test('integerValue decodes from a plain int too (emulator quirk safety)',
        () {
      expect(fromFirestoreValue({'integerValue': 7}), 7);
    });
  });

  test('fromFirestoreValue throws on an unknown wrapper', () {
    expect(() => fromFirestoreValue({'weirdValue': 1}), throwsFormatException);
  });

  group('field helpers', () {
    test('encodeFields/decodeFields round-trip a doc field map', () {
      final fields = {'code': 'ABC123', 'seq': 4, 'active': true};
      expect(decodeFields(encodeFields(fields)), fields);
    });
  });
}
