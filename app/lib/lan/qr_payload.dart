/// The string a host's QR code carries, and the parser that reads it back.
///
/// Pure Dart on purpose: no `dart:io`, no Flutter, no plugin. The encoder runs
/// on the hosting device, the parser runs on whatever the joining device's
/// camera happened to be pointed at — and those are two very different trust
/// levels, so the parser is the interesting half of this file.
library;

/// The scheme every AIGammon join code starts with.
///
/// A custom scheme (rather than an `https://` deep link) keeps the payload
/// short — a shorter string is a lower-density QR, which a cheap phone camera
/// reads from further away and at worse angles — and makes a foreign QR code
/// fail at the very first character.
const String qrJoinScheme = 'aigammon';

/// The one host segment this app answers to, so a future `aigammon://watch`
/// cannot be mistaken for a join.
const String qrJoinHost = 'join';

/// The payload version.
///
/// Its own number, independent of the app version and of the match protocol's:
/// it changes only when the FIELDS change. A code from a future version decodes
/// to null rather than to a half-understood target, which surfaces as "not an
/// AIGammon code" instead of a connection to nowhere.
const String qrJoinVersion = '1';

/// Longest string the parser will even look at.
///
/// A QR code can carry a few kilobytes, and this runs on whatever the camera
/// saw. Everything valid here is well under 80 characters, so anything past
/// this is not ours and is rejected before any parsing work is done.
const int maxQrPayloadLength = 512;

/// Longest address accepted, which is the longest textual IPv6 address
/// (an IPv4-mapped one, `0000:...:255.255.255.255`).
const int _maxAddressLength = 45;

/// What a joining device needs in order to knock: where the host is, and the
/// four digits that authorise it.
///
/// The same triple the manual-entry form asks a person to type — the QR code is
/// a shortcut past the typing, not a second way in. In particular the room code
/// travels IN the code, which is sound for exactly the reason the spoken code
/// is: possession of it means you were physically in front of the host's
/// screen. It is never broadcast (see `HostBeacon`).
class QrJoinPayload {
  const QrJoinPayload({
    required this.address,
    required this.port,
    required this.code,
  });

  /// The host's address on the LAN, as the host itself reported it.
  final String address;

  /// The TCP port its match server is listening on.
  final int port;

  /// The four-digit room code.
  final String code;

  @override
  bool operator ==(Object other) =>
      other is QrJoinPayload &&
      other.address == address &&
      other.port == port &&
      other.code == code;

  @override
  int get hashCode => Object.hash(address, port, code);

  @override
  String toString() => 'QrJoinPayload($address:$port, code $code)';
}

/// Render [payload] as the string to put in the QR code.
///
/// Shape: `aigammon://join?v=1&h=<address>&p=<port>&c=<code>`. Deliberately
/// built by hand rather than through `Uri`: the field values are already
/// constrained to characters that need no escaping, and a hand-built string
/// keeps the QR's character count (and therefore its module density) minimal
/// and predictable.
String encodeQrJoin(QrJoinPayload payload) =>
    '$qrJoinScheme://$qrJoinHost?v=$qrJoinVersion'
    '&h=${Uri.encodeComponent(payload.address)}'
    '&p=${payload.port}'
    '&c=${Uri.encodeComponent(payload.code)}';

/// Read a scanned string back, or null if it is not one of ours.
///
/// TOTAL: for any input — empty, a URL, a Wi-Fi config, a vCard, a megabyte of
/// binary that happened to decode as text, a well-formed AIGammon URI with a
/// port of 0 — this returns a payload or null, and never throws. That is the
/// contract the scanner depends on: it points a camera at the world and feeds
/// whatever comes back straight in here.
QrJoinPayload? tryDecodeQrJoin(String? raw) {
  if (raw == null) return null;
  final text = raw.trim();
  if (text.isEmpty || text.length > maxQrPayloadLength) return null;
  try {
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    // `Uri` lower-cases the scheme and host when parsing, so a shouted
    // AIGAMMON://JOIN — which is what an uppercase-alphanumeric QR encoding
    // produces — still matches.
    if (uri.scheme != qrJoinScheme) return null;
    if (uri.host != qrJoinHost) return null;

    final params = uri.queryParameters;
    if (params['v'] != qrJoinVersion) return null;

    final address = params['h']?.trim() ?? '';
    if (!_validAddress(address)) return null;

    // Digits first, THEN parse: `int.tryParse` accepts `0x10` (and a leading
    // sign), so a code carrying `p=0x10` would otherwise dial port 16.
    final rawPort = params['p'] ?? '';
    if (rawPort.isEmpty || rawPort.length > 5 || !_allDigits(rawPort)) {
      return null;
    }
    final port = int.tryParse(rawPort);
    if (port == null || port < 1 || port > 65535) return null;

    final code = params['c']?.trim() ?? '';
    if (!validRoomCode(code)) return null;

    return QrJoinPayload(address: address, port: port, code: code);
  } catch (_) {
    // `Uri` is careful, but it is not documented as total over arbitrary text
    // (a malformed percent-escape in the query throws from
    // `queryParameters`, for one). Nothing the camera sees may reach the
    // caller as an exception.
    return null;
  }
}

/// The room-code rule, in one place: exactly four digits.
///
/// Shared with the join form so the typed path and the scanned path cannot
/// drift apart.
bool validRoomCode(String code) => code.length == 4 && _allDigits(code);

/// ASCII digits only — `int.tryParse` is not a digit test (it takes signs,
/// `0x` prefixes and, in other places, underscores), and full-width digits
/// must not pass for the real thing.
bool _allDigits(String text) {
  for (final unit in text.codeUnits) {
    if (unit < 0x30 || unit > 0x39) return false;
  }
  return true;
}

/// Whether [address] is plausibly something to dial.
///
/// Not a full IP parser — `dart:io` does that when the socket is actually
/// opened, and this file stays pure. What it does do is bound the length and
/// restrict the alphabet to what an IPv4 address, an IPv6 address or a hostname
/// can contain, so a scanned code cannot smuggle a shell-ish or path-ish string
/// into the join form.
///
/// `%` is NOT in the alphabet, which does two jobs: it rules out an IPv6 zone
/// index (meaningless on the joining device anyway — zone names are local to the
/// host that named them) and it means a value left un-unescaped by a malformed
/// percent-escape, such as `%ZZ`, is rejected rather than dialled verbatim.
bool _validAddress(String address) {
  if (address.isEmpty || address.length > _maxAddressLength) return false;
  for (final unit in address.codeUnits) {
    final isDigit = unit >= 0x30 && unit <= 0x39;
    final isLower = unit >= 0x61 && unit <= 0x7a;
    final isUpper = unit >= 0x41 && unit <= 0x5a;
    const punctuation = <int>{0x2e, 0x3a, 0x2d}; // . : -
    if (!isDigit && !isLower && !isUpper && !punctuation.contains(unit)) {
      return false;
    }
  }
  return true;
}
