import 'dart:convert';
import 'dart:typed_data';

import 'package:online_client/online_client.dart';
import 'package:online_client/src/proto_codec.dart';
import 'package:test/test.dart';

/// The Firestore `Listen` WIRE format: the hand-rolled protobuf codec, the two
/// query targets we send, and the six response shapes we decode.
///
/// These tests are about STRUCTURE, and they are deliberately paranoid about it:
/// a wrong field number is invisible in Dart and surfaces at the far end as an
/// opaque `INVALID_ARGUMENT`, so the encoder is asserted down to individual bytes
/// where the byte is short enough to read, and decoded field-by-field where it is
/// not. Whether Firestore AGREES with these numbers is proven by
/// `emulator_integration_test.dart`, which runs the same encoder against a real
/// Firestore.
void main() {
  // =========================================================================
  group('protobuf primitives', () {
    test('a small varint field is tag-then-value', () {
      // field 1, wire type 0 → tag 0x08; value 1.
      expect((ProtoWriter()..integer(1, 1)).toBytes(), [0x08, 0x01]);
      // field 5, wire type 0 → tag 0x28; 300 spans two bytes.
      expect((ProtoWriter()..integer(5, 300)).toBytes(), [0x28, 0xac, 0x02]);
    });

    test('a NEGATIVE varint is the full ten-byte two\'s complement', () {
      // Not academic: the events target really does filter `seq > -1` to mean
      // "the whole log", and a naive 7-bit loop would encode that as nothing.
      expect(
        (ProtoWriter()..integer(1, -1)).toBytes(),
        [0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01],
      );
      final reader = ProtoReader((ProtoWriter()..integer(1, -1)).toBytes());
      expect(reader.readTag() >> 3, 1);
      expect(reader.readVarint(), -1);
    });

    test('strings, bytes, bools, doubles and nested messages round-trip', () {
      final nested = ProtoWriter()..string(2, 'inner');
      final bytes = (ProtoWriter()
            ..string(1, 'héllo')
            ..boolean(2, true)
            ..bytes(3, const [1, 2, 3])
            ..float(4, 1.5)
            ..message(5, nested))
          .toBytes();

      final reader = ProtoReader(bytes);
      expect(reader.readTag() >> 3, 1);
      expect(reader.readString(), 'héllo');
      expect(reader.readTag() >> 3, 2);
      expect(reader.readVarint(), 1);
      expect(reader.readTag() >> 3, 3);
      expect(reader.readBytes(), [1, 2, 3]);
      expect(reader.readTag() >> 3, 4);
      expect(reader.readDouble(), 1.5);
      expect(reader.readTag() >> 3, 5);
      final sub = reader.readMessage();
      expect(sub.readTag() >> 3, 2);
      expect(sub.readString(), 'inner');
      expect(sub.hasNext, isFalse, reason: 'a sub-reader is bounded');
      expect(reader.hasNext, isFalse);
    });

    test('an unknown field is skipped, whatever its wire type', () {
      // Forward compatibility: Firestore may add fields to any of these messages
      // and every decoder here must sail past them.
      final bytes = (ProtoWriter()
            ..integer(7, 99)
            ..string(8, 'ignored')
            ..float(9, 2.5)
            ..integer(1, 42))
          .toBytes();
      final reader = ProtoReader(bytes);
      var found = 0;
      while (reader.hasNext) {
        final tag = reader.readTag();
        if (tag >> 3 == 1) {
          found = reader.readVarint();
        } else {
          reader.skip(tag & 7);
        }
      }
      expect(found, 42);
    });

    test('a truncated field is a FormatException, not a silent zero', () {
      final reader = ProtoReader(Uint8List.fromList([0x0a, 0x05, 1, 2]));
      reader.readTag();
      expect(reader.readBytes, throwsA(isA<FormatException>()));
      expect(() => ProtoReader(Uint8List.fromList([0xff])).readVarint(),
          throwsA(isA<FormatException>()));
    });

    test('a repeated int field decodes packed AND unpacked', () {
      // proto3 packs by default, but one-varint-per-occurrence is legal too and
      // `target_ids` has been seen both ways.
      final packed = (ProtoWriter()..bytes(2, const [1, 2, 3])).toBytes();
      final loose = (ProtoWriter()
            ..integer(2, 1)
            ..integer(2, 2)
            ..integer(2, 3))
          .toBytes();
      for (final body in [packed, loose]) {
        final reader = ProtoReader(body);
        final ids = <int>[];
        while (reader.hasNext) {
          final tag = reader.readTag();
          reader.readIntegers(tag & 7, ids);
        }
        expect(ids, [1, 2, 3]);
      }
    });
  });

  // =========================================================================
  group('ListenRequest', () {
    /// Decodes the parts of a `ListenRequest` these tests assert on, using only
    /// the field numbers from `firestore.proto` / `query.proto`.
    _Request decodeRequest(Uint8List body) {
      var database = '';
      var parent = '';
      var collection = '';
      var field = '';
      var op = 0;
      var from = 0;
      var orderField = '';
      var direction = 0;
      var targetId = -1;
      Uint8List? token;

      final request = ProtoReader(body);
      while (request.hasNext) {
        final tag = request.readTag();
        switch (tag >> 3) {
          case 1:
            database = request.readString();
          case 2:
            final target = request.readMessage();
            while (target.hasNext) {
              final targetTag = target.readTag();
              switch (targetTag >> 3) {
                case 2: // Target.query
                  final query = target.readMessage();
                  while (query.hasNext) {
                    final queryTag = query.readTag();
                    switch (queryTag >> 3) {
                      case 1:
                        parent = query.readString();
                      case 2: // structured_query
                        final sq = query.readMessage();
                        while (sq.hasNext) {
                          final sqTag = sq.readTag();
                          switch (sqTag >> 3) {
                            case 2: // from
                              final sel = sq.readMessage();
                              sel.readTag();
                              collection = sel.readString();
                            case 3: // where
                              final where = sq.readMessage();
                              expect(where.readTag() >> 3, 2,
                                  reason: 'Filter.field_filter');
                              final ff = where.readMessage();
                              while (ff.hasNext) {
                                final ffTag = ff.readTag();
                                switch (ffTag >> 3) {
                                  case 1:
                                    final ref = ff.readMessage();
                                    ref.readTag();
                                    field = ref.readString();
                                  case 2:
                                    op = ff.readVarint();
                                  case 3:
                                    final value = ff.readMessage();
                                    expect(value.readTag() >> 3, 2,
                                        reason: 'Value.integer_value');
                                    from = value.readVarint();
                                  default:
                                    ff.skip(ffTag & 7);
                                }
                              }
                            case 4: // order_by
                              final order = sq.readMessage();
                              while (order.hasNext) {
                                final orderTag = order.readTag();
                                switch (orderTag >> 3) {
                                  case 1:
                                    final ref = order.readMessage();
                                    ref.readTag();
                                    orderField = ref.readString();
                                  case 2:
                                    direction = order.readVarint();
                                  default:
                                    order.skip(orderTag & 7);
                                }
                              }
                            default:
                              sq.skip(sqTag & 7);
                          }
                        }
                      default:
                        query.skip(queryTag & 7);
                    }
                  }
                case 4:
                  token = target.readBytes();
                case 5:
                  targetId = target.readVarint();
                default:
                  target.skip(targetTag & 7);
              }
            }
          default:
            request.skip(tag & 7);
        }
      }
      return _Request(
        database: database,
        parent: parent,
        collection: collection,
        field: field,
        op: op,
        from: from,
        orderField: orderField,
        direction: direction,
        targetId: targetId,
        resumeToken: token,
      );
    }

    test('the events target is a subcollection QUERY, not a document list', () {
      // A document target cannot express "tell me about events/{seq} documents
      // that do not exist yet", which is the entire job.
      final decoded = decodeRequest(encodeListenRequest(
        database: 'projects/demo/databases/(default)',
        documentsPrefix: 'projects/demo/databases/(default)/documents',
        target: const ListenTarget(
          targetId: 1,
          parentPath: 'matches/ABCD1234',
          collectionId: 'events',
          field: 'seq',
          from: -1,
          inclusive: false,
        ),
      ));

      expect(decoded.database, 'projects/demo/databases/(default)');
      expect(decoded.parent,
          'projects/demo/databases/(default)/documents/matches/ABCD1234');
      expect(decoded.collection, 'events');
      expect(decoded.field, 'seq');
      expect(decoded.op, 3, reason: 'FieldFilter.Operator.GREATER_THAN');
      expect(decoded.from, -1, reason: 'seq > -1 is the whole log');
      expect(decoded.orderField, 'seq',
          reason: 'Firestore requires the inequality field to be ordered first');
      expect(decoded.direction, 1, reason: 'ASCENDING');
      expect(decoded.targetId, 1);
      expect(decoded.resumeToken, isNull);
    });

    test('the rolls target is INCLUSIVE, because a roll floor is not consumed',
        () {
      final decoded = decodeRequest(encodeListenRequest(
        database: 'projects/demo/databases/(default)',
        documentsPrefix: 'projects/demo/databases/(default)/documents',
        target: const ListenTarget(
          targetId: 2,
          parentPath: 'matches/ABCD1234',
          collectionId: 'rolls',
          field: 'n',
          from: 4,
          inclusive: true,
        ),
      ));
      expect(decoded.collection, 'rolls');
      expect(decoded.field, 'n');
      expect(decoded.op, 4,
          reason: 'GREATER_THAN_OR_EQUAL — roll 4 may still change');
      expect(decoded.from, 4);
      expect(decoded.targetId, 2);
    });

    test('a resume token rides along on the target', () {
      final decoded = decodeRequest(encodeListenRequest(
        database: 'projects/demo/databases/(default)',
        documentsPrefix: 'projects/demo/databases/(default)/documents',
        target: ListenTarget(
          targetId: 1,
          parentPath: 'matches/ABCD1234',
          collectionId: 'events',
          field: 'seq',
          from: 7,
          inclusive: false,
          resumeToken: Uint8List.fromList(const [9, 8, 7]),
        ),
      ));
      expect(decoded.resumeToken, [9, 8, 7]);
      expect(decoded.from, 7, reason: 'a token is only valid for ITS query');
    });
  });

  // =========================================================================
  group('ListenResponse', () {
    test('a documentChange decodes through firestore_value.dart', () {
      // The one decoder rule: a proto Value is re-shaped into the REST typed
      // value and handed to the SAME decoder the REST path uses, so an event
      // document cannot mean two things.
      final delta = decodeListenResponse(_documentChange(
        name: 'projects/p/databases/(default)/documents/matches/C/events/'
            '00000003',
        fields: {
          'seq': _int(3),
          'gameNo': _int(1),
          'author': _string('uid-remote'),
          'event': _string(jsonEncode({'type': 'double', 'player': 'white'})),
        },
        targetIds: const [1],
      ));

      final doc = delta as ListenDocument;
      expect(doc.id, '00000003');
      expect(doc.targetIds, [1]);
      expect(doc.fields['seq'], 3, reason: 'integerValue decodes to int');
      expect(doc.fields['gameNo'], 1);
      expect(doc.fields['author'], 'uid-remote');
      // And it feeds the shipped document decoder unchanged.
      final row = RemoteEvent.fromFields(doc.fields);
      expect(row.seq, 3);
      expect(row.author, 'uid-remote');
    });

    test('every Value type the model can hold survives the reshaping', () {
      final delta = decodeListenResponse(_documentChange(
        name: 'projects/p/databases/(default)/documents/matches/C/rolls/'
            '00000001',
        fields: {
          'n': _int(1),
          'roller': _string('u'),
          'flag': (ProtoWriter()..boolean(1, true)),
          'blank': (ProtoWriter()..integer(11, 0)),
          'ratio': (ProtoWriter()..float(3, 0.5)),
          'stamp': (ProtoWriter()
            ..message(10, ProtoWriter()..integer(1, 1000000000))),
          'list': (ProtoWriter()
            ..message(
                9,
                ProtoWriter()
                  ..message(1, _int(1))
                  ..message(1, _int(2)))),
          'nested': (ProtoWriter()
            ..message(
                6,
                ProtoWriter()
                  ..message(
                      1,
                      ProtoWriter()
                        ..string(1, 'inner')
                        ..message(2, _string('v'))))),
        },
      )) as ListenDocument;

      expect(delta.fields['n'], 1);
      expect(delta.fields['flag'], isTrue);
      expect(delta.fields['blank'], isNull);
      expect(delta.fields['ratio'], 0.5);
      expect(delta.fields['stamp'],
          DateTime.utc(2001, 9, 9, 1, 46, 40), reason: 'timestampValue → UTC');
      expect(delta.fields['list'], [1, 2]);
      expect(delta.fields['nested'], {'inner': 'v'});
    });

    test('a Value type the model never stores decodes as null, not a crash', () {
      // One exotic field must not kill a live match's stream.
      final delta = decodeListenResponse(_documentChange(
        name: 'projects/p/databases/(default)/documents/matches/C/events/'
            '00000000',
        fields: {'blob': (ProtoWriter()..bytes(18, const [1, 2, 3]))},
      )) as ListenDocument;
      expect(delta.fields['blob'], isNull);
    });

    test('the five targetChange types map to five different deltas', () {
      ListenDelta change(int type, {List<int> ids = const [1], List<int>? token}) {
        final tc = ProtoWriter()..integer(1, type);
        for (final id in ids) {
          tc.integer(2, id);
        }
        if (token != null) tc.bytes(4, token);
        return decodeListenResponse(
            (ProtoWriter()..message(2, tc)).toBytes())!;
      }

      expect(change(0, token: const [1, 2]),
          isA<ListenSnapshot>().having((s) => s.current, 'current', isFalse));
      expect((change(0, token: const [1, 2]) as ListenSnapshot).resumeToken,
          [1, 2]);
      expect(change(1), isA<ListenTargetAdded>());
      expect(change(2), isA<ListenTargetRemoved>());
      expect(change(3, token: const [7]),
          isA<ListenSnapshot>().having((s) => s.current, 'current', isTrue));
      expect(change(4), isA<ListenTargetReset>());
    });

    test('a REMOVE carries its google.rpc.Status as a cause', () {
      final status = ProtoWriter()
        ..integer(1, 7)
        ..string(2, 'Missing or insufficient permissions.');
      final tc = ProtoWriter()
        ..integer(1, 2)
        ..integer(2, 1)
        ..message(3, status);
      final delta = decodeListenResponse(
          (ProtoWriter()..message(2, tc)).toBytes()) as ListenTargetRemoved;
      expect(delta.cause, contains('insufficient permissions'));
      expect(delta.cause, contains('7'));
      expect(delta.targetIds, [1]);
    });

    test('documentDelete and documentRemove differ only in a field number', () {
      // DocumentDelete.removed_target_ids = 6; DocumentRemove's = 2. Reading the
      // wrong one loses the target ids silently.
      final deleted = decodeListenResponse((ProtoWriter()
            ..message(
                4,
                ProtoWriter()
                  ..string(1, 'projects/p/databases/(default)/documents/x/y')
                  ..integer(6, 2)))
          .toBytes()) as ListenDocumentGone;
      expect(deleted.targetIds, [2]);
      expect(deleted.name, endsWith('/x/y'));

      final removed = decodeListenResponse((ProtoWriter()
            ..message(
                6,
                ProtoWriter()
                  ..string(1, 'projects/p/databases/(default)/documents/x/y')
                  ..integer(2, 1)))
          .toBytes()) as ListenDocumentGone;
      expect(removed.targetIds, [1]);
    });

    test('an ExistenceFilter (and anything unknown) decodes to null', () {
      // Nothing in this model is ever deleted, so the filter carries no
      // information we need; an unmodelled response must be ignored, never fatal.
      final filter = ProtoWriter()
        ..integer(1, 1)
        ..integer(2, 3);
      expect(decodeListenResponse((ProtoWriter()..message(5, filter)).toBytes()),
          isNull);
      expect(decodeListenResponse((ProtoWriter()..integer(99, 1)).toBytes()),
          isNull);
    });

    test('packed target_ids decode too', () {
      final tc = ProtoWriter()
        ..integer(1, 3)
        ..bytes(2, const [1, 2]);
      final delta =
          decodeListenResponse((ProtoWriter()..message(2, tc)).toBytes())
              as ListenSnapshot;
      expect(delta.targetIds, [1, 2]);
      expect(delta.current, isTrue);
    });
  });
}

// ---------------------------------------------------------------------------
// Fixtures: a "server" that writes ListenResponse bytes by hand.
// ---------------------------------------------------------------------------

ProtoWriter _int(int value) => ProtoWriter()..integer(2, value);

ProtoWriter _string(String value) => ProtoWriter()..string(17, value);

/// A `ListenResponse{document_change{document{name, fields}, target_ids}}`.
Uint8List _documentChange({
  required String name,
  required Map<String, ProtoWriter> fields,
  List<int> targetIds = const [1],
}) {
  final document = ProtoWriter()..string(1, name);
  for (final entry in fields.entries) {
    document.message(
      2,
      ProtoWriter()
        ..string(1, entry.key)
        ..message(2, entry.value),
    );
  }
  final change = ProtoWriter()..message(1, document);
  for (final id in targetIds) {
    change.integer(5, id);
  }
  return (ProtoWriter()..message(3, change)).toBytes();
}

class _Request {
  const _Request({
    required this.database,
    required this.parent,
    required this.collection,
    required this.field,
    required this.op,
    required this.from,
    required this.orderField,
    required this.direction,
    required this.targetId,
    required this.resumeToken,
  });

  final String database;
  final String parent;
  final String collection;
  final String field;
  final int op;
  final int from;
  final String orderField;
  final int direction;
  final int targetId;
  final Uint8List? resumeToken;
}
