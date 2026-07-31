/// The TEST-ONLY half of `match_transport`, kept out of the main barrel.
///
/// Two things live here and nowhere near production code:
///
///   * [InMemoryBackend] / [InMemoryTransport] — an in-process transport pair
///     for driving two controllers against each other;
///   * the scripted commit-reveal helpers, which aim the fair-dice derivation
///     at a known roll.
///
/// They used to be exported from `match_transport.dart` alongside the real
/// interface, so every production import of the transport seam also pulled in
/// an in-memory stand-in. Neither imports `package:test`, so this barrel is
/// safe for a `flutter_test` suite too — the executable contract, which DOES
/// import it, stays in its own `package:match_transport/transport_contract.dart`
/// and is imported only by the three plain-Dart suites that run it.
///
/// Import this ALONGSIDE `package:match_transport/match_transport.dart`; it
/// deliberately does not re-export the interface.
library;

export 'src/in_memory_transport.dart';
export 'src/scripted_dice.dart';
