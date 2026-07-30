import 'package:aigammon_app/lan/qr_payload.dart';
import 'package:flutter_test/flutter_test.dart';

/// The QR payload is the only part of Play Nearby that parses input from
/// OUTSIDE the app: a camera pointed at the world sees posters, Wi-Fi codes,
/// receipts and pranks, and every one of them lands in [tryDecodeQrJoin]. So
/// half of this file is round-trips and half is garbage.
void main() {
  group('encode', () {
    test('produces a versioned aigammon join URI', () {
      final text = encodeQrJoin(const QrJoinPayload(
        address: '192.168.1.20',
        port: 47780,
        code: '4271',
      ));
      expect(text, 'aigammon://join?v=1&h=192.168.1.20&p=47780&c=4271');
    });

    test('stays short enough to stay a low-density QR', () {
      final text = encodeQrJoin(const QrJoinPayload(
        address: '255.255.255.255',
        port: 65535,
        code: '9999',
      ));
      expect(text.length, lessThan(80));
    });
  });

  group('round trip', () {
    test('an ordinary LAN target survives', () {
      const payload =
          QrJoinPayload(address: '192.168.1.20', port: 47780, code: '4271');
      expect(tryDecodeQrJoin(encodeQrJoin(payload)), payload);
    });

    test('boundary addresses, ports and codes survive', () {
      const cases = [
        QrJoinPayload(address: '0.0.0.0', port: 1, code: '0000'),
        QrJoinPayload(address: '255.255.255.255', port: 65535, code: '9999'),
        QrJoinPayload(address: '10.0.0.1', port: 47780, code: '0001'),
        // IPv6, in case a future host reports one.
        QrJoinPayload(address: 'fe80::1', port: 8080, code: '1234'),
      ];
      for (final payload in cases) {
        expect(tryDecodeQrJoin(encodeQrJoin(payload)), payload,
            reason: '$payload should round trip');
      }
    });

    test('a shouted (uppercase) encoding still decodes', () {
      // Alphanumeric QR mode is uppercase-only; a scanner may hand back the
      // scheme and host in caps.
      final decoded =
          tryDecodeQrJoin('AIGAMMON://JOIN?v=1&h=192.168.1.20&p=47780&c=4271');
      expect(decoded?.address, '192.168.1.20');
      expect(decoded?.port, 47780);
      expect(decoded?.code, '4271');
    });

    test('a repeated key is LAST wins, and that is pinned on purpose', () {
      // `Uri.queryParameters` keeps the final value. Nothing this app writes
      // repeats a key, so this only ever comes from a hand-made or hostile
      // code — but a future parser must not change the answer by accident.
      expect(
        tryDecodeQrJoin('aigammon://join?v=1&h=1.2.3.4&p=8080&p=1&c=1234')
            ?.port,
        1,
      );
      expect(
        tryDecodeQrJoin(
                'aigammon://join?v=1&h=10.0.0.1&h=10.0.0.2&p=47780&c=1234')
            ?.address,
        '10.0.0.2',
      );
      // And a repeat that makes the LAST value invalid is refused outright,
      // rather than falling back to the earlier good one.
      expect(
        tryDecodeQrJoin('aigammon://join?v=1&h=1.2.3.4&p=47780&p=0&c=1234'),
        isNull,
      );
    });

    test('surrounding whitespace is tolerated', () {
      expect(
        tryDecodeQrJoin('  aigammon://join?v=1&h=10.0.0.4&p=47780&c=1234\n'),
        const QrJoinPayload(address: '10.0.0.4', port: 47780, code: '1234'),
      );
    });
  });

  group('tryDecode is total', () {
    test('null and empty are null, not a throw', () {
      expect(tryDecodeQrJoin(null), isNull);
      expect(tryDecodeQrJoin(''), isNull);
      expect(tryDecodeQrJoin('   '), isNull);
    });

    test('foreign QR content is refused', () {
      const foreign = [
        'https://example.com/join?v=1&h=1.2.3.4&p=47780&c=1234',
        'WIFI:S:MyNetwork;T:WPA;P:hunter2;;',
        'BEGIN:VCARD\nFN:Ada\nEND:VCARD',
        'tel:+15551234567',
        '4271',
        'aigammon://watch?v=1&h=1.2.3.4&p=47780&c=1234',
        'aigammonx://join?v=1&h=1.2.3.4&p=47780&c=1234',
        '://join?v=1&h=1.2.3.4&p=47780&c=1234',
      ];
      for (final text in foreign) {
        expect(tryDecodeQrJoin(text), isNull, reason: text);
      }
    });

    test('a missing or unknown version is refused', () {
      expect(tryDecodeQrJoin('aigammon://join?h=1.2.3.4&p=47780&c=1234'),
          isNull);
      expect(tryDecodeQrJoin('aigammon://join?v=2&h=1.2.3.4&p=47780&c=1234'),
          isNull);
      expect(tryDecodeQrJoin('aigammon://join?v=&h=1.2.3.4&p=47780&c=1234'),
          isNull);
    });

    test('a missing field is refused', () {
      const missing = [
        'aigammon://join?v=1&p=47780&c=1234',
        'aigammon://join?v=1&h=1.2.3.4&c=1234',
        'aigammon://join?v=1&h=1.2.3.4&p=47780',
        'aigammon://join?v=1',
        'aigammon://join',
      ];
      for (final text in missing) {
        expect(tryDecodeQrJoin(text), isNull, reason: text);
      }
    });

    test('an out-of-range or non-numeric port is refused', () {
      for (final port in const ['0', '-1', '65536', '99999999999999999999',
        'x', '', '47780.5', '0x10']) {
        expect(tryDecodeQrJoin('aigammon://join?v=1&h=1.2.3.4&p=$port&c=1234'),
            isNull,
            reason: 'port $port');
      }
    });

    test('a room code that is not four digits is refused', () {
      for (final code in const ['', '123', '12345', 'abcd', '12 4', '１２３４']) {
        expect(
            tryDecodeQrJoin(
                'aigammon://join?v=1&h=1.2.3.4&p=47780&c=${Uri.encodeComponent(code)}'),
            isNull,
            reason: 'code "$code"');
      }
    });

    test('an address outside the address alphabet is refused', () {
      for (final host in const [
        '',
        '../../etc/passwd',
        r'1.2.3.4;rm -rf',
        '1.2.3.4/path',
        'host name',
        'ho\u0000st',
      ]) {
        expect(
            tryDecodeQrJoin(
                'aigammon://join?v=1&h=${Uri.encodeComponent(host)}&p=47780&c=1234'),
            isNull,
            reason: 'host "$host"');
      }
    });

    test('an over-long address is refused', () {
      final long = List.filled(20, '1234').join('.');
      expect(
          tryDecodeQrJoin('aigammon://join?v=1&h=$long&p=47780&c=1234'), isNull);
    });

    test('a huge input is refused without parsing it', () {
      final huge = 'aigammon://join?v=1&h=1.2.3.4&p=47780&c=1234'
          '&pad=${'A' * (maxQrPayloadLength * 20)}';
      expect(tryDecodeQrJoin(huge), isNull);
    });

    test('malformed escapes and control bytes do not throw', () {
      const nasty = [
        'aigammon://join?v=1&h=%ZZ&p=47780&c=1234',
        'aigammon://join?v=1&h=1.2.3.4&p=47780&c=%',
        'aigammon://join?%',
        'aigammon://join?v=1&&&&&',
        'aigammon://[::::]?v=1',
        // Raw control bytes and a replacement character: what a decoder hands
        // back when the symbol was not text at all.
        '\u0000\u0001\uFFFD',
        'aigammon://join?v=1&h=1.2.3.4&p=47780&c=1234\u0000',
      ];
      for (final text in nasty) {
        expect(() => tryDecodeQrJoin(text), returnsNormally, reason: text);
        expect(tryDecodeQrJoin(text), isNull, reason: text);
      }
    });
  });

  group('validRoomCode', () {
    test('accepts exactly four digits', () {
      expect(validRoomCode('0000'), isTrue);
      expect(validRoomCode('4271'), isTrue);
    });

    test('rejects anything else', () {
      for (final code in const ['', '1', '123', '12345', 'abcd', '12.4', ' 123',
        '１２３４']) {
        expect(validRoomCode(code), isFalse, reason: 'code "$code"');
      }
    });
  });
}
