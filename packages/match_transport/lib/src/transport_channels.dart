/// The three broadcast channels every [MatchTransport] carries, and the guard
/// logic around them.
///
/// Four implementations ship — the LAN host and guest halves of
/// `SocketTransport`, `FirestoreTransport` and [InMemoryTransport] — and each
/// had grown its own copy of the same twenty lines: three
/// `StreamController.broadcast()`s, six interface getters, a
/// `publish`/`publishError` pair that must not touch a closed controller, a
/// presence setter that dedupes, a status setter that (in three of the four)
/// did not, and a disposal that closes all three.
///
/// The copies had already drifted: only `FirestoreTransport` skipped a
/// redundant status write, so the other three re-announced `connected` on every
/// no-op transition and the connection chip flickered for no reason. One copy
/// of the rule fixes all four.
library;

import 'dart:async';

import 'match_transport.dart';

/// Carries the frame, status and presence channels for a [MatchTransport].
///
/// The host class supplies [isDisposed] — it owns the disposal flag, because
/// every implementation guards its OWN work with it too and orders its teardown
/// around it. Everything the mixin emits is gated on that flag and on the
/// controller still being open, so a late callback after `dispose()` is a no-op
/// rather than a "Cannot add new events after calling close".
mixin TransportChannels {
  /// Whether the owning transport has been disposed. Set by the host class
  /// FIRST thing in its `dispose()`, before it tears anything down.
  bool get isDisposed;

  final StreamController<InboundFrame> _inboundChannel =
      StreamController<InboundFrame>.broadcast();
  final StreamController<TransportStatusEvent> _statusChannel =
      StreamController<TransportStatusEvent>.broadcast();
  final StreamController<bool> _presenceChannel =
      StreamController<bool>.broadcast();

  TransportStatus _statusValue = TransportStatus.connecting;
  String? _statusReason;
  bool _opponentPresent = false;

  // --- the MatchTransport surface --------------------------------------------

  Stream<InboundFrame> get inbound => _inboundChannel.stream;

  Stream<TransportStatusEvent> get statusStream => _statusChannel.stream;

  TransportStatus get status => _statusValue;

  String? get statusReason => _statusReason;

  bool get opponentPresent => _opponentPresent;

  Stream<bool> get opponentPresence => _presenceChannel.stream;

  // --- emitting ---------------------------------------------------------------

  /// Deliver [frame] on [inbound].
  void publish(InboundFrame frame) {
    if (isDisposed || _inboundChannel.isClosed) return;
    _inboundChannel.add(frame);
  }

  /// A transient fault on [inbound], WITHOUT closing it — per the contract, a
  /// transport never ends `inbound` to signal trouble.
  void publishError(Object error) {
    if (isDisposed || _inboundChannel.isClosed) return;
    _inboundChannel.addError(error);
  }

  /// Record the status and announce it, unless nothing changed.
  ///
  /// The dedup is the point: a poll loop that confirms `connected` on every
  /// cycle, or a socket that re-reports the state it is already in, must not
  /// bill the controller (and the connection chip) an event for standing still.
  void setStatus(TransportStatus status, [String? reason]) {
    if (updateStatus(status, reason)) emitStatus();
  }

  /// Record the status WITHOUT announcing it; returns whether it changed.
  ///
  /// Pairs with [emitStatus] for the two callers that must run side effects
  /// between the update and the event (a guest link that fails its pending
  /// writes first) or that must adopt a status silently at construction.
  bool updateStatus(TransportStatus status, [String? reason]) {
    if (isDisposed) return false;
    if (_statusValue == status && _statusReason == reason) return false;
    _statusValue = status;
    _statusReason = reason;
    return true;
  }

  /// Announce the CURRENT [status]/[statusReason]. See [updateStatus].
  void emitStatus() {
    if (isDisposed || _statusChannel.isClosed) return;
    _statusChannel.add(TransportStatusEvent(_statusValue, _statusReason));
  }

  /// Record the opponent's presence and announce a change.
  void setOpponentPresent(bool present) {
    if (isDisposed || _opponentPresent == present) return;
    _opponentPresent = present;
    if (!_presenceChannel.isClosed) _presenceChannel.add(present);
  }

  // --- disposal ---------------------------------------------------------------

  /// Close all three channels. Call LAST in the host class's `dispose()`, after
  /// it has set its disposal flag and cancelled whatever it owns.
  Future<void> closeChannels() async {
    await _inboundChannel.close();
    await _statusChannel.close();
    await _presenceChannel.close();
  }
}
