import 'dart:convert';

import 'package:backgammon_core/backgammon_core.dart';

/// The wire-protocol version this build speaks. A peer announcing anything else
/// is refused at the handshake (see [ProtocolErrorKind.unsupportedVersion]).
const int protocolVersion = 1;

/// Hard cap on one frame's text length: a LAN peer is untrusted input, and
/// anything bigger is dropped before it reaches the JSON parser.
///
/// Sized for the biggest LEGITIMATE frame — a `welcome`/`reject` replaying a
/// whole match log. One entry encodes to ~110 bytes and a 3-point match runs to
/// ~300 entries, so a long 7-point match lands in the low hundreds of KB; 512 KB
/// leaves generous headroom without being unbounded. Frame size deliberately
/// does NOT carry the hostile-nesting defence — [maxNestingDepth] does, so the
/// two can be tuned independently.
///
/// Measured in UTF-16 code units, which is never more than the UTF-8 byte
/// length, so this is a conservative byte cap too.
const int maxMessageLength = 512 * 1024;

/// Hard cap on JSON container nesting, checked on the RAW text before parsing.
/// The deepest legitimate frame is 7 levels (frame > payload > log > entry >
/// event > move > hop), so 32 is roomy — while `[[[[...` bombs designed to
/// stress the parser are refused without ever being parsed.
const int maxNestingDepth = 32;

/// Cap on a peer-supplied display name (UI-facing, so bounded).
const int maxNameLength = 64;

/// Cap on a peer-supplied resume token.
const int maxResumeLength = 64;

/// Cap on a peer-supplied reject reason (host-authored, but validated on read).
const int maxReasonLength = 256;

/// The most hops one turn can ever have (doubles: four checkers).
const int maxMoveHops = 4;

/// Sanity bound on EVERY integer the wire carries (seq, gameNo, hops, match
/// length). Nothing legitimate approaches it, and it keeps `double.toInt()`
/// away from its clamping behaviour: `(1e300).toInt()` and `(2^63).toInt()`
/// both silently yield `9223372036854775807`, so an unbounded decoder would
/// turn a nonsense number into a plausible one instead of refusing it.
const int maxIntValue = 1000000000;

/// The largest match length the protocol will carry.
const int maxMatchLength = 99;

/// Why a frame was refused.
enum ProtocolErrorKind {
  /// Longer than [maxMessageLength].
  tooLarge,

  /// Not parseable as JSON, or not a JSON object at the top level.
  malformed,

  /// `v` is missing, not an integer, or not [protocolVersion].
  unsupportedVersion,

  /// `type` is a string but names no known message.
  unknownType,

  /// A field is missing, of the wrong type, or out of range.
  badField,
}

/// A refused frame. Decoding NEVER throws — it returns [DecodeFailure]
/// wrapping one of these — so a hostile peer cannot crash the host.
class ProtocolError implements Exception {
  const ProtocolError(this.kind, this.message);

  final ProtocolErrorKind kind;
  final String message;

  @override
  String toString() => 'ProtocolError(${kind.name}): $message';
}

/// The result of [Envelope.decode].
sealed class DecodeResult {
  const DecodeResult();
}

class DecodeOk extends DecodeResult {
  const DecodeOk(this.envelope);
  final Envelope envelope;
}

class DecodeFailure extends DecodeResult {
  const DecodeFailure(this.error);
  final ProtocolError error;
}

/// The match parameters the host fixes and the guest adopts.
class MatchConfig {
  const MatchConfig({required this.length, this.cubeless = false});

  final int length;
  final bool cubeless;

  Map<String, dynamic> toJson() => {'length': length, 'cubeless': cubeless};

  @override
  bool operator ==(Object other) =>
      other is MatchConfig &&
      other.length == length &&
      other.cubeless == cubeless;

  @override
  int get hashCode => Object.hash(length, cubeless);

  @override
  String toString() => 'MatchConfig(length: $length, cubeless: $cubeless)';
}

/// One entry of the host's append-only log: a [GameEvent] stamped with its
/// match-wide [seq] and the [gameNo] it belongs to.
///
/// Deliberately shaped like `online_client`'s `RemoteEvent` so a guest
/// controller folds a LAN stream exactly as it folds the Firestore stream.
class LogEntry {
  const LogEntry({
    required this.seq,
    required this.gameNo,
    required this.event,
  });

  /// Strictly monotonic across the whole match, starting at 1.
  final int seq;

  /// 1-based game number within the match.
  final int gameNo;

  final GameEvent event;

  Map<String, dynamic> toJson() =>
      {'seq': seq, 'gameNo': gameNo, 'event': event.toJson()};

  @override
  String toString() => 'LogEntry($seq, game $gameNo, ${event.toJson()})';
}

/// A protocol frame: `{v, type, seq?, payload?}`.
///
/// Encoding is total; decoding is strict but total as well — see [decode].
sealed class Envelope {
  const Envelope();

  /// The wire discriminator.
  String get type;

  /// Envelope-level sequence number; only [EventMessage] carries one.
  int? get seq => null;

  /// Type-specific body, or null for bodyless control frames.
  Map<String, dynamic>? get payload;

  Map<String, dynamic> toJson() => {
        'v': protocolVersion,
        'type': type,
        if (seq != null) 'seq': seq,
        if (payload != null) 'payload': payload,
      };

  String encode() => jsonEncode(toJson());

  /// Parse one frame. Returns [DecodeOk] or [DecodeFailure]; never throws.
  ///
  /// Unknown FIELDS are ignored (forward compatibility); unknown TYPES,
  /// wrong versions, wrong field types and oversized frames are refused.
  static DecodeResult decode(String raw) {
    try {
      if (raw.length > maxMessageLength) {
        throw ProtocolError(ProtocolErrorKind.tooLarge,
            'frame of ${raw.length} exceeds $maxMessageLength');
      }
      _checkNesting(raw);
      final Object? parsed;
      try {
        parsed = jsonDecode(raw);
      } catch (_) {
        throw const ProtocolError(
            ProtocolErrorKind.malformed, 'not valid JSON');
      }
      if (parsed is! Map<String, dynamic>) {
        throw const ProtocolError(
            ProtocolErrorKind.malformed, 'frame is not a JSON object');
      }
      final version = parsed['v'];
      if (version is! int) {
        throw ProtocolError(ProtocolErrorKind.unsupportedVersion,
            'missing or non-integer version: $version');
      }
      if (version != protocolVersion) {
        throw ProtocolError(ProtocolErrorKind.unsupportedVersion,
            'unsupported protocol version $version (this build speaks '
            '$protocolVersion)');
      }
      final type = parsed['type'];
      if (type is! String) {
        throw const ProtocolError(
            ProtocolErrorKind.badField, 'missing or non-string type');
      }
      final rawPayload = parsed['payload'];
      if (rawPayload != null && rawPayload is! Map<String, dynamic>) {
        throw const ProtocolError(
            ProtocolErrorKind.badField, 'payload is not an object');
      }
      final p = (rawPayload as Map<String, dynamic>?) ?? const {};

      return DecodeOk(switch (type) {
        'hello' => HelloMessage(
            name: _string(p, 'name', max: maxNameLength),
            resume: _optString(p, 'resume', max: maxResumeLength),
          ),
        'welcome' => WelcomeMessage(
            config: _config(p['matchConfig']),
            side: _side(p['side']),
            resume: _optString(p, 'resume', max: maxResumeLength),
            log: _log(p['log']),
          ),
        'event' => EventMessage(LogEntry(
            seq: _positive(parsed['seq'], 'seq'),
            gameNo: _positive(p['gameNo'], 'gameNo'),
            event: _event(p['event']),
          )),
        'submit' => SubmitMessage(_event(p['event'])),
        'reject' => RejectMessage(
            reason: _string(p, 'reason', max: maxReasonLength),
            lastSeq: _nonNegative(p['lastSeq'], 'lastSeq'),
          ),
        'roll_request' => const RollRequestMessage(),
        'busy' => const BusyMessage(),
        'ping' => const PingMessage(),
        'pong' => const PongMessage(),
        _ => throw ProtocolError(
            ProtocolErrorKind.unknownType, 'unknown message type: $type'),
      });
    } on ProtocolError catch (e) {
      return DecodeFailure(e);
    } catch (e) {
      // Belt and braces: no parser surprise (RangeError, StackOverflowError on
      // a pathological nesting, ...) may escape as a throw.
      return DecodeFailure(
          ProtocolError(ProtocolErrorKind.malformed, 'unreadable frame: $e'));
    }
  }

  // --- strict field helpers (all throw ProtocolError) ------------------------

  /// Refuse absurdly nested text before the parser sees it. Scans the raw
  /// frame once, skipping string literals (and their escapes) so brackets
  /// inside a display name cannot trip it.
  static void _checkNesting(String raw) {
    const quote = 0x22, backslash = 0x5C;
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = 0; i < raw.length; i++) {
      final c = raw.codeUnitAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == backslash) {
          escaped = true;
        } else if (c == quote) {
          inString = false;
        }
        continue;
      }
      switch (c) {
        case quote:
          inString = true;
        case 0x5B: // [
        case 0x7B: // {
          if (++depth > maxNestingDepth) {
            throw ProtocolError(ProtocolErrorKind.malformed,
                'nesting deeper than $maxNestingDepth');
          }
        case 0x5D: // ]
        case 0x7D: // }
          depth--;
      }
    }
  }

  static Never _bad(String message) =>
      throw ProtocolError(ProtocolErrorKind.badField, message);

  static String _string(Map<String, dynamic> p, String key,
      {required int max}) {
    final v = p[key];
    if (v is! String || v.isEmpty) _bad('$key must be a non-empty string');
    if (v.length > max) _bad('$key exceeds $max characters');
    return v;
  }

  static String? _optString(Map<String, dynamic> p, String key,
      {required int max}) {
    if (p[key] == null) return null;
    return _string(p, key, max: max);
  }

  /// An integer, tolerating the integral doubles a JSON encoder may emit, and
  /// bounded by [maxIntValue] in both directions — see that constant for why an
  /// unbounded version silently accepts 1e300.
  static int _int(Object? v, String what) {
    if (v is int) {
      if (v.abs() > maxIntValue) _bad('$what is out of range: $v');
      return v;
    }
    if (v is double) {
      // Note the order: the range check runs BEFORE toInt(), which is the
      // operation that would clamp.
      if (!v.isFinite || v != v.roundToDouble() || v.abs() > maxIntValue) {
        _bad('$what must be an integer in +/-$maxIntValue');
      }
      return v.toInt();
    }
    _bad('$what must be an integer');
  }

  static int _positive(Object? v, String what) {
    final n = _int(v, what);
    if (n < 1) _bad('$what must be >= 1');
    return n;
  }

  /// A counter that may legitimately be zero (a log that is still empty).
  static int _nonNegative(Object? v, String what) {
    final n = _int(v, what);
    if (n < 0) _bad('$what must be >= 0');
    return n;
  }

  static MatchConfig _config(Object? raw) {
    if (raw is! Map<String, dynamic>) _bad('matchConfig must be an object');
    final m = raw;
    final length = _int(m['length'], 'matchConfig.length');
    if (length < 1 || length > maxMatchLength) {
      _bad('matchConfig.length must be 1..$maxMatchLength');
    }
    final cubeless = m['cubeless'];
    if (cubeless is! bool) _bad('matchConfig.cubeless must be a boolean');
    return MatchConfig(length: length, cubeless: cubeless);
  }

  static Player _side(Object? raw) => switch (raw) {
        'white' => Player.white,
        'black' => Player.black,
        _ => _bad('side must be "white" or "black"'),
      };

  static List<LogEntry> _log(Object? raw) {
    if (raw is! List) _bad('log must be an array');
    return [
      for (final e in raw)
        if (e is! Map<String, dynamic>)
          _bad('log entries must be objects')
        else
          LogEntry(
            seq: _positive(e['seq'], 'log[].seq'),
            gameNo: _positive(e['gameNo'], 'log[].gameNo'),
            event: _event(e['event']),
          ),
    ];
  }

  /// A [GameEvent], validated for shape BEFORE handing it to the core codec so
  /// no core exception (FormatException, RangeError, ArgumentError) escapes.
  static GameEvent _event(Object? raw) {
    if (raw is! Map<String, dynamic>) _bad('event must be an object');
    final m = raw;
    if (m['type'] is! String) _bad('event.type must be a string');
    if (m['type'] == 'move') {
      final hops = m['move'];
      if (hops is! List) _bad('event.move must be an array of hops');
      if (hops.length > maxMoveHops) {
        _bad('event.move has more than $maxMoveHops hops');
      }
      for (final h in hops) {
        if (h is! List || h.length != 3) _bad('a hop must be [from, to, hit]');
        _int(h[0], 'hop.from');
        _int(h[1], 'hop.to');
        if (h[2] is! bool) _bad('hop.hit must be a boolean');
      }
    }
    try {
      return GameEvent.fromJson(m);
    } catch (e) {
      _bad('unreadable event: $e');
    }
  }
}

/// guest -> host: open (or resume) the session.
class HelloMessage extends Envelope {
  const HelloMessage({required this.name, this.resume});

  /// The guest's display name.
  final String name;

  /// A token from a previous [WelcomeMessage]; presenting it asks for a replay
  /// of the existing match rather than a fresh session.
  final String? resume;

  @override
  String get type => 'hello';

  @override
  Map<String, dynamic> get payload =>
      {'name': name, if (resume != null) 'resume': resume};
}

/// host -> guest: accepted; here is the match, your side, and the log so far.
class WelcomeMessage extends Envelope {
  const WelcomeMessage({
    required this.config,
    required this.side,
    required this.log,
    this.resume,
  });

  final MatchConfig config;

  /// The side the guest plays.
  final Player side;

  /// Every event so far, in seq order (may be empty).
  final List<LogEntry> log;

  /// Token to present in a later [HelloMessage] to resume this session.
  final String? resume;

  @override
  String get type => 'welcome';

  @override
  Map<String, dynamic> get payload => {
        'matchConfig': config.toJson(),
        'side': side.name,
        if (resume != null) 'resume': resume,
        'log': [for (final e in log) e.toJson()],
      };
}

/// host -> peers: one authoritative log entry.
class EventMessage extends Envelope {
  const EventMessage(this.entry);

  final LogEntry entry;

  @override
  String get type => 'event';

  @override
  int? get seq => entry.seq;

  @override
  Map<String, dynamic> get payload =>
      {'gameNo': entry.gameNo, 'event': entry.event.toJson()};
}

/// guest -> host: an intended event for the guest's own side.
class SubmitMessage extends Envelope {
  const SubmitMessage(this.event);

  final GameEvent event;

  @override
  String get type => 'submit';

  @override
  Map<String, dynamic> get payload => {'event': event.toJson()};
}

/// host -> guest: a submission was refused.
///
/// Deliberately CONSTANT-SIZE: it carries the reason and the host's [lastSeq],
/// never the log. A guest whose [lastSeq] is behind knows it has drifted and
/// resyncs by sending `hello` again (which answers with the full log); one that
/// is level knows the refusal was about the submission itself, not about
/// divergence. Attaching the log here instead would let any peer pull hundreds
/// of KB out of the host with one small always-invalid frame, forever.
class RejectMessage extends Envelope {
  const RejectMessage({required this.reason, required this.lastSeq});

  final String reason;

  /// The last seq the host has assigned; 0 before any event.
  final int lastSeq;

  @override
  String get type => 'reject';

  @override
  Map<String, dynamic> get payload => {'reason': reason, 'lastSeq': lastSeq};
}

/// guest -> host: "roll for me" (dice are host-authoritative).
class RollRequestMessage extends Envelope {
  const RollRequestMessage();

  @override
  String get type => 'roll_request';

  @override
  Map<String, dynamic>? get payload => null;
}

/// host -> guest: a match is already in progress with another guest.
class BusyMessage extends Envelope {
  const BusyMessage();

  @override
  String get type => 'busy';

  @override
  Map<String, dynamic>? get payload => null;
}

class PingMessage extends Envelope {
  const PingMessage();

  @override
  String get type => 'ping';

  @override
  Map<String, dynamic>? get payload => null;
}

class PongMessage extends Envelope {
  const PongMessage();

  @override
  String get type => 'pong';

  @override
  Map<String, dynamic>? get payload => null;
}
