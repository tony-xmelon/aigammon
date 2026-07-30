import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:crypto/crypto.dart';
import 'package:match_transport/match_transport.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Independent re-implementation of the derivation.
//
// Written from the SPEC PROSE in fair_dice.dart, deliberately structured
// differently from the production code: it materialises accepted faces eagerly
// into a list (block by block) instead of pulling a lazy stream, and parses hex
// with its own loop. Every derivation assertion below is cross-checked against
// this path, so a typo in either implementation shows up as a failure.
// ---------------------------------------------------------------------------

List<int> _parseHex(String hex) => [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];

/// The first [wanted] accepted faces of the derivation stream for the pair.
List<int> _independentFaces(String aHex, String bHex, int wanted) {
  var block = sha256.convert([..._parseHex(aHex), ..._parseHex(bHex)]).bytes;
  final faces = <int>[];
  var blocks = 0;
  while (faces.length < wanted) {
    for (final byte in block) {
      if (byte < 252) faces.add(byte % 6 + 1);
      if (faces.length == wanted) break;
    }
    if (faces.length < wanted) {
      block = sha256.convert(block).bytes;
      if (++blocks > 64) throw StateError('derivation failed to terminate');
    }
  }
  return faces;
}

Dice _independentDice(String aHex, String bHex) {
  final f = _independentFaces(aHex, bHex, 2);
  return Dice(f[0], f[1]);
}

Dice _independentOpeningDice(String aHex, String bHex) {
  for (var pairs = 1;; pairs++) {
    final f = _independentFaces(aHex, bHex, 2 * pairs);
    final die1 = f[2 * pairs - 2];
    final die2 = f[2 * pairs - 1];
    if (die1 != die2) return Dice(die1, die2);
    if (pairs > 64) throw StateError('opening derivation failed to terminate');
  }
}

String _counterSecret(String tag, int i) =>
    bytesToHex(sha256.convert('$tag$i'.codeUnits).bytes);

// ---------------------------------------------------------------------------
// Fixed vectors.
//
// Derivations shown so a future reader (or another client's author) can redo
// them by hand:
//
//   A = 0011..eeff, B = ffee..1100
//   sha256(A‖B) = 900d2b5d8c0cb7030d67e140d41568b715c5bacee9e5e6867d20df04661b8451
//   byte 0 = 0x90 = 144 → accepted (<252) → 144 % 6 + 1 = 1
//   byte 1 = 0x0d =  13 → accepted        →  13 % 6 + 1 = 2   ⇒ dice 1-2
//   1 ≠ 2, so the opening variant returns the same pair.
//
//   Z = 32 zero bytes, O = 32 × 0x11
//   sha256(Z‖O) = 8878b15a7d6a3a4f464e8f9f42591dbc0cf4bedea0ec309003d2b2ee53655ef8
//   byte 0 = 0x88 = 136 → 136 % 6 + 1 = 5
//   byte 1 = 0x78 = 120 → 120 % 6 + 1 = 1                     ⇒ dice 5-1
// ---------------------------------------------------------------------------

const _a = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
const _b = 'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';
const _zeros =
    '0000000000000000000000000000000000000000000000000000000000000000';
const _ones = '1111111111111111111111111111111111111111111111111111111111111111';

/// sha256(A‖B), for the by-hand derivation above.
const _seedAB =
    '900d2b5d8c0cb7030d67e140d41568b715c5bacee9e5e6867d20df04661b8451';

/// Paired with [_b] this yields a seed starting 0xff (255) — the first byte is
/// REJECTED (255 >= 252), so die1 comes from the second byte. Found by scanning
/// counter-varied secrets; see the rejection-sampling group.
const _rejectSecret =
    '01a7fd256dd778b49ffc4772def39856722a87bf05ad9175c2c557207c943988';

/// Paired with [_b] this yields a DOUBLE (2-2) for an ordinary roll, so the
/// opening variant must discard that pair and draw the next one (2-3).
const _tieSecret =
    '61b73551033d27dab53b171b5c5aa25971c3a262f7b28cbff1c3aed4dea67acb';

void main() {
  group('hex helpers', () {
    test('isHex64 accepts exactly 64 lowercase hex characters', () {
      expect(isHex64(_a), isTrue);
      expect(isHex64(_zeros), isTrue);
      expect(isHex64('f' * 64), isTrue);
    });

    test('isHex64 rejects wrong length, uppercase and non-hex', () {
      expect(isHex64('a' * 63), isFalse);
      expect(isHex64('a' * 65), isFalse);
      expect(isHex64(''), isFalse);
      expect(isHex64('A' * 64), isFalse, reason: 'uppercase is not the shape');
      expect(isHex64(_a.replaceRange(0, 1, 'A')), isFalse);
      expect(isHex64('g' * 64), isFalse);
      expect(isHex64('${'a' * 63} '), isFalse);
    });

    test('hex64ToBytes/bytesToHex round-trip', () {
      final bytes = hex64ToBytes(_a);
      expect(bytes, hasLength(kSecretBytes));
      expect(bytes.first, 0x00);
      expect(bytes[1], 0x11);
      expect(bytes.last, 0xff);
      expect(bytesToHex(bytes), _a);
      expect(hex64ToBytes(_zeros), everyElement(0));
    });

    test('hex64ToBytes rejects anything not 64 lowercase hex', () {
      expect(() => hex64ToBytes('ABC'), throwsFormatException);
      expect(() => hex64ToBytes(_a.toUpperCase()), throwsFormatException);
      expect(() => hex64ToBytes('a' * 62), throwsFormatException);
    });
  });

  group('secrets and commitments', () {
    test('generateSecretHex produces the 64-hex wire shape', () {
      for (var i = 0; i < 32; i++) {
        expect(isHex64(generateSecretHex()), isTrue);
      }
    });

    test('generateSecretHex is not repetitive', () {
      final seen = {for (var i = 0; i < 64; i++) generateSecretHex()};
      expect(seen, hasLength(64));
    });

    test('commitFor hashes the RAW bytes, not the ascii hex', () {
      // sha256 of 32 zero bytes is a well-known value; sha256 of the ASCII
      // string "000...0" is a different one. Getting this wrong would be an
      // invisible cross-client incompatibility.
      expect(commitFor(_zeros),
          '66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925');
      expect(commitFor(_zeros),
          isNot(bytesToHex(sha256.convert(_zeros.codeUnits).bytes)));
      expect(commitFor(_a),
          bytesToHex(sha256.convert(_parseHex(_a)).bytes));
    });

    test('commitFor output is itself the 64-hex wire shape', () {
      expect(isHex64(commitFor(_a)), isTrue);
      expect(isHex64(commitFor(generateSecretHex())), isTrue);
    });

    test('commitMatches accepts the pre-image and nothing else', () {
      expect(commitMatches(commitFor(_a), _a), isTrue);
      expect(commitMatches(commitFor(_a), _b), isFalse);
      expect(commitMatches('nope', _a), isFalse);
      expect(commitMatches(commitFor(_a), 'nope'), isFalse);
    });

    test('commitFor rejects malformed secrets', () {
      expect(() => commitFor('deadbeef'), throwsFormatException);
    });
  });

  group('derivation — fixed vectors', () {
    test('seed block matches the documented sha256(A‖B)', () {
      expect(bytesToHex(sha256.convert([..._parseHex(_a), ..._parseHex(_b)]).bytes),
          _seedAB);
    });

    test('diceFrom(A, B) == 1-2, cross-checked independently', () {
      expect(diceFrom(_a, _b), Dice(1, 2));
      expect(diceFrom(_a, _b), _independentDice(_a, _b));
    });

    test('diceFrom(Z, O) == 5-1, cross-checked independently', () {
      expect(diceFrom(_zeros, _ones), Dice(5, 1));
      expect(diceFrom(_zeros, _ones), _independentDice(_zeros, _ones));
    });

    test('openingDiceFrom(A, B) == 1-2 (already distinct)', () {
      expect(openingDiceFrom(_a, _b), Dice(1, 2));
      expect(openingDiceFrom(_a, _b), _independentOpeningDice(_a, _b));
    });

    test('argument order matters — the roller secret always comes first', () {
      expect(diceFrom(_b, _a), Dice(5, 5));
      expect(diceFrom(_b, _a), isNot(diceFrom(_a, _b)));
      expect(diceFrom(_b, _a), _independentDice(_b, _a));
    });

    test('derivation is deterministic across repeated calls', () {
      final first = diceFrom(_a, _b);
      for (var i = 0; i < 100; i++) {
        expect(diceFrom(_a, _b), first);
      }
    });

    test('random pairs agree with the independent implementation', () {
      for (var i = 0; i < 500; i++) {
        final a = _counterSecret('cross-a', i);
        final b = _counterSecret('cross-b', i);
        expect(diceFrom(a, b), _independentDice(a, b), reason: 'pair $i');
        expect(openingDiceFrom(a, b), _independentOpeningDice(a, b),
            reason: 'opening pair $i');
      }
    });

    test('derivation rejects malformed inputs', () {
      expect(() => diceFrom('short', _b), throwsFormatException);
      expect(() => openingDiceFrom(_a, _b.toUpperCase()),
          throwsFormatException);
    });
  });

  group('rejection sampling', () {
    test('sampleDie maps accepted bytes with byte % 6 + 1', () {
      for (var b = 0; b < kRejectAtOrAbove; b++) {
        var served = false;
        expect(sampleDie(() {
          expect(served, isFalse, reason: 'byte $b must be accepted at once');
          served = true;
          return b;
        }), b % 6 + 1);
      }
    });

    test('sampleDie skips every byte >= 252', () {
      final stream = [252, 253, 254, 255, 7].iterator;
      final die = sampleDie(() {
        stream.moveNext();
        return stream.current;
      });
      expect(die, 7 % 6 + 1);
    });

    test('the accepted range covers each face exactly 42 times', () {
      final counts = <int, int>{};
      for (var b = 0; b < kRejectAtOrAbove; b++) {
        counts.update(b % 6 + 1, (v) => v + 1, ifAbsent: () => 1);
      }
      expect(counts.values, everyElement(42),
          reason: '252 = 6 x 42 — that is the whole point of the threshold');
      expect(kRejectAtOrAbove, 252);
    });

    test('a real vector exercises the rejection path', () {
      // sha256(_rejectSecret ‖ _b) starts 0xff 0x70 0x96 ...
      final seed =
          sha256.convert([..._parseHex(_rejectSecret), ..._parseHex(_b)]).bytes;
      expect(seed[0], greaterThanOrEqualTo(kRejectAtOrAbove));
      expect(seed[0], 255);
      // 0xff rejected; 0x70 = 112 → 5; 0x96 = 150 → 1.
      expect(diceFrom(_rejectSecret, _b), Dice(5, 1));
      expect(diceFrom(_rejectSecret, _b), _independentDice(_rejectSecret, _b));
    });

    test('DerivationByteStream chains to sha256(block) when exhausted', () {
      final stream = DerivationByteStream(List.filled(kSecretBytes, 0));
      final pulled = [for (var i = 0; i < 40; i++) stream.nextByte()];
      expect(stream.chainDepth, 1);
      expect(pulled.take(32), everyElement(0));
      expect(pulled.sublist(32),
          sha256.convert(List.filled(kSecretBytes, 0)).bytes.take(8));
    });

    test('sampleDie survives a fully-rejecting block (exhaustion path)', () {
      // A synthetic block of 32 bytes that are ALL rejected forces the chain.
      // Unreachable in practice (probability (4/256)^32), reachable here.
      final stream = DerivationByteStream(List.filled(kSecretBytes, 255));
      expect(sampleDie(stream.nextByte), isIn([1, 2, 3, 4, 5, 6]));
      expect(stream.chainDepth, greaterThanOrEqualTo(1));
    });

    test('DerivationByteStream rejects an empty seed', () {
      expect(() => DerivationByteStream(const []), throwsArgumentError);
    });
  });

  group('uniformity smoke', () {
    test('10k derivations are flat across the six faces', () {
      // Deterministic input (counter-derived secrets) => deterministic result,
      // so this cannot flake. Bounds are lenient on purpose: this is a smoke
      // test for a gross derivation bug, not a randomness certification.
      // (It is NOT sensitive enough to see modulo bias — that is covered by
      // the rejection-sampling group above, which checks the 6 x 42 property
      // exactly.)
      const rolls = 10000;
      final counts = List<int>.filled(7, 0);
      for (var i = 0; i < rolls; i++) {
        final d = diceFrom(_counterSecret('uniformity-a', i),
            _counterSecret('uniformity-b', i));
        counts[d.die1]++;
        counts[d.die2]++;
      }
      const total = 2 * rolls;
      const expectedCount = total / 6;
      var chiSquare = 0.0;
      for (var face = 1; face <= 6; face++) {
        final p = counts[face] / total;
        expect((p - 1 / 6).abs(), lessThan(0.03),
            reason: 'face $face at $p (${counts[face]}/$total)');
        final dev = counts[face] - expectedCount;
        chiSquare += dev * dev / expectedCount;
      }
      // 5 degrees of freedom: 20.5 is the p=0.001 critical value.
      expect(chiSquare, lessThan(20.5), reason: 'chi-square $chiSquare');
      expect(counts.sublist(1).reduce((a, b) => a + b), total);
    });
  });

  group('opening variant', () {
    test('never returns a tie over 1000 counter-varied pairs', () {
      for (var i = 0; i < 1000; i++) {
        final dice = openingDiceFrom(
            _counterSecret('open-a', i), _counterSecret('open-b', i));
        expect(dice.isDouble, isFalse, reason: 'pair $i produced $dice');
        // The result is directly usable as an OpeningRollEvent.
        expect(
            () =>
                OpeningRollEvent(whiteDie: dice.die1, blackDie: dice.die2)
                    .validate(),
            returnsNormally);
      }
    });

    test('a tied first pair is discarded and the next pair used', () {
      expect(diceFrom(_tieSecret, _b), Dice(2, 2),
          reason: 'the ordinary roll IS a double here');
      expect(openingDiceFrom(_tieSecret, _b), Dice(2, 3),
          reason: 'the opening variant draws the following pair');
      expect(openingDiceFrom(_tieSecret, _b),
          _independentOpeningDice(_tieSecret, _b));
    });

    test('the discard path really is exercised at ~1/6 of pairs', () {
      var discarded = 0;
      for (var i = 0; i < 1000; i++) {
        if (diceFrom(_counterSecret('open-a', i), _counterSecret('open-b', i))
            .isDouble) {
          discarded++;
        }
      }
      expect(discarded, greaterThan(80));
      expect(discarded, lessThan(250));
    });

    test('opening dice feed GameState.opening without an argument error', () {
      final dice = openingDiceFrom(_a, _b);
      expect(
          () => GameState.opening(
              firstPlayer: dice.die1 > dice.die2 ? Player.white : Player.black,
              openingDice: dice),
          returnsNormally);
    });
  });

  group('role state machines', () {
    test('roller and witness reach the same dice', () {
      final roller = RollerSession(rollIndex: 7);
      final witness = WitnessSession(rollIndex: 7);

      final commit = roller.makeCommit();
      witness.seeCommit(commit);
      final entropy = witness.contributeEntropy();
      roller.acceptEntropy(entropy);
      final reveal = roller.reveal();
      witness.verifyReveal(reveal);

      expect(roller.phase, FairDicePhase.revealed);
      expect(witness.phase, FairDicePhase.revealed);
      expect(roller.dice, witness.dice);
      expect(roller.openingDice, witness.openingDice);
      expect(roller.dice, diceFrom(reveal, entropy));
      expect(witness.reveal, reveal);
      expect(witness.commit, commit);
      expect(roller.entropy, entropy);
    });

    test('every wire value is the 64-hex shape the rules enforce', () {
      for (var i = 0; i < 20; i++) {
        final roller = RollerSession();
        final witness = WitnessSession();
        final commit = roller.makeCommit();
        witness.seeCommit(commit);
        final entropy = witness.contributeEntropy();
        roller.acceptEntropy(entropy);
        final reveal = roller.reveal();
        witness.verifyReveal(reveal);
        for (final value in [commit, entropy, reveal]) {
          expect(isHex64(value), isTrue, reason: '"$value" is not hex64');
        }
        expect(commitFor(reveal), commit);
      }
    });

    test('injected Random makes a session reproducible (test-only path)', () {
      String runRoller(int seed) =>
          (RollerSession(rng: Random(seed))..makeCommit()).commit;
      expect(runRoller(42), runRoller(42));
      expect(runRoller(42), isNot(runRoller(43)));
    });

    test('roller phase skips throw StateError', () {
      final fresh = RollerSession();
      expect(() => fresh.acceptEntropy(_b), throwsStateError);
      expect(() => fresh.reveal(), throwsStateError);
      expect(() => fresh.dice, throwsStateError);
      expect(() => fresh.openingDice, throwsStateError);
      expect(() => fresh.commit, throwsStateError);
      expect(() => fresh.entropy, throwsStateError);

      final committed = RollerSession()..makeCommit();
      expect(() => committed.makeCommit(), throwsStateError);
      expect(() => committed.reveal(), throwsStateError);
      expect(() => committed.dice, throwsStateError);
      expect(() => committed.entropy, throwsStateError);

      final withEntropy = RollerSession()
        ..makeCommit()
        ..acceptEntropy(_b);
      expect(() => withEntropy.acceptEntropy(_a), throwsStateError);
      expect(() => withEntropy.dice, throwsStateError,
          reason: 'dice only after reveal()');

      final done = RollerSession()..makeCommit();
      done.acceptEntropy(_b);
      done.reveal();
      expect(() => done.reveal(), throwsStateError);
      expect(done.dice, isA<Dice>());
    });

    test('witness phase skips throw StateError', () {
      final fresh = WitnessSession();
      expect(() => fresh.contributeEntropy(), throwsStateError);
      expect(() => fresh.verifyReveal(_a), throwsStateError);
      expect(() => fresh.dice, throwsStateError);
      expect(() => fresh.openingDice, throwsStateError);
      expect(() => fresh.commit, throwsStateError);

      final seen = WitnessSession()..seeCommit(commitFor(_a));
      expect(() => seen.seeCommit(commitFor(_b)), throwsStateError);
      expect(() => seen.verifyReveal(_a), throwsStateError,
          reason: 'must contribute entropy before a reveal is meaningful');
      expect(() => seen.entropy, throwsStateError);

      final contributed = WitnessSession()..seeCommit(commitFor(_a));
      contributed.contributeEntropy();
      expect(() => contributed.contributeEntropy(), throwsStateError);
      expect(() => contributed.dice, throwsStateError);
      expect(() => contributed.reveal, throwsStateError);
      contributed.verifyReveal(_a);
      expect(() => contributed.verifyReveal(_a), throwsStateError);
      expect(contributed.dice, isA<Dice>());
    });

    test('sessions reject malformed wire values', () {
      final roller = RollerSession()..makeCommit();
      expect(() => roller.acceptEntropy('nope'), throwsFormatException);

      expect(() => WitnessSession().seeCommit('nope'), throwsFormatException);

      final witness = WitnessSession()..seeCommit(commitFor(_a));
      witness.contributeEntropy();
      expect(() => witness.verifyReveal('nope'), throwsFormatException);
    });
  });

  group('cheat detection', () {
    test('a swapped reveal throws with the offending values', () {
      final witness = WitnessSession(rollIndex: 12)
        ..seeCommit(commitFor(_a));
      witness.contributeEntropy();

      expect(
        () => witness.verifyReveal(_b),
        throwsA(isA<FairDiceCheatException>()
            .having((e) => e.commit, 'commit', commitFor(_a))
            .having((e) => e.reveal, 'reveal', _b)
            .having((e) => e.actualCommit, 'actualCommit', commitFor(_b))
            .having((e) => e.rollIndex, 'rollIndex', 12)
            .having((e) => e.toString(), 'message',
                allOf(contains('roll 12'), contains(commitFor(_a))))),
      );
      expect(witness.phase, FairDicePhase.entropy,
          reason: 'a failed verification must not advance the session');
    });

    test('a cheat exception without a roll index still reads sensibly', () {
      final witness = WitnessSession()..seeCommit(commitFor(_a));
      witness.contributeEntropy();
      expect(
          () => witness.verifyReveal(_zeros),
          throwsA(isA<FairDiceCheatException>().having(
              (e) => e.toString(), 'message', contains('does not match'))));
    });

    test('an honest reveal never throws over many rounds', () {
      for (var i = 0; i < 100; i++) {
        final roller = RollerSession();
        final witness = WitnessSession()..seeCommit(roller.makeCommit());
        roller.acceptEntropy(witness.contributeEntropy());
        expect(() => witness.verifyReveal(roller.reveal()), returnsNormally);
      }
    });
  });

  group('folding-side validation', () {
    CompletedRoll completed({int index = 3}) => CompletedRoll(
        commit: commitFor(_a), entropy: _b, reveal: _a, index: index);

    test('CompletedRoll derives the same dice as the sessions', () {
      final roll = completed();
      expect(roll.dice, diceFrom(_a, _b));
      expect(roll.openingDice, openingDiceFrom(_a, _b));
      expect(() => roll.verifyCommit(), returnsNormally);
    });

    test('fromFields decodes a Firestore field map', () {
      final roll = CompletedRoll.fromFields({
        'n': 42,
        'roller': 'uid-1',
        'commit': commitFor(_a),
        'entropy': _b,
        'reveal': _a,
      });
      expect(roll.index, 42);
      expect(roll.dice, Dice(1, 2));
    });

    test('fromFields refuses an incomplete or malformed roll', () {
      expect(
          () => CompletedRoll.fromFields(
              {'commit': commitFor(_a), 'entropy': _b}),
          throwsFormatException);
      expect(
          () => CompletedRoll.fromFields(
              {'commit': commitFor(_a), 'entropy': _b, 'reveal': 7}),
          throwsFormatException);
      expect(
          () => CompletedRoll.fromFields(
              {'commit': 'nope', 'entropy': _b, 'reveal': _a}),
          throwsFormatException);
    });

    test('diceMatchRoll accepts the protocol dice and rejects others', () {
      final roll = completed();
      expect(
          diceMatchRoll(roll, const RollEvent(Player.white, 1, 2)), isTrue);
      expect(
          diceMatchRoll(roll, const RollEvent(Player.white, 2, 1)), isFalse,
          reason: 'order is part of the derivation');
      expect(
          diceMatchRoll(roll, const RollEvent(Player.white, 6, 6)), isFalse);
      expect(diceMatchRoll(roll, const RollEvent(Player.black, 1, 2)), isTrue,
          reason: 'the player field is the event log\'s business, not ours');
    });

    test('openingDiceMatchRoll maps die1/die2 to white/black', () {
      final roll = completed();
      expect(
          openingDiceMatchRoll(
              roll, const OpeningRollEvent(whiteDie: 1, blackDie: 2)),
          isTrue);
      expect(
          openingDiceMatchRoll(
              roll, const OpeningRollEvent(whiteDie: 2, blackDie: 1)),
          isFalse);
    });

    test('opening validation uses the tie-discarding derivation', () {
      final roll = CompletedRoll(
          commit: commitFor(_tieSecret), entropy: _b, reveal: _tieSecret);
      expect(
          openingDiceMatchRoll(
              roll, const OpeningRollEvent(whiteDie: 2, blackDie: 3)),
          isTrue);
      expect(diceMatchRoll(roll, const RollEvent(Player.white, 2, 2)), isTrue);
    });

    test('a broken commitment throws rather than returning false', () {
      final forged =
          CompletedRoll(commit: commitFor(_a), entropy: _b, reveal: _b, index: 9);
      expect(() => forged.verifyCommit(),
          throwsA(isA<FairDiceCheatException>()));
      expect(() => diceMatchRoll(forged, const RollEvent(Player.white, 1, 2)),
          throwsA(isA<FairDiceCheatException>()
              .having((e) => e.rollIndex, 'rollIndex', 9)));
      expect(
          () => openingDiceMatchRoll(
              forged, const OpeningRollEvent(whiteDie: 1, blackDie: 2)),
          throwsA(isA<FairDiceCheatException>()));
    });

    test('CompletedRoll enforces the 64-hex wire shape on construction', () {
      expect(
          () => CompletedRoll(commit: 'x', entropy: _b, reveal: _a),
          throwsFormatException);
      expect(
          () => CompletedRoll(
              commit: commitFor(_a), entropy: _b.toUpperCase(), reveal: _a),
          throwsFormatException);
    });

    test('a full session round-trips through CompletedRoll', () {
      for (var i = 0; i < 25; i++) {
        final roller = RollerSession();
        final witness = WitnessSession()..seeCommit(roller.makeCommit());
        final entropy = witness.contributeEntropy();
        roller.acceptEntropy(entropy);
        final reveal = roller.reveal();
        witness.verifyReveal(reveal);

        final roll = CompletedRoll.fromFields({
          'n': i,
          'commit': witness.commit,
          'entropy': entropy,
          'reveal': reveal,
        });
        expect(roll.dice, roller.dice);
        final dice = roller.dice;
        expect(
            diceMatchRoll(roll, RollEvent(Player.white, dice.die1, dice.die2)),
            isTrue);
        final opening = roller.openingDice;
        expect(
            openingDiceMatchRoll(roll,
                OpeningRollEvent(whiteDie: opening.die1, blackDie: opening.die2)),
            isTrue);
      }
    });
  });
}
