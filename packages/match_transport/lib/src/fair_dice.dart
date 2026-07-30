/// Commit-reveal fair-dice protocol (Plan 16, Task 2).
///
/// Pure Dart, no I/O: this file is the CROSS-CLIENT CONTRACT for how two
/// mutually-distrusting peers agree on a dice roll that neither could bias.
/// The Firestore transport (`matches/{code}/rolls/{n}`) only carries the three
/// hex strings this file produces and consumes; every derivation rule below is
/// normative and must be reimplemented byte-for-byte by any other client.
///
/// ## Protocol
///
/// Per roll, the two peers hold asymmetric roles:
///
/// * the **roller** (the player whose roll it is) picks secret A, publishes
///   `commit = sha256hex(A)`, and later publishes `reveal = A`;
/// * the **witness** (the opponent) sees the commit, publishes its own secret
///   `entropy = B`, and on reveal checks `sha256hex(reveal) == commit`.
///
/// The roller is bound to A before it can see B, and B lands before A is
/// revealed, so neither side can steer the outcome; both then derive the same
/// dice from `sha256(A ‖ B)`.
///
/// Wire shape: `commit`, `entropy` and `reveal` are ALL exactly 64 lowercase
/// hex characters (32 raw bytes) — the same `isHex64` shape the security rules
/// enforce in `firebase/firestore.rules`.
///
/// ## Derivation (normative)
///
/// Let `A` and `B` be the 32 raw bytes of the roller's secret and the witness's
/// entropy respectively, in that order (roller first — ALWAYS, regardless of
/// which player is white/black or who wrote the document first).
///
/// 1. `block₀ = sha256(A ‖ B)` — 32 bytes, over the 64-byte concatenation of
///    the RAW bytes (not the ASCII hex spellings).
/// 2. The **derivation byte stream** is the unbounded sequence
///    `block₀[0..31], block₁[0..31], block₂[0..31], …` where
///    `blockₖ₊₁ = sha256(blockₖ)` (the raw 32-byte digest hashed again).
///    Chaining only ever matters if 32 bytes are exhausted, which needs 32
///    consecutive rejections — probability `(4/256)^32 ≈ 2^-160`.
/// 3. A **die draw** consumes bytes from the stream and rejection-samples:
///    a byte `b` is REJECTED iff `b >= 252` (252 = 6 × 42, so bytes 0..251 map
///    onto the six faces exactly 42 times each — no modulo bias); an accepted
///    byte yields the face `b % 6 + 1`.
/// 4. [diceFrom] draws `die1` then `die2` from that one stream, in order.
/// 5. [openingDiceFrom] draws PAIRS from the same single stream and returns the
///    first pair whose two faces differ, discarding tied pairs entirely (a tie
///    consumes its two draws and the next pair continues from the very next
///    stream byte). This is the reroll-on-tie rule of the opening roll, made
///    deterministic; `whiteDie = die1`, `blackDie = die2`.
///
/// Both peers run the identical derivation, so a roll needs no trusted party
/// and no server-side code.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:crypto/crypto.dart';

/// Length in bytes of a protocol secret (and therefore of every commit).
const int kSecretBytes = 32;

/// Length of the hex spelling of a secret/commit/entropy/reveal.
const int kHexLength = kSecretBytes * 2;

/// Bytes at or above this value are rejected by the die sampler.
///
/// 252 == 6 × 42: the accepted range 0..251 covers each of the six faces
/// exactly 42 times, so `b % 6` is perfectly uniform. Using the full 0..255
/// range instead would over-weight faces 1..4 by ~1.6%.
const int kRejectAtOrAbove = 252;

// ---------------------------------------------------------------------------
// Hex helpers
// ---------------------------------------------------------------------------

const String _hexDigits = '0123456789abcdef';

/// True iff [value] is exactly 64 lowercase hex characters — the shape the
/// Firestore rules require of `commit`, `entropy` and `reveal`.
bool isHex64(String value) {
  if (value.length != kHexLength) return false;
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    final isDigit = c >= 0x30 && c <= 0x39;
    final isLower = c >= 0x61 && c <= 0x66;
    if (!isDigit && !isLower) return false;
  }
  return true;
}

/// Lowercase hex spelling of [bytes].
String bytesToHex(List<int> bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out
      ..write(_hexDigits[(b >> 4) & 0xf])
      ..write(_hexDigits[b & 0xf]);
  }
  return out.toString();
}

/// Raw bytes of a 64-char lowercase-hex string.
///
/// Throws [FormatException] on anything that is not exactly that shape — the
/// protocol never accepts uppercase, short, or odd-length input, so that both
/// peers hash byte-identical material.
Uint8List hex64ToBytes(String hex) {
  if (!isHex64(hex)) {
    throw FormatException(
        'expected $kHexLength lowercase hex characters, got "$hex"');
  }
  final out = Uint8List(kSecretBytes);
  for (var i = 0; i < kSecretBytes; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Secrets and commitments
// ---------------------------------------------------------------------------

/// A fresh 32-byte secret as 64 lowercase hex characters.
///
/// Uses [Random.secure] unless a deterministic [rng] is injected (tests only —
/// NEVER pass a seeded `Random` in production, it would make the secret, and
/// therefore the roll, predictable to the opponent).
String generateSecretHex({Random? rng}) {
  final random = rng ?? Random.secure();
  final bytes = Uint8List(kSecretBytes);
  for (var i = 0; i < kSecretBytes; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytesToHex(bytes);
}

/// The commitment for [secretHex]: `sha256` of the secret's RAW 32 bytes,
/// rendered as 64 lowercase hex characters.
String commitFor(String secretHex) =>
    bytesToHex(sha256.convert(hex64ToBytes(secretHex)).bytes);

/// True iff [revealHex] is the pre-image behind [commitHex].
bool commitMatches(String commitHex, String revealHex) {
  if (!isHex64(commitHex) || !isHex64(revealHex)) return false;
  return commitFor(revealHex) == commitHex;
}

/// Thrown when a revealed secret does not hash to the commitment that was
/// published before the entropy was contributed — i.e. the opponent tried to
/// swap its secret after seeing ours, which is the only way to bias the dice.
///
/// Carries the raw values so the UI/controller can show exactly what failed and
/// freeze the match with evidence.
class FairDiceCheatException implements Exception {
  /// The commitment published in phase 1.
  final String commit;

  /// The secret published in phase 3.
  final String reveal;

  /// `sha256hex(reveal)` — what the commitment WOULD have had to be.
  final String actualCommit;

  /// Roll index (`rolls/{n}`) when known, for the error message.
  final int? rollIndex;

  FairDiceCheatException({
    required this.commit,
    required this.reveal,
    required this.actualCommit,
    this.rollIndex,
  });

  @override
  String toString() {
    final where = rollIndex == null ? '' : ' at roll $rollIndex';
    return 'FairDiceCheatException$where: revealed secret does not match the '
        'commitment (commit=$commit, reveal=$reveal, '
        'sha256(reveal)=$actualCommit)';
  }
}

// ---------------------------------------------------------------------------
// Derivation
// ---------------------------------------------------------------------------

/// The unbounded deterministic byte stream of the derivation (step 2 of the
/// spec at the top of this library): the seed block's bytes, then the bytes of
/// `sha256(previous block)`, and so on.
///
/// Exposed (rather than private) so the sampler can be exercised directly by
/// tests, including the digest-exhaustion path that is unreachable in practice.
class DerivationByteStream {
  Uint8List _block;
  int _index = 0;

  /// Number of blocks consumed beyond the seed block (0 until the seed block's
  /// 32 bytes are exhausted). Diagnostics/tests only.
  int chainDepth = 0;

  DerivationByteStream(List<int> seedBlock)
      : _block = Uint8List.fromList(seedBlock) {
    if (_block.isEmpty) {
      throw ArgumentError('seed block must not be empty');
    }
  }

  /// Seeds from `sha256(secretA ‖ secretB)` over the secrets' raw bytes.
  factory DerivationByteStream.forSecrets(
          String secretAHex, String secretBHex) =>
      DerivationByteStream(sha256
          .convert(<int>[
            ...hex64ToBytes(secretAHex),
            ...hex64ToBytes(secretBHex),
          ])
          .bytes);

  /// The next byte of the stream, chaining to `sha256(block)` when the current
  /// block runs out.
  int nextByte() {
    if (_index == _block.length) {
      _block = Uint8List.fromList(sha256.convert(_block).bytes);
      _index = 0;
      chainDepth++;
    }
    return _block[_index++];
  }
}

/// Draws one die face (1..6) by rejection sampling [nextByte].
///
/// Skips every byte >= [kRejectAtOrAbove]; the first accepted byte `b` yields
/// `b % 6 + 1`.
int sampleDie(int Function() nextByte) {
  while (true) {
    final b = nextByte();
    if (b < kRejectAtOrAbove) return b % 6 + 1;
  }
}

/// The dice for an ordinary roll, derived from the roller's secret
/// [secretAHex] and the witness's entropy [secretBHex].
///
/// Deterministic: same inputs, same dice, on every client. Doubles are possible
/// (as they must be for a normal roll).
Dice diceFrom(String secretAHex, String secretBHex) {
  final stream = DerivationByteStream.forSecrets(secretAHex, secretBHex);
  final die1 = sampleDie(stream.nextByte);
  final die2 = sampleDie(stream.nextByte);
  return Dice(die1, die2);
}

/// The dice for the OPENING roll — the one roll whose two dice must differ,
/// since they decide who plays first ([OpeningRollEvent] rejects ties, and
/// `GameState.opening` rejects doubles).
///
/// Draws successive pairs from the same derivation stream and returns the first
/// pair whose faces differ; tied pairs are discarded (both of their draws are
/// consumed). `die1` is the WHITE die, `die2` the BLACK die.
///
/// This is the classic "reroll on tie" rule made deterministic: because both
/// peers walk the identical stream, both discard the identical ties.
Dice openingDiceFrom(String secretAHex, String secretBHex) {
  final stream = DerivationByteStream.forSecrets(secretAHex, secretBHex);
  while (true) {
    final die1 = sampleDie(stream.nextByte);
    final die2 = sampleDie(stream.nextByte);
    if (die1 != die2) return Dice(die1, die2);
  }
}

// ---------------------------------------------------------------------------
// Role state machines
// ---------------------------------------------------------------------------

/// Phases of a single roll, for both roles.
enum FairDicePhase {
  /// Nothing published yet.
  fresh,

  /// The commitment exists (roller: published it; witness: saw it).
  committed,

  /// The witness's entropy exists.
  entropy,

  /// The secret has been revealed (and, for the witness, verified). Dice ready.
  revealed,
}

/// The roller's side of one roll: commit → accept entropy → reveal → dice.
///
/// Every phase skip throws [StateError]; the session is single-use.
class RollerSession {
  /// Roll index (`rolls/{n}`), carried for error reporting only.
  final int? rollIndex;

  final Random? _rng;
  FairDicePhase _phase = FairDicePhase.fresh;
  String? _secretHex;
  String? _commitHex;
  String? _entropyHex;

  RollerSession({this.rollIndex, Random? rng}) : _rng = rng;

  FairDicePhase get phase => _phase;

  /// The published commitment, once [makeCommit] has run.
  String get commit => _require(_commitHex, 'commit', FairDicePhase.committed);

  /// The opponent's entropy, once [acceptEntropy] has run.
  String get entropy => _require(_entropyHex, 'entropy', FairDicePhase.entropy);

  /// Phase 1 — pick a secret and publish its commitment.
  String makeCommit() {
    if (_phase != FairDicePhase.fresh) {
      throw StateError('makeCommit() already called (phase: ${_phase.name})');
    }
    final secret = generateSecretHex(rng: _rng);
    _secretHex = secret;
    _commitHex = commitFor(secret);
    _phase = FairDicePhase.committed;
    return _commitHex!;
  }

  /// Phase 2 — take the opponent's entropy off the roll document.
  void acceptEntropy(String entropyHex) {
    if (_phase != FairDicePhase.committed) {
      throw StateError(
          'acceptEntropy() requires the committed phase (phase: ${_phase.name})');
    }
    if (!isHex64(entropyHex)) {
      throw FormatException('entropy must be 64 lowercase hex characters',
          entropyHex);
    }
    _entropyHex = entropyHex;
    _phase = FairDicePhase.entropy;
  }

  /// Phase 3 — publish the secret. Returns the reveal value to write.
  String reveal() {
    if (_phase != FairDicePhase.entropy) {
      throw StateError(
          'reveal() requires the entropy phase (phase: ${_phase.name})');
    }
    _phase = FairDicePhase.revealed;
    return _secretHex!;
  }

  /// The derived dice for an ordinary roll. Available after [reveal].
  Dice get dice {
    _requireRevealed('dice');
    return diceFrom(_secretHex!, _entropyHex!);
  }

  /// The derived dice for the opening roll (never a tie). Available after
  /// [reveal]. `die1` is white's die, `die2` black's.
  Dice get openingDice {
    _requireRevealed('openingDice');
    return openingDiceFrom(_secretHex!, _entropyHex!);
  }

  void _requireRevealed(String what) {
    if (_phase != FairDicePhase.revealed) {
      throw StateError('$what requires reveal() first (phase: ${_phase.name})');
    }
  }

  String _require(String? value, String what, FairDicePhase needed) {
    if (value == null) {
      throw StateError('$what is not available yet (phase: ${_phase.name}, '
          'needs ${needed.name})');
    }
    return value;
  }
}

/// The witness's (opponent's) side of one roll: see commit → contribute
/// entropy → verify reveal → dice.
///
/// [verifyReveal] is the ONLY place the protocol can catch a cheating roller;
/// it throws [FairDiceCheatException] with the offending values.
class WitnessSession {
  /// Roll index (`rolls/{n}`), attached to any [FairDiceCheatException].
  final int? rollIndex;

  final Random? _rng;
  FairDicePhase _phase = FairDicePhase.fresh;
  String? _commitHex;
  String? _entropyHex;
  String? _revealHex;

  WitnessSession({this.rollIndex, Random? rng}) : _rng = rng;

  FairDicePhase get phase => _phase;

  /// The roller's commitment, once [seeCommit] has run.
  String get commit => _require(_commitHex, 'commit');

  /// Our own entropy, once [contributeEntropy] has run.
  String get entropy => _require(_entropyHex, 'entropy');

  /// The roller's revealed secret, once [verifyReveal] has accepted it.
  String get reveal => _require(_revealHex, 'reveal');

  /// Phase 1 — observe the roller's commitment.
  void seeCommit(String commitHex) {
    if (_phase != FairDicePhase.fresh) {
      throw StateError('seeCommit() already called (phase: ${_phase.name})');
    }
    if (!isHex64(commitHex)) {
      throw FormatException(
          'commit must be 64 lowercase hex characters', commitHex);
    }
    _commitHex = commitHex;
    _phase = FairDicePhase.committed;
  }

  /// Phase 2 — pick our entropy. Returns the value to write to the roll doc.
  String contributeEntropy() {
    if (_phase != FairDicePhase.committed) {
      throw StateError('contributeEntropy() requires a seen commit '
          '(phase: ${_phase.name})');
    }
    _entropyHex = generateSecretHex(rng: _rng);
    _phase = FairDicePhase.entropy;
    return _entropyHex!;
  }

  /// Phase 3 — check the revealed secret against the commitment.
  ///
  /// Throws [FairDiceCheatException] if `sha256hex(reveal) != commit`.
  void verifyReveal(String revealHex) {
    if (_phase != FairDicePhase.entropy) {
      throw StateError(
          'verifyReveal() requires contributed entropy (phase: ${_phase.name})');
    }
    if (!isHex64(revealHex)) {
      throw FormatException(
          'reveal must be 64 lowercase hex characters', revealHex);
    }
    final actual = commitFor(revealHex);
    if (actual != _commitHex) {
      throw FairDiceCheatException(
        commit: _commitHex!,
        reveal: revealHex,
        actualCommit: actual,
        rollIndex: rollIndex,
      );
    }
    _revealHex = revealHex;
    _phase = FairDicePhase.revealed;
  }

  /// The derived dice for an ordinary roll. Available after [verifyReveal].
  Dice get dice {
    _requireRevealed('dice');
    return diceFrom(_revealHex!, _entropyHex!);
  }

  /// The derived dice for the opening roll (never a tie). Available after
  /// [verifyReveal]. `die1` is white's die, `die2` black's.
  Dice get openingDice {
    _requireRevealed('openingDice');
    return openingDiceFrom(_revealHex!, _entropyHex!);
  }

  void _requireRevealed(String what) {
    if (_phase != FairDicePhase.revealed) {
      throw StateError(
          '$what requires verifyReveal() first (phase: ${_phase.name})');
    }
  }

  String _require(String? value, String what) {
    if (value == null) {
      throw StateError('$what is not available yet (phase: ${_phase.name})');
    }
    return value;
  }
}

// ---------------------------------------------------------------------------
// Folding-side validation
// ---------------------------------------------------------------------------

/// A finished `matches/{code}/rolls/{n}` document: all three protocol values
/// present. Used by the folding side to re-derive what the opponent's
/// [RollEvent] was REQUIRED to say.
class CompletedRoll {
  final String commit;
  final String entropy;
  final String reveal;

  /// Roll index (`rolls/{n}`), when known.
  final int? index;

  CompletedRoll({
    required this.commit,
    required this.entropy,
    required this.reveal,
    this.index,
  }) {
    for (final MapEntry(key: name, value: value) in {
      'commit': commit,
      'entropy': entropy,
      'reveal': reveal,
    }.entries) {
      if (!isHex64(value)) {
        throw FormatException(
            '$name must be 64 lowercase hex characters', value);
      }
    }
  }

  /// Decodes a decoded Firestore field map. Throws [FormatException] if any of
  /// the three protocol fields is missing or malformed (an incomplete roll).
  factory CompletedRoll.fromFields(Map<String, Object?> fields) {
    String field(String name) {
      final v = fields[name];
      if (v is! String) {
        throw FormatException('roll document is missing "$name"', '$fields');
      }
      return v;
    }

    final n = fields['n'];
    return CompletedRoll(
      commit: field('commit'),
      entropy: field('entropy'),
      reveal: field('reveal'),
      index: n is num ? n.toInt() : null,
    );
  }

  /// Throws [FairDiceCheatException] unless `sha256hex(reveal) == commit`.
  void verifyCommit() {
    final actual = commitFor(reveal);
    if (actual != commit) {
      throw FairDiceCheatException(
        commit: commit,
        reveal: reveal,
        actualCommit: actual,
        rollIndex: index,
      );
    }
  }

  /// The dice this roll was bound to produce (ordinary roll).
  Dice get dice => diceFrom(reveal, entropy);

  /// The dice this roll was bound to produce (opening roll; never a tie).
  Dice get openingDice => openingDiceFrom(reveal, entropy);
}

/// True iff [event] carries exactly the dice [roll] derives.
///
/// Verifies the commitment FIRST: a broken commitment is a different (and
/// worse) offence than a mismatched roll, so it throws
/// [FairDiceCheatException] rather than returning `false`. A `false` return
/// means the commit-reveal was sound but the opponent wrote different dice into
/// the event log.
bool diceMatchRoll(CompletedRoll roll, RollEvent event) {
  roll.verifyCommit();
  final derived = roll.dice;
  return event.die1 == derived.die1 && event.die2 == derived.die2;
}

/// True iff [event] carries exactly the opening dice [roll] derives
/// (`whiteDie == die1`, `blackDie == die2`).
///
/// Same commitment semantics as [diceMatchRoll].
bool openingDiceMatchRoll(CompletedRoll roll, OpeningRollEvent event) {
  roll.verifyCommit();
  final derived = roll.openingDice;
  return event.whiteDie == derived.die1 && event.blackDie == derived.die2;
}
