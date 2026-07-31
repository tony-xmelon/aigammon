/// The transport seam AIGammon's unified multiplayer runs on (Plan 17).
///
/// One `MatchTransport` interface, one commit-reveal dice protocol, and an
/// in-process transport pair for tests. LAN (socket relay) and online
/// (Firestore) each provide one implementation; a single match controller drives
/// either. See `src/match_transport.dart`'s library doc for the normative
/// fold/resync contract every implementation guarantees.
library;

export 'src/fair_dice.dart';
export 'src/in_memory_transport.dart';
export 'src/match_transport.dart';
export 'src/transport_channels.dart';
export 'src/scripted_dice.dart';
