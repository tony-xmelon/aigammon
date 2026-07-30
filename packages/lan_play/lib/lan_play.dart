/// Nearby (LAN) play: the wire protocol, the bidirectional relay, and the
/// sockets that carry them.
///
/// [MatchRelay] is transport-free by design — it holds the append-only event log
/// and the commit-reveal roll documents, enforces write-once ordering and NOTHING
/// else, so it is fully unit-testable in memory. [HostServer] and [GuestClient]
/// wrap it in `dart:io` WebSockets, adding the room-code handshake, the
/// single-guest policy, heartbeats, rate limits and reconnection.
/// [SocketTransport] joins the two into the one `MatchTransport` both peers'
/// `NetMatchController`s drive.
///
/// There is no referee here: `HostAuthority` was deleted in Plan 17 and every
/// check it made now lives in the controller, on BOTH peers. See
/// [MatchRelay]'s class doc.
library;

export 'src/discovery.dart';
export 'src/display_name.dart';
export 'src/guest_client.dart';
export 'src/host_server.dart';
export 'src/lan_timings.dart';
export 'src/match_relay.dart';
export 'src/protocol.dart';
export 'src/socket_transport.dart';
