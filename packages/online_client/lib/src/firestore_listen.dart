/// Firestore's real-time `Listen` channel — the push half of online play.
///
/// ## Why gRPC at all
///
/// Firestore's watch API (`google.firestore.v1.Firestore/Listen`) is a
/// bidirectional gRPC stream and has NO REST equivalent: `:runQuery` answers
/// once and hangs up. So the alternative to this file is the poll loop, and the
/// poll loop is what the free-tier read budget cannot afford — a listen is billed
/// per DELIVERED DOCUMENT, a poll per cycle whether anything changed or not.
///
/// `package:grpc` is used for HTTP/2 framing, TLS and metadata only; the message
/// bodies are encoded by hand ([ProtoWriter]/[ProtoReader]) so no `protoc` enters
/// the build. See `proto_codec.dart` for that trade-off in full.
///
/// ## The two targets
///
/// Firestore's Listen takes TARGETS, and for a subcollection there are two kinds
/// to choose from: a `DocumentsTarget` (an explicit list of document names) or a
/// `QueryTarget` (a `StructuredQuery`). Document targets are unusable here — the
/// whole point is to hear about `events/{seq}` documents that do not exist yet —
/// so both targets are QUERY targets over the match document's subcollections,
/// and they mirror the poll's two queries exactly:
///
///   * `events` where `seq > cursor`, ordered by `seq` ascending;
///   * `rolls`  where `n >= floor`,   ordered by `n` ascending.
///
/// The inequality is not decoration: it is the read budget. A bare
/// collection target re-delivers (and re-bills) every existing document the
/// moment the stream opens, so the cursor is what makes a rejoin cost the tail of
/// the log instead of all of it. The `orderBy` is required by Firestore for a
/// query with an inequality filter, and both fields are covered by the automatic
/// single-field indexes — no `firestore.indexes.json` entry is needed.
///
/// Note what the ordering does NOT buy: Listen makes no promise about the order
/// of `documentChange` messages within a snapshot. Ordering frames is the
/// consumer's job — see `FirestoreTransport`, which buffers to a snapshot
/// boundary and sorts.
///
/// ## Resume tokens
///
/// Every snapshot boundary carries a `resume_token`. Re-opening a target with its
/// token asks Firestore for the changes SINCE that token rather than the current
/// result set, which is the cheap way back after a dropped connection. A token is
/// bound to the query that produced it, so it may only be replayed against a
/// byte-identical target — and since our targets embed a moving cursor, the
/// consumer has to decide (see `FirestoreTransport._listenTargets`). It is never
/// wrong to drop a token; it just costs one re-delivery of whatever the query
/// currently matches.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';

import 'firestore_value.dart';
import 'online_config.dart';
import 'proto_codec.dart';

// ---------------------------------------------------------------------------
// Targets
// ---------------------------------------------------------------------------

/// One query target: a subcollection of one document, filtered from an index.
class ListenTarget {
  const ListenTarget({
    required this.targetId,
    required this.parentPath,
    required this.collectionId,
    required this.field,
    required this.from,
    required this.inclusive,
    this.resumeToken,
  });

  /// Client-chosen id, echoed back on every change for this target.
  final int targetId;

  /// The parent document, RELATIVE to the documents root (e.g. `matches/ABCD`).
  /// The channel prefixes it with the project's resource path.
  final String parentPath;

  /// The subcollection to watch (`events` / `rolls`).
  final String collectionId;

  /// The integer field the filter and the ordering both use (`seq` / `n`).
  final String field;

  /// The lower bound for [field].
  final int from;

  /// True for `>= from`, false for `> from`.
  final bool inclusive;

  /// A token from a previous snapshot of an IDENTICAL target, or null to (re-)read
  /// the current result set.
  final Uint8List? resumeToken;
}

// ---------------------------------------------------------------------------
// Deltas
// ---------------------------------------------------------------------------

/// One decoded `ListenResponse`.
sealed class ListenDelta {
  const ListenDelta();

  /// The targets this delta concerns. EMPTY means "every target" — Firestore's
  /// own convention for a `targetChange` with no ids.
  List<int> get targetIds;
}

/// A document was created or changed (`documentChange`).
class ListenDocument extends ListenDelta {
  const ListenDocument({
    required this.name,
    required this.fields,
    required this.targetIds,
  });

  /// The document's full resource name.
  final String name;

  /// Fields already decoded to plain Dart by `firestore_value.dart` — the SAME
  /// decoder the REST path uses, so `RemoteEvent.fromFields` / `RollDoc.fromFields`
  /// cannot disagree between the two paths.
  final Map<String, Object?> fields;

  @override
  final List<int> targetIds;

  /// The last path segment — the document id.
  String get id => name.substring(name.lastIndexOf('/') + 1);
}

/// A document left the result set (`documentDelete` / `documentRemove`).
class ListenDocumentGone extends ListenDelta {
  const ListenDocumentGone({required this.name, required this.targetIds});

  final String name;

  @override
  final List<int> targetIds;
}

/// Firestore acknowledged a target (`targetChange: ADD`).
class ListenTargetAdded extends ListenDelta {
  const ListenTargetAdded(this.targetIds);

  @override
  final List<int> targetIds;
}

/// A consistent snapshot boundary (`targetChange: NO_CHANGE` or `CURRENT`).
///
/// Everything delivered since the previous boundary forms one atomic view, which
/// is what lets the consumer sort a batch before publishing it. [current] marks
/// the first such boundary for a target — the point at which the listener has
/// caught up and polling can stop.
class ListenSnapshot extends ListenDelta {
  const ListenSnapshot({
    required this.targetIds,
    required this.current,
    this.resumeToken,
  });

  @override
  final List<int> targetIds;

  final bool current;

  /// The token to resume this snapshot from, if the server sent one.
  final Uint8List? resumeToken;
}

/// `targetChange: RESET` — "forget what you have for this target, I am about to
/// resend it".
///
/// NOT a match-identity change: see the RESET note on `FirestoreTransport`.
class ListenTargetReset extends ListenDelta {
  const ListenTargetReset(this.targetIds);

  @override
  final List<int> targetIds;
}

/// `targetChange: REMOVE` — the server dropped the target, with [cause]
/// explaining why (a rules refusal, an expired token, an invalid query).
class ListenTargetRemoved extends ListenDelta {
  const ListenTargetRemoved(this.targetIds, {this.cause});

  @override
  final List<int> targetIds;

  final String? cause;
}

// ---------------------------------------------------------------------------
// The channel
// ---------------------------------------------------------------------------

/// A source of [ListenDelta]s for a set of targets.
///
/// One instance carries ONE stream: after the stream ends (for any reason) the
/// channel is spent and the consumer builds a new one from its factory. That
/// keeps reconnection logic entirely in the consumer, and makes the whole
/// listener path fakeable with a `StreamController`.
abstract class FirestoreListenChannel {
  /// Open the stream. Errors on the returned stream (including a `GrpcError`)
  /// mean the listener is down; the stream closing means the same.
  Stream<ListenDelta> listen(List<ListenTarget> targets);

  /// Tear the stream and its connection down. Idempotent.
  Future<void> close();
}

/// Builds a fresh [FirestoreListenChannel]. Null anywhere this appears means
/// "no listener — poll instead".
typedef FirestoreListenChannelFactory = FirestoreListenChannel Function();

/// The real channel: a `Listen` bidi stream over gRPC.
class GrpcFirestoreListenChannel implements FirestoreListenChannel {
  GrpcFirestoreListenChannel({
    required this.config,
    required this.token,
    ClientChannel? channel,
  }) : _channel = channel;

  final OnlineConfig config;

  /// Supplies a fresh (auto-refreshing) idToken — `AuthClient.validToken`.
  final Future<String> Function() token;

  ClientChannel? _channel;
  ClientCall<List<int>, Uint8List>? _call;
  StreamController<List<int>>? _requests;
  bool _closed = false;

  /// The RPC, with the identity function for a serialiser: the bodies are
  /// already protobuf bytes (see `proto_codec.dart`).
  static final ClientMethod<List<int>, Uint8List> _listen =
      ClientMethod<List<int>, Uint8List>(
    '/google.firestore.v1.Firestore/Listen',
    (List<int> request) => request,
    (List<int> response) =>
        response is Uint8List ? response : Uint8List.fromList(response),
  );

  @override
  Stream<ListenDelta> listen(List<ListenTarget> targets) {
    if (_closed) {
      throw StateError('this listen channel has already been closed');
    }
    final channel = _channel ??= ClientChannel(
      config.firestoreGrpcHost,
      port: config.firestoreGrpcPort,
      options: ChannelOptions(
        credentials: config.firestoreGrpcSecure
            ? const ChannelCredentials.secure()
            : const ChannelCredentials.insecure(),
        // A watch stream is idle by design — that is the whole point — so the
        // channel must not be reaped for being quiet.
        idleTimeout: null,
      ),
    );

    // The request stream stays OPEN for the life of the call: this is a bidi RPC
    // and closing it would end the watch.
    final requests = _requests = StreamController<List<int>>();
    final call = _call = channel.createCall(
      _listen,
      requests.stream,
      CallOptions(
        metadata: {
          // The two headers Firestore routes on. Without the resource prefix the
          // backend cannot tell which database the stream is for.
          'google-cloud-resource-prefix': config.firestoreDatabaseName,
          'x-goog-request-params':
              'database=${Uri.encodeComponent(config.firestoreDatabaseName)}',
        },
        // A provider rather than static metadata, so a token that expires
        // between reconnects is refreshed for the NEXT call instead of
        // reconnecting with a dead one.
        providers: [
          (metadata, _) async {
            metadata['authorization'] = 'Bearer ${await token()}';
          },
        ],
      ),
    );

    for (final target in targets) {
      requests.add(encodeListenRequest(
        database: config.firestoreDatabaseName,
        documentsPrefix: config.documentsResourcePrefix,
        target: target,
      ));
    }

    return call.response
        .map(decodeListenResponse)
        .where((delta) => delta != null)
        .cast<ListenDelta>();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _requests?.close();
    _requests = null;
    // cancel() surfaces a "cancelled" error on the response stream; the consumer
    // is already tearing down, and it guards on its own disposed flag.
    await _call?.cancel().catchError((_) {});
    _call = null;
    await _channel?.shutdown().catchError((_) {});
    _channel = null;
  }
}

// ---------------------------------------------------------------------------
// Encoding — google.firestore.v1.ListenRequest
// ---------------------------------------------------------------------------

/// One `ListenRequest` carrying an `add_target`.
///
/// Field numbers are from `google/firestore/v1/firestore.proto` and
/// `query.proto`; each is named in a comment next to its use, because a wrong
/// number here fails as an opaque `INVALID_ARGUMENT` a long way from the cause.
Uint8List encodeListenRequest({
  required String database,
  required String documentsPrefix,
  required ListenTarget target,
}) {
  final request = ProtoWriter()
    ..string(1, database) // ListenRequest.database
    ..message(2, _encodeTarget(documentsPrefix, target)); // .add_target
  return request.toBytes();
}

ProtoWriter _encodeTarget(String documentsPrefix, ListenTarget target) {
  final query = ProtoWriter()
    ..string(1, '$documentsPrefix/${target.parentPath}') // QueryTarget.parent
    ..message(2, _encodeStructuredQuery(target)); // .structured_query

  final out = ProtoWriter()..message(2, query); // Target.query
  final token = target.resumeToken;
  if (token != null && token.isNotEmpty) {
    out.bytes(4, token); // Target.resume_token
  }
  out.integer(5, target.targetId); // Target.target_id
  return out;
}

/// `StructuredQuery`: `from` the subcollection, `where field {>|>=} from`,
/// `order by field ascending`.
ProtoWriter _encodeStructuredQuery(ListenTarget target) {
  // CollectionSelector.collection_id = 2
  final from = ProtoWriter()..string(2, target.collectionId);

  // FieldReference.field_path = 2
  ProtoWriter fieldRef() => ProtoWriter()..string(2, target.field);

  // Value.integer_value = 2
  final bound = ProtoWriter()..integer(2, target.from);

  // FieldFilter{field=1, op=2, value=3}; Operator GREATER_THAN=3,
  // GREATER_THAN_OR_EQUAL=4.
  final fieldFilter = ProtoWriter()
    ..message(1, fieldRef())
    ..integer(2, target.inclusive ? 4 : 3)
    ..message(3, bound);

  // Filter.field_filter = 2
  final where = ProtoWriter()..message(2, fieldFilter);

  // Order{field=1, direction=2}; ASCENDING=1.
  final order = ProtoWriter()
    ..message(1, fieldRef())
    ..integer(2, 1);

  return ProtoWriter()
    ..message(2, from) // StructuredQuery.from
    ..message(3, where) // .where
    ..message(4, order); // .order_by
}

// ---------------------------------------------------------------------------
// Decoding — google.firestore.v1.ListenResponse
// ---------------------------------------------------------------------------

/// Decode one `ListenResponse`, or null for a response type we do not model
/// (`ExistenceFilter`, or anything Firestore adds later).
///
/// Ignoring `ExistenceFilter` is safe HERE and only here: it is an optimisation
/// hint that lets a client detect documents it holds which the server no longer
/// has, and nothing in this model is ever deleted mid-match.
ListenDelta? decodeListenResponse(Uint8List body) {
  final reader = ProtoReader(body);
  while (reader.hasNext) {
    final tag = reader.readTag();
    switch (tag >> 3) {
      case 2:
        return _decodeTargetChange(reader.readMessage());
      case 3:
        return _decodeDocumentChange(reader.readMessage());
      case 4:
        return _decodeDocumentGone(reader.readMessage(), removedField: 6);
      case 6:
        return _decodeDocumentGone(reader.readMessage(), removedField: 2);
      default:
        reader.skip(tag & 7);
    }
  }
  return null;
}

ListenDelta _decodeTargetChange(ProtoReader reader) {
  var type = 0;
  final ids = <int>[];
  Uint8List? token;
  String? cause;
  while (reader.hasNext) {
    final tag = reader.readTag();
    final wire = tag & 7;
    switch (tag >> 3) {
      case 1:
        type = reader.readVarint(); // target_change_type
      case 2:
        reader.readIntegers(wire, ids); // target_ids
      case 3:
        cause = _decodeStatus(reader.readMessage()); // google.rpc.Status
      case 4:
        token = reader.readBytes(); // resume_token
      default:
        reader.skip(wire);
    }
  }
  return switch (type) {
    1 => ListenTargetAdded(ids), // ADD
    2 => ListenTargetRemoved(ids, cause: cause), // REMOVE
    3 => ListenSnapshot(targetIds: ids, current: true, resumeToken: token),
    4 => ListenTargetReset(ids), // RESET
    _ => ListenSnapshot(targetIds: ids, current: false, resumeToken: token),
  };
}

/// `google.rpc.Status{code = 1, message = 2}`, rendered for a status reason.
String _decodeStatus(ProtoReader reader) {
  var code = 0;
  var message = '';
  while (reader.hasNext) {
    final tag = reader.readTag();
    final wire = tag & 7;
    switch (tag >> 3) {
      case 1:
        code = reader.readVarint();
      case 2:
        message = reader.readString();
      default:
        reader.skip(wire);
    }
  }
  return message.isEmpty ? 'status $code' : '$message (status $code)';
}

ListenDelta _decodeDocumentChange(ProtoReader reader) {
  var name = '';
  var fields = const <String, Object?>{};
  final ids = <int>[];
  while (reader.hasNext) {
    final tag = reader.readTag();
    final wire = tag & 7;
    switch (tag >> 3) {
      case 1:
        final document = _decodeDocument(reader.readMessage());
        name = document.name;
        fields = document.fields;
      case 5:
        reader.readIntegers(wire, ids); // target_ids
      default:
        reader.skip(wire);
    }
  }
  return ListenDocument(name: name, fields: fields, targetIds: ids);
}

/// `DocumentDelete` and `DocumentRemove` differ only in which field number
/// carries `removed_target_ids` (6 and 2 respectively).
ListenDelta _decodeDocumentGone(ProtoReader reader, {required int removedField}) {
  var name = '';
  final ids = <int>[];
  while (reader.hasNext) {
    final tag = reader.readTag();
    final wire = tag & 7;
    final field = tag >> 3;
    if (field == 1) {
      name = reader.readString();
    } else if (field == removedField) {
      reader.readIntegers(wire, ids);
    } else {
      reader.skip(wire);
    }
  }
  return ListenDocumentGone(name: name, targetIds: ids);
}

({String name, Map<String, Object?> fields}) _decodeDocument(
    ProtoReader reader) {
  var name = '';
  final fields = <String, Object?>{};
  while (reader.hasNext) {
    final tag = reader.readTag();
    final wire = tag & 7;
    switch (tag >> 3) {
      case 1:
        name = reader.readString(); // Document.name
      case 2:
        // Document.fields is a proto map: one message per entry, key=1, value=2.
        final entry = reader.readMessage();
        var key = '';
        var typed = const <String, Object?>{'nullValue': null};
        while (entry.hasNext) {
          final entryTag = entry.readTag();
          final entryWire = entryTag & 7;
          switch (entryTag >> 3) {
            case 1:
              key = entry.readString();
            case 2:
              typed = protoValueToTypedValue(entry.readMessage());
            default:
              entry.skip(entryWire);
          }
        }
        fields[key] = fromFirestoreValue(typed);
      default:
        reader.skip(wire);
    }
  }
  return (name: name, fields: fields);
}

/// Re-shape a `google.firestore.v1.Value` into the REST "typed value" map.
///
/// This is the join between the two transports: rather than growing a second
/// decoder for the gRPC path, a proto `Value` is rendered as exactly the
/// `{"integerValue": "3"}` shape the REST API sends, and `firestore_value.dart`
/// stays the ONE place that turns Firestore values into Dart ones. (It is also
/// literally what protobuf's own JSON mapping does with a `oneof`.)
///
/// Types the game model never stores — bytes, geo points, references, and
/// anything added to `Value` after this was written — decode as null rather than
/// throwing, so one exotic field cannot kill a live match's stream.
Map<String, Object?> protoValueToTypedValue(ProtoReader reader) {
  while (reader.hasNext) {
    final tag = reader.readTag();
    final wire = tag & 7;
    switch (tag >> 3) {
      case 11: // null_value
        reader.readVarint();
        return const {'nullValue': null};
      case 1: // boolean_value
        return {'booleanValue': reader.readVarint() != 0};
      case 2: // integer_value
        return {'integerValue': reader.readVarint().toString()};
      case 3: // double_value
        return {'doubleValue': reader.readDouble()};
      case 10: // timestamp_value
        return {'timestampValue': _decodeTimestamp(reader.readMessage())};
      case 17: // string_value
        return {'stringValue': reader.readString()};
      case 9: // array_value
        final array = reader.readMessage();
        final values = <Map<String, Object?>>[];
        while (array.hasNext) {
          final itemTag = array.readTag();
          if (itemTag >> 3 == 1) {
            values.add(protoValueToTypedValue(array.readMessage()));
          } else {
            array.skip(itemTag & 7);
          }
        }
        return {
          'arrayValue': {'values': values},
        };
      case 6: // map_value
        final map = reader.readMessage();
        final entries = <String, Object?>{};
        while (map.hasNext) {
          final mapTag = map.readTag();
          if (mapTag >> 3 != 1) {
            map.skip(mapTag & 7);
            continue;
          }
          final entry = map.readMessage();
          var key = '';
          var typed = const <String, Object?>{'nullValue': null};
          while (entry.hasNext) {
            final entryTag = entry.readTag();
            switch (entryTag >> 3) {
              case 1:
                key = entry.readString();
              case 2:
                typed = protoValueToTypedValue(entry.readMessage());
              default:
                entry.skip(entryTag & 7);
            }
          }
          entries[key] = typed;
        }
        return {
          'mapValue': {'fields': entries},
        };
      default:
        reader.skip(wire);
    }
  }
  return const {'nullValue': null};
}

/// `google.protobuf.Timestamp{seconds = 1, nanos = 2}` as the RFC-3339 string
/// `fromFirestoreValue` parses.
String _decodeTimestamp(ProtoReader reader) {
  var seconds = 0;
  var nanos = 0;
  while (reader.hasNext) {
    final tag = reader.readTag();
    final wire = tag & 7;
    switch (tag >> 3) {
      case 1:
        seconds = reader.readVarint();
      case 2:
        nanos = reader.readVarint();
      default:
        reader.skip(wire);
    }
  }
  final at = DateTime.fromMillisecondsSinceEpoch(
    seconds * 1000 + nanos ~/ 1000000,
    isUtc: true,
  );
  return at.toIso8601String();
}
