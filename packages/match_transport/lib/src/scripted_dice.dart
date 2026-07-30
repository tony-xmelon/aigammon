/// Aiming the commit-reveal derivation at a KNOWN roll, for tests.
///
/// The derivation is a hash, so the only way to get specific dice out of it is
/// to brute-force the witness's entropy against a fixed roller secret until the
/// pair derives what you asked for (about 30 tries on average). That is what lets
/// a scripted match seed an exact opening or turn roll WITHOUT forging an
/// unverifiable roll document — every value still passes commitment
/// verification. Ported from the shipped `fake_online_backend`/`lan_harness`
/// helpers into the shared package so every transport's tests can reuse them.
library;

import 'dart:math';

import 'fair_dice.dart';

/// A commit-reveal secret pair whose derivation gives exactly the dice a test
/// asked for: [secret] is the roller's, [entropy] the witness's, [commit] the
/// published commitment `sha256(secret)`.
typedef ScriptedSecrets = ({String secret, String entropy, String commit});

/// The default deterministic seed, so a scripted match replays identically.
const int _defaultSeed = 20260727;

ScriptedSecrets _search(bool Function(String a, String b) matches, Random rng) {
  final secret = generateSecretHex(rng: rng);
  for (var i = 0; i < 20000; i++) {
    final entropy = generateSecretHex(rng: rng);
    if (matches(secret, entropy)) {
      return (secret: secret, entropy: entropy, commit: commitFor(secret));
    }
  }
  throw StateError('no entropy produced the requested dice in 20000 tries');
}

/// Secrets whose OPENING derivation is exactly [white]/[black]
/// (`whiteDie == die1`, `blackDie == die2`). The two faces must differ — an
/// opening roll is never a tie.
ScriptedSecrets openingSecretsFor(int white, int black, {Random? rng}) {
  if (white == black) {
    throw ArgumentError('an opening roll cannot be a tie');
  }
  return _search((a, b) {
    final d = openingDiceFrom(a, b);
    return d.die1 == white && d.die2 == black;
  }, rng ?? Random(_defaultSeed));
}

/// Secrets whose ordinary derivation is exactly [die1]/[die2].
ScriptedSecrets turnSecretsFor(int die1, int die2, {Random? rng}) =>
    _search((a, b) {
      final d = diceFrom(a, b);
      return d.die1 == die1 && d.die2 == die2;
    }, rng ?? Random(_defaultSeed));
