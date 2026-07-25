/// Raised for any non-success REST outcome (a callable `{"error":...}` envelope,
/// a non-2xx HTTP status, or a malformed response).
class OnlineException implements Exception {
  /// A short machine code — the callable error `status` (e.g. `not-found`,
  /// `permission-denied`), or `http-<statusCode>` for a raw HTTP failure.
  final String code;

  /// A human-readable message from the server or transport.
  final String message;

  const OnlineException(this.code, this.message);

  @override
  String toString() => 'OnlineException($code): $message';
}
