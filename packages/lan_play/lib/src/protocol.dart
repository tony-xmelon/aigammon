/// The LAN wire protocol: the frames a [MatchTransport] relay carries.
///
/// ## What changed when the referee went away (Plan 17, Task 3)
///
/// This file used to carry an AUTHORITY's vocabulary: a guest `submit`ted an
/// intention, the host validated it, and a `roll_request` asked the host to deal
/// the dice. There is no referee any more — the peer that binds the socket is a
/// dumb RELAY (see [MatchRelay]) and both peers run the same validating
/// controller — so the frames are now exactly the [MatchTransport] surface:
///
///  * [HelloMessage] / [WelcomeMessage] — the room-code handshake, answered with
///    the whole log AND every roll document, which is also the resync path;
///  * [EventMessage] / [RollMessage] — relayed frames (each peer's writes are
///    echoed back to it too, per the transport's at-least-once contract);
///  * the four `write` frames ([WriteEventMessage], [WriteRollMessage],
///    [WriteEntropyMessage], [WriteRevealMessage]) — a guest's optimistic,
///    index-claiming writes, each carrying a correlation [id];
///  * [AckMessage] — the relay's answer to one write, which is what makes
///    `await transport.sendEvent(...)` mean COMMITTED rather than merely "handed
///    to the socket";
///  * [RejectMessage] (handshake refusals), [BusyMessage], [PingMessage],
///    [PongMessage] — unchanged.
///
/// Note what is NOT on the wire: an event's AUTHOR. The relay stamps that from
/// the connection the frame arrived on ([EventFrame.author]), so a guest cannot
/// claim to be the host, and the host's `sideOf` mapping cannot be forged. The
/// same goes for a roll's `roller`.
///
/// Encoding is total; decoding is strict but total as well — see
/// [Envelope.decode]. Nothing a hostile peer sends may throw out of this file.
library;

import 'dart:convert';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:match_transport/match_transport.dart';

/// The wire-protocol version this build speaks. A peer announcing anything else
/// is refused at the handshake (see [ProtocolErrorKind.unsupportedVersion]).
///
/// Bumped to 2 by the relay rewrite: version 1 spoke `submit`/`roll_request` to
/// a host authority that no longer exists, and letting a v1 peer connect would
/// mean a silent stall rather than the honest "different version" refusal.
const int protocolVersion = 2;

/// Hard cap on one frame's text length: a LAN peer is untrusted input, and
/// anything bigger is dropped before it reaches the JSON parser.
///
/// Sized for the biggest LEGITIMATE frame — a `welcome` replaying a whole match
/// log AND its roll documents. One log entry encodes to ~130 bytes and one roll
/// to ~230, and a 7-point match runs to a few hundred of each, so a long match
/// lands in the low hundreds of KB; 512 KB leaves generous headroom without
/// being unbounded. Frame size deliberately does NOT carry the hostile-nesting
/// defence — [maxNestingDepth] does, so the two can be tuned independently.
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

/// Cap on the peer-supplied room code. The host mints four digits; the bound is
/// looser so a later format still fits, but small enough that a code is never a
/// vehicle for bulk data.
const int maxCodeLength = 16;

/// Cap on a reject/ack reason. Enforced on CONSTRUCTION (see [capReason]) as
/// well as on read: a refusal is built from a [ProtocolError] message, and some
/// of those quote peer-supplied text, so capping only on read would let a peer
/// buy an arbitrarily large outbound frame with one small nonsense field — and
/// would then have the honest peer DROP it, losing the `lastSeq` signal too.
const int maxReasonLength = 256;

/// [reason] truncated to [maxReasonLength] code units, so a frame that quotes
/// peer-supplied text stays constant-size. Null in, null out.
///
/// Never splits a surrogate pair: a trailing lone high surrogate is dropped
/// rather than shipped as an unpaired code unit.
String? capReason(String? reason) {
  if (reason == null || reason.length <= maxReasonLength) return reason;
  var end = maxReasonLength;
  final last = reason.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return reason.substring(0, end);
}

/// The most hops one turn can ever have (doubles: four checkers).
const int maxMoveHops = 4;

/// Sanity bound on EVERY integer the wire carries (seq, gameNo, roll index,
/// write id, match length). Nothing legitimate approaches it, and it keeps
/// `double.toInt()` away from its clamping behaviour: `(1e300).toInt()` and
/// `(2^63).toInt()` both silently yield `9223372036854775807`, so an unbounded
/// decoder would turn a nonsense number into a plausible one instead of
/// refusing it.
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
/// wrapping one of these — so a hostile peer cannot crash the relay.
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

/// How the relay answered one write. Maps one-for-one onto the transport's typed
/// errors, so the guest side needs no string matching.
enum AckStatus {
  /// Committed: the frame is in the log and will come back on `inbound`.
  ok,

  /// The index was already taken — [TransportContested]: resync and retry at the
  /// next free one.
  contested,

  /// The relay refused it and an identical retry would fail identically —
  /// [TransportRejected]. Never retry.
  rejected,

  /// A transient failure — [TransportUnavailable].
  unavailable;

  static AckStatus? byName(String name) {
    for (final s in AckStatus.values) {
      if (s.name == name) return s;
    }
    return null;
  }
}

/// A protocol frame: `{v, type, payload?}`.
///
/// Encoding is total; decoding is strict but total as well — see [decode].
sealed class Envelope {
  const Envelope();

  /// The wire discriminator.
  String get type;

  /// Type-specific body, or null for bodyless control frames.
  Map<String, dynamic>? get payload;

  Map<String, dynamic> toJson() => {
        'v': protocolVersion,
        'type': type,
        if (payload != null) 'payload': payload,
      };

  /// The wire text, refusing a frame the PEER would silently drop.
  ///
  /// [maxMessageLength] is enforced on the RECEIVING side by [decode] and by
  /// the two socket readers, all of which simply discard an oversized frame:
  /// no error, no diagnostic, nothing to see. For a `welcome` that is the
  /// worst possible failure — the guest sits out its handshake timeout while
  /// the host believes it answered — and there is no way to tell it apart from
  /// a dead network afterwards.
  ///
  /// The sender is the one end that still knows what it was trying to say, so
  /// the cap is checked HERE too and an oversized frame is refused loudly
  /// rather than emitted to be dropped. Callers on the send path turn this into
  /// a `reject` for the peer (see `HostServer._send`); nothing legitimate
  /// reaches it, because the log and the roll store are both bounded
  /// ([MatchRelay.maxRollIndex]).
  String encode() {
    final raw = jsonEncode(toJson());
    if (raw.length > maxMessageLength) {
      throw ProtocolError(
          ProtocolErrorKind.tooLarge,
          'refusing to send a "$type" frame of ${raw.length} characters: the '
              'peer drops anything over $maxMessageLength');
    }
    return raw;
  }

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
            code: _optString(p, 'code', max: maxCodeLength),
            resume: _optString(p, 'resume', max: maxResumeLength),
          ),
        'welcome' => WelcomeMessage(
            config: _config(p['matchConfig']),
            side: _side(p['side']),
            resume: _optString(p, 'resume', max: maxResumeLength),
            log: _log(p['log']),
            rolls: _rolls(p['rolls']),
          ),
        'event' => EventMessage(_entry(p['entry'])),
        'roll' => RollMessage(_roll(p['roll'])),
        'w_event' => WriteEventMessage(
            id: _positive(p['id'], 'id'),
            seq: _positive(p['seq'], 'seq'),
            gameNo: _positive(p['gameNo'], 'gameNo'),
            event: _event(p['event']),
          ),
        'w_roll' => WriteRollMessage(
            id: _positive(p['id'], 'id'),
            n: _positive(p['n'], 'n'),
            commit: _hex(p, 'commit'),
          ),
        'w_entropy' => WriteEntropyMessage(
            id: _positive(p['id'], 'id'),
            n: _positive(p['n'], 'n'),
            entropy: _hex(p, 'entropy'),
          ),
        'w_reveal' => WriteRevealMessage(
            id: _positive(p['id'], 'id'),
            n: _positive(p['n'], 'n'),
            reveal: _hex(p, 'reveal'),
          ),
        'ack' => AckMessage(
            id: _positive(p['id'], 'id'),
            status: _status(p['status']),
            reason: _optString(p, 'reason', max: maxReasonLength),
            lastSeq: _nonNegative(p['lastSeq'], 'lastSeq'),
          ),
        'reject' => RejectMessage(
            reason: _string(p, 'reason', max: maxReasonLength),
            lastSeq: _nonNegative(p['lastSeq'], 'lastSeq'),
          ),
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

  /// A commit-reveal protocol value: EXACTLY 64 lowercase hex characters (see
  /// `fair_dice.dart`). Checking the shape here means a malformed secret is a
  /// protocol refusal rather than a [FormatException] deep inside a derivation.
  static String _hex(Map<String, dynamic> p, String key) {
    final v = p[key];
    if (v is! String) _bad('$key must be a string');
    if (!isHex64(v)) _bad('$key must be $kHexLength lowercase hex characters');
    return v;
  }

  static String? _optHex(Map<String, dynamic> p, String key) {
    if (p[key] == null) return null;
    return _hex(p, key);
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

  static AckStatus _status(Object? raw) {
    if (raw is! String) _bad('status must be a string');
    return AckStatus.byName(raw) ?? _bad('unknown ack status: $raw');
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

  static List<EventFrame> _log(Object? raw) {
    if (raw is! List) _bad('log must be an array');
    return [for (final e in raw) _entry(e)];
  }

  /// One log entry, AUTHOR included: the relay stamps the author from the
  /// connection, so what travels here is the relay's own attribution, never a
  /// peer's claim about itself.
  static EventFrame _entry(Object? raw) {
    if (raw is! Map<String, dynamic>) _bad('a log entry must be an object');
    return EventFrame(
      seq: _positive(raw['seq'], 'entry.seq'),
      gameNo: _positive(raw['gameNo'], 'entry.gameNo'),
      author: _string(raw, 'author', max: maxNameLength),
      event: _event(raw['event']),
    );
  }

  static List<RollFrame> _rolls(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List) _bad('rolls must be an array');
    return [for (final r in raw) _roll(r)];
  }

  static RollFrame _roll(Object? raw) {
    if (raw is! Map<String, dynamic>) _bad('a roll must be an object');
    return RollFrame(
      n: _positive(raw['n'], 'roll.n'),
      roller: _string(raw, 'roller', max: maxNameLength),
      commit: _hex(raw, 'commit'),
      entropy: _optHex(raw, 'entropy'),
      reveal: _optHex(raw, 'reveal'),
    );
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

// ---------------------------------------------------------------------------
// Encoding helpers for the shared frame types
// ---------------------------------------------------------------------------

/// The wire form of a [MatchConfig] (which is a pure-data type in
/// `match_transport` and deliberately carries no wire concerns of its own).
Map<String, dynamic> configToJson(MatchConfig config) =>
    {'length': config.length, 'cubeless': config.cubeless};

/// The wire form of one log entry.
Map<String, dynamic> entryToJson(EventFrame frame) => {
      'seq': frame.seq,
      'gameNo': frame.gameNo,
      'author': frame.author,
      'event': frame.event.toJson(),
    };

/// The wire form of one roll document at whatever phase it has reached.
Map<String, dynamic> rollToJson(RollFrame frame) => {
      'n': frame.n,
      'roller': frame.roller,
      'commit': frame.commit,
      if (frame.entropy != null) 'entropy': frame.entropy,
      if (frame.reveal != null) 'reveal': frame.reveal,
    };

// ---------------------------------------------------------------------------
// Handshake
// ---------------------------------------------------------------------------

/// guest -> host: open (or resume) the session.
class HelloMessage extends Envelope {
  const HelloMessage({required this.name, this.code, this.resume});

  /// The guest's display name.
  final String name;

  /// The room code shown on the host's screen. OPTIONAL on the wire, but the
  /// socket transport requires it and closes the connection when it is absent or
  /// wrong. See [HostServer].
  final String? code;

  /// A token from a previous [WelcomeMessage]; presenting it asks for a replay
  /// of the existing match rather than a fresh session.
  final String? resume;

  @override
  String get type => 'hello';

  @override
  Map<String, dynamic> get payload => {
        'name': name,
        if (code != null) 'code': code,
        if (resume != null) 'resume': resume,
      };
}

/// host -> guest: accepted; here is the match, your side, and EVERYTHING the
/// relay holds — the whole event log and every roll document.
///
/// One frame answers a first join, a reconnect and a plain resync alike: the
/// guest's transport replaces its mirror with this and tells its controller to
/// replay from scratch (a `ResetFrame`). That is why the relay needs no
/// incremental catch-up protocol.
class WelcomeMessage extends Envelope {
  const WelcomeMessage({
    required this.config,
    required this.side,
    required this.log,
    this.rolls = const [],
    this.resume,
  });

  final MatchConfig config;

  /// The side the guest plays (the host keeps [TransportSession.hostSide]).
  final Player side;

  /// Every event so far, in seq order (may be empty).
  final List<EventFrame> log;

  /// Every roll document so far, ascending by index (may be empty).
  final List<RollFrame> rolls;

  /// The relay's current match identity, echoed back in a later [HelloMessage]
  /// and compared by the controller: a DIFFERENT token means a different match
  /// (the host restarted), which voids every per-match watermark.
  final String? resume;

  @override
  String get type => 'welcome';

  @override
  Map<String, dynamic> get payload => {
        'matchConfig': configToJson(config),
        'side': side.name,
        if (resume != null) 'resume': resume,
        'log': [for (final e in log) entryToJson(e)],
        'rolls': [for (final r in rolls) rollToJson(r)],
      };
}

// ---------------------------------------------------------------------------
// Relayed frames (host -> guest)
// ---------------------------------------------------------------------------

/// host -> guest: one committed log entry, with the relay's own attribution.
class EventMessage extends Envelope {
  const EventMessage(this.entry);

  final EventFrame entry;

  @override
  String get type => 'event';

  @override
  Map<String, dynamic> get payload => {'entry': entryToJson(entry)};
}

/// host -> guest: one roll document, re-sent at each phase it reaches.
class RollMessage extends Envelope {
  const RollMessage(this.roll);

  final RollFrame roll;

  @override
  String get type => 'roll';

  @override
  Map<String, dynamic> get payload => {'roll': rollToJson(roll)};
}

// ---------------------------------------------------------------------------
// Writes (guest -> host) and their acknowledgements
// ---------------------------------------------------------------------------

/// A guest write, carrying the [id] its [AckMessage] will quote.
sealed class WriteMessage extends Envelope {
  const WriteMessage(this.id);

  /// Correlates this write with its acknowledgement. Per-connection, ascending.
  final int id;
}

/// guest -> host: append [event] to the log at [seq].
class WriteEventMessage extends WriteMessage {
  const WriteEventMessage({
    required int id,
    required this.seq,
    required this.gameNo,
    required this.event,
  }) : super(id);

  final int seq;
  final int gameNo;
  final GameEvent event;

  @override
  String get type => 'w_event';

  @override
  Map<String, dynamic> get payload =>
      {'id': id, 'seq': seq, 'gameNo': gameNo, 'event': event.toJson()};
}

/// guest -> host: create roll [n] with the roller's [commit].
class WriteRollMessage extends WriteMessage {
  const WriteRollMessage(
      {required int id, required this.n, required this.commit})
      : super(id);

  final int n;
  final String commit;

  @override
  String get type => 'w_roll';

  @override
  Map<String, dynamic> get payload => {'id': id, 'n': n, 'commit': commit};
}

/// guest -> host: contribute the witness's [entropy] to roll [n].
class WriteEntropyMessage extends WriteMessage {
  const WriteEntropyMessage(
      {required int id, required this.n, required this.entropy})
      : super(id);

  final int n;
  final String entropy;

  @override
  String get type => 'w_entropy';

  @override
  Map<String, dynamic> get payload => {'id': id, 'n': n, 'entropy': entropy};
}

/// guest -> host: publish the roller's [reveal] for roll [n].
class WriteRevealMessage extends WriteMessage {
  const WriteRevealMessage(
      {required int id, required this.n, required this.reveal})
      : super(id);

  final int n;
  final String reveal;

  @override
  String get type => 'w_reveal';

  @override
  Map<String, dynamic> get payload => {'id': id, 'n': n, 'reveal': reveal};
}

/// host -> guest: the answer to write [id].
///
/// Deliberately CONSTANT-SIZE: a status, a bounded reason and the relay's
/// [lastSeq] — never the log. A guest whose fold is behind [lastSeq] knows it has
/// drifted and resyncs (one `hello`); one that is level knows the refusal was
/// about the write itself. Attaching the log here instead would let any peer pull
/// hundreds of KB out of the relay with one small always-invalid frame, forever.
class AckMessage extends Envelope {
  AckMessage({
    required this.id,
    required this.status,
    required this.lastSeq,
    String? reason,
  }) : reason = capReason(reason);

  final int id;
  final AckStatus status;

  /// The last seq the relay has committed; 0 before any event.
  final int lastSeq;

  final String? reason;

  @override
  String get type => 'ack';

  @override
  Map<String, dynamic> get payload => {
        'id': id,
        'status': status.name,
        'lastSeq': lastSeq,
        if (reason != null) 'reason': reason,
      };
}

/// host -> guest: the handshake was refused (bad code, malformed frame).
///
/// Constant-size for the same reason as [AckMessage]; before the welcome it is
/// TERMINAL (retrying a wrong code only burns the brute-force quota).
///
/// [reason] is capped HERE, at construction, and not merely on read. Every
/// refusal is built from a [ProtocolError] message, and several of those quote
/// the offending peer-supplied value verbatim (`unreadable event: ...` carries
/// the peer's `event.type`), so a 100 KB nonsense field would otherwise buy a
/// 100 KB reject — the constant-size invariant gone, and with it the [lastSeq]
/// signal, since a reason longer than [maxReasonLength] is DROPPED by the honest
/// peer's decoder and takes the whole frame with it.
class RejectMessage extends Envelope {
  RejectMessage({required String reason, required this.lastSeq})
      // Never empty: the decoder requires a non-empty string, and dropping a
      // reject would drop [lastSeq] with it.
      : reason = _nonEmpty(capReason(reason));

  static String _nonEmpty(String? reason) =>
      (reason == null || reason.isEmpty) ? 'refused' : reason;

  final String reason;

  /// The last seq the relay has committed; 0 before any event, and always 0 for
  /// a peer that never authenticated.
  final int lastSeq;

  @override
  String get type => 'reject';

  @override
  Map<String, dynamic> get payload => {'reason': reason, 'lastSeq': lastSeq};
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
