import 'dart:convert';

/// Raised for any non-success REST outcome (a Firestore/Identity-Toolkit error
/// envelope, a non-2xx HTTP status, or a malformed response).
///
/// The canonical Google-API status strings get their own subclasses so callers
/// can branch on the *meaning* rather than string-matching a code; anything
/// unrecognised stays a plain [OnlineException] carrying the raw code.
class OnlineException implements Exception {
  /// The Google-API status string (`PERMISSION_DENIED`, `NOT_FOUND`, …) or
  /// `http-<statusCode>` when the body carried no structured error.
  final String code;

  /// A human-readable message from the server or transport.
  final String message;

  const OnlineException(this.code, this.message);

  @override
  String toString() => '$runtimeType($code): $message';
}

/// The security rules refused the operation.
///
/// This is the *rules-rejection* signal: the caller is authenticated but the
/// write it attempted is not one the model allows (wrong author, phase skip,
/// bad shape, non-participant access). It is never transient — retrying an
/// identical request will fail identically.
class PermissionDeniedException extends OnlineException {
  const PermissionDeniedException(String message)
      : super('PERMISSION_DENIED', message);
}

/// The caller presented no (or an unusable) credential.
class UnauthenticatedException extends OnlineException {
  const UnauthenticatedException(String message)
      : super('UNAUTHENTICATED', message);
}

/// The addressed document does not exist — e.g. a mistyped invite code.
class NotFoundException extends OnlineException {
  const NotFoundException(String message) : super('NOT_FOUND', message);
}

/// A create lost the race for a document id.
///
/// Two meanings, both handled the same way by the caller: an invite code
/// collision (retry with a fresh code) or a sequence-number collision on
/// `events/{seq}` / `rolls/{n}` — the opponent claimed that slot first, so the
/// controller must resync the log and retry with the next free index.
class AlreadyExistsException extends OnlineException {
  const AlreadyExistsException(String message)
      : super('ALREADY_EXISTS', message);
}

/// A `currentDocument` precondition failed on an update: the document changed
/// (or vanished) between the read and the write. Retry after re-reading.
class FailedPreconditionException extends OnlineException {
  const FailedPreconditionException(String message)
      : super('FAILED_PRECONDITION', message);
}

/// Map a REST failure onto the typed exception hierarchy.
///
/// Google's JSON error envelope is `{"error": {"status": ..., "message": ...}}`.
/// Streaming methods (`:runQuery`) wrap that object in a one-element ARRAY, so
/// both shapes are accepted. A body that parses as neither degrades to
/// `http-<statusCode>` with the raw body as the message.
OnlineException onlineExceptionFor(int statusCode, String body) {
  final error = _errorObject(body);
  final status = error?['status']?.toString();
  final message = error?['message']?.toString() ?? (body.isEmpty ? 'HTTP $statusCode' : body);
  switch (status) {
    case 'PERMISSION_DENIED':
      return PermissionDeniedException(message);
    case 'UNAUTHENTICATED':
      return UnauthenticatedException(message);
    case 'NOT_FOUND':
      return NotFoundException(message);
    case 'ALREADY_EXISTS':
      return AlreadyExistsException(message);
    case 'FAILED_PRECONDITION':
      return FailedPreconditionException(message);
  }
  // Some emulator/REST paths omit `status` but keep the numeric code; fall back
  // to the HTTP status, which carries the same distinctions for our cases.
  switch (statusCode) {
    case 401:
      return UnauthenticatedException(message);
    case 403:
      return PermissionDeniedException(message);
    case 404:
      return NotFoundException(message);
    case 409:
      return AlreadyExistsException(message);
  }
  return OnlineException(status ?? 'http-$statusCode', message);
}

Map<String, Object?>? _errorObject(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (decoded is List) {
    for (final row in decoded) {
      if (row is Map && row['error'] is Map) {
        return (row['error'] as Map).cast<String, Object?>();
      }
    }
    return null;
  }
  if (decoded is Map && decoded['error'] is Map) {
    return (decoded['error'] as Map).cast<String, Object?>();
  }
  return null;
}
