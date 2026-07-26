/// Nearby (LAN) play: the wire protocol, the host-side authority, and the
/// sockets that carry them.
///
/// [HostAuthority] is transport-free by design — it consumes decoded
/// [Envelope]s (or raw frames) and emits targeted [HostOutbound] messages, so
/// it is fully unit-testable in memory. [HostServer] and [GuestClient] wrap it
/// in `dart:io` WebSockets, adding the room-code handshake, the single-guest
/// policy, heartbeats, rate limits and reconnection.
library;

export 'src/dice_roller.dart';
export 'src/guest_client.dart';
export 'src/host_authority.dart';
export 'src/host_server.dart';
export 'src/lan_timings.dart';
export 'src/protocol.dart';
