/// Decoding for [Isolate.addErrorListener] messages.
///
/// Deliberately NOT exported from the package barrel — it is an internal detail
/// of `EngineService`. It lives in its own library so it can be unit-tested
/// without a real isolate crash, which is otherwise impossible to provoke
/// through the public API (every reachable failure inside the worker is caught
/// and replied as an `err`).
library;

import 'dart:isolate';

/// An error that escaped an isolate, as delivered on its error port.
class IsolateError {
  const IsolateError(this.error, this.stack);

  final Object error;
  final StackTrace? stack;
}

/// Decodes one message from an isolate error/exit port.
///
/// The runtime sends `[error.toString(), stackTrace.toString()]` on the error
/// port (the stack may be null). [Isolate.addOnExitListener] shares the same
/// port in `EngineService` and delivers the exit response — `null` — for a
/// CLEAN shutdown. Returns null for anything that is not an actual error, so
/// disposing the engine never looks like a crash.
IsolateError? decodeIsolateError(Object? message) {
  if (message is! List || message.isEmpty) return null;
  final error = message[0];
  if (error == null) return null;
  final rawStack = message.length > 1 ? message[1] : null;
  return IsolateError(
    error,
    rawStack is String && rawStack.isNotEmpty
        ? StackTrace.fromString(rawStack)
        : null,
  );
}
