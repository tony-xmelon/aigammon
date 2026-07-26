/// Nearby (LAN) play: the wire protocol and the host-side authority.
///
/// Transport-free by design — [HostAuthority] consumes decoded [Envelope]s (or
/// raw frames) and emits targeted [HostOutbound] messages, so it is fully
/// unit-testable in memory. The socket layer lives in Task 2.
library;

export 'src/dice_roller.dart';
export 'src/host_authority.dart';
export 'src/protocol.dart';
