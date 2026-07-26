import 'dart:convert';

import 'package:http/http.dart' as http;

import 'firestore_value.dart';
import 'online_config.dart';
import 'online_exception.dart';

/// One Firestore document as the REST API returns it.
class FirestoreDoc {
  /// Full resource name, e.g.
  /// `projects/p/databases/(default)/documents/matches/ABCD1234`.
  final String name;

  /// Decoded field map (see [decodeFields]).
  final Map<String, Object?> fields;

  /// The document's `updateTime`, usable as an optimistic-concurrency token in
  /// [FirestoreDocs.patch].
  final String? updateTime;

  const FirestoreDoc({
    required this.name,
    required this.fields,
    this.updateTime,
  });

  /// The last path segment of [name] — the document id.
  String get id => name.substring(name.lastIndexOf('/') + 1);
}

/// Comparison operators supported by [FirestoreDocs.query].
enum FieldOp {
  greaterThan('GREATER_THAN'),
  greaterThanOrEqual('GREATER_THAN_OR_EQUAL');

  const FieldOp(this.wire);
  final String wire;
}

/// Direct Firestore REST v1 document operations — the whole serverless
/// transport surface, with no Cloud Functions anywhere.
///
/// Three RPC shapes are used, each chosen for a reason:
///
/// * **`:commit`** for every CREATE. It is the only shape that can attach an
///   `updateTransforms` server-timestamp (the match doc's `createdAt` must
///   equal `request.time`, which a client-chosen value can never satisfy — see
///   `firebase/firestore.rules`) and it carries a `currentDocument:{exists:
///   false}` precondition, which is what makes doc-id-as-sequence-number an
///   append primitive: the loser of a race gets [AlreadyExistsException]
///   instead of clobbering the winner.
/// * **`PATCH` with `updateMask`** for every UPDATE. The mask is load-bearing,
///   not an optimisation: the rules pin each legal transition with
///   `diff(resource.data).affectedKeys().hasOnly([...])`, so a write that
///   resends unchanged fields is fine but a write that touches anything outside
///   the mask is refused. An optional `currentDocument.updateTime` turns a lost
///   race into [FailedPreconditionException] rather than a silent overwrite.
/// * **`:runQuery`** for reads of the `events` / `rolls` subcollections, which
///   the rules allow participants to `list`. (`matches` itself may never be
///   listed — invite codes must not be enumerable — so match reads are always
///   direct gets by code.)
class FirestoreDocs {
  final OnlineConfig config;
  final Future<String> Function() _token;
  final http.Client _http;

  FirestoreDocs(
    this.config, {
    required Future<String> Function() token,
    http.Client? inner,
  })  : _token = token,
        _http = inner ?? http.Client();

  Future<Map<String, String>> _headers() async => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${await _token()}',
      };

  /// Fetch the document at [path] (relative to the documents root, e.g.
  /// `matches/ABCD1234`). Returns null when it does not exist.
  ///
  /// A rules refusal still throws [PermissionDeniedException] — "denied" and
  /// "absent" are deliberately NOT collapsed, because for a match code they
  /// mean very different things ("someone else's match" vs "bad code").
  Future<FirestoreDoc?> get(String path) async {
    final res = await _http.get(
      Uri.parse('${config.firestoreDocumentsBase}/$path'),
      headers: await _headers(),
    );
    if (res.statusCode == 404) return null;
    final body = _decodeObject(res);
    return _docFrom(body);
  }

  /// Create the document at [path] with [fields], failing with
  /// [AlreadyExistsException] if it already exists.
  ///
  /// Each entry of [serverTimestamps] is a field path stamped with the server's
  /// `REQUEST_TIME` — the value rules see as `request.time`.
  Future<void> create(
    String path,
    Map<String, Object?> fields, {
    List<String> serverTimestamps = const [],
  }) async {
    final write = <String, Object?>{
      'update': {
        'name': '${config.documentsResourcePrefix}/$path',
        'fields': encodeFields(fields),
      },
      'currentDocument': {'exists': false},
    };
    if (serverTimestamps.isNotEmpty) {
      write['updateTransforms'] = [
        for (final field in serverTimestamps)
          {'fieldPath': field, 'setToServerValue': 'REQUEST_TIME'},
      ];
    }
    final res = await _http.post(
      Uri.parse('${config.firestoreDocumentsBase}:commit'),
      headers: await _headers(),
      body: jsonEncode({
        'writes': [write],
      }),
    );
    if (_isError(res)) throw _createError(res);
  }

  /// Patch [fields] into the document at [path], writing ONLY the field paths
  /// in [updateMask].
  ///
  /// The write always carries `currentDocument.exists=true`, so a patch can
  /// never accidentally CREATE the document it was meant to amend — which
  /// matters here because the rules for a fresh document are entirely
  /// different from the rules for a transition.
  ///
  /// Deliberately no `updateTime` precondition: the Firestore emulator does
  /// not honour REST's `currentDocument.updateTime` — supplying it makes the
  /// write evaluate as a CREATE against the rules (verified against the
  /// emulator, encoded or raw). Optimistic concurrency is instead a property
  /// of the model: every legal transition in `firestore.rules` is pinned to
  /// the PRE-state it starts from (`status == 'waiting'`, `guestUid == null`,
  /// `!('entropy' in resource.data)`, …), so a caller that lost a race gets
  /// PERMISSION_DENIED rather than silently overwriting the winner.
  ///
  /// Returns the document as it stands after the write.
  Future<FirestoreDoc> patch(
    String path,
    Map<String, Object?> fields, {
    required List<String> updateMask,
  }) async {
    final url = Uri.parse('${config.firestoreDocumentsBase}/$path')
        .replace(queryParameters: <String, List<String>>{
      'updateMask.fieldPaths': updateMask,
      'currentDocument.exists': ['true'],
    });
    final res = await _http.patch(
      url,
      headers: await _headers(),
      body: jsonEncode({'fields': encodeFields(fields)}),
    );
    return _docFrom(_decodeObject(res));
  }

  /// Query the subcollection [collectionId] under [parentPath], optionally
  /// filtering on an int field, ordering ascending by [orderBy], and capping the
  /// page at [limit] documents.
  Future<List<FirestoreDoc>> query(
    String parentPath,
    String collectionId, {
    (String field, FieldOp op, int value)? whereInt,
    String? orderBy,
    int? limit,
  }) async {
    final structuredQuery = <String, Object?>{
      'from': [
        {'collectionId': collectionId},
      ],
      if (whereInt != null)
        'where': {
          'fieldFilter': {
            'field': {'fieldPath': whereInt.$1},
            'op': whereInt.$2.wire,
            'value': {'integerValue': whereInt.$3.toString()},
          },
        },
      if (orderBy != null)
        'orderBy': [
          {
            'field': {'fieldPath': orderBy},
            'direction': 'ASCENDING',
          },
        ],
      if (limit != null) 'limit': limit,
    };

    final res = await _http.post(
      Uri.parse('${config.firestoreDocumentsBase}/$parentPath:runQuery'),
      headers: await _headers(),
      body: jsonEncode({'structuredQuery': structuredQuery}),
    );
    if (_isError(res)) throw onlineExceptionFor(res.statusCode, res.body);
    final decoded = jsonDecode(res.body);
    if (decoded is! List) {
      throw onlineExceptionFor(res.statusCode, res.body);
    }
    final out = <FirestoreDoc>[];
    for (final row in decoded) {
      if (row is! Map) continue;
      // A streamed error row, and read-time-only rows that carry no document.
      if (row['error'] is Map) {
        throw onlineExceptionFor(res.statusCode, res.body);
      }
      final doc = row['document'];
      if (doc is! Map) continue;
      out.add(_docFrom(doc.cast<String, Object?>()));
    }
    return out;
  }

  /// Close the underlying HTTP client.
  void close() => _http.close();

  // --- plumbing --------------------------------------------------------------

  bool _isError(http.Response res) =>
      res.statusCode < 200 || res.statusCode >= 300;

  Map<String, Object?> _decodeObject(http.Response res) {
    if (_isError(res)) throw onlineExceptionFor(res.statusCode, res.body);
    final decoded = jsonDecode(res.body);
    if (decoded is! Map) {
      throw OnlineException('malformed-response', res.body);
    }
    return decoded.cast<String, Object?>();
  }

  FirestoreDoc _docFrom(Map<String, Object?> body) {
    final fields = body['fields'];
    return FirestoreDoc(
      name: body['name']?.toString() ?? '',
      fields: fields is Map
          ? decodeFields(fields.cast<String, Object?>())
          : const <String, Object?>{},
      updateTime: body['updateTime']?.toString(),
    );
  }

  /// Normalises a failed create.
  ///
  /// The ONLY precondition a create carries is `exists: false`, so a
  /// `FAILED_PRECONDITION` from `:commit` means exactly one thing — the id is
  /// taken. Firestore reports that as `ALREADY_EXISTS` on some paths and as a
  /// precondition failure on others; callers should not have to care, so both
  /// surface as [AlreadyExistsException].
  OnlineException _createError(http.Response res) {
    final mapped = onlineExceptionFor(res.statusCode, res.body);
    if (mapped is FailedPreconditionException) {
      return AlreadyExistsException(mapped.message);
    }
    return mapped;
  }
}
