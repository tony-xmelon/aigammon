/// The transport seam AIGammon's unified multiplayer runs on (Plan 17).
///
/// One `MatchTransport` interface and one commit-reveal dice protocol. LAN
/// (socket relay) and online (Firestore) each provide one implementation; a
/// single match controller drives either. See `src/match_transport.dart`'s
/// library doc for the normative fold/resync contract every implementation
/// guarantees.
///
/// The test-only half — the executable contract suite, the in-process transport
/// pair and the scripted dice helpers — is `package:match_transport/testing.dart`,
/// deliberately a sibling library rather than part of this barrel.
library;

export 'src/fair_dice.dart';
export 'src/match_transport.dart';
export 'src/transport_channels.dart';
