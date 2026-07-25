import 'dart:convert';

import 'package:http/http.dart' as http;

import 'firestore_value.dart';
import 'online_config.dart';
import 'online_exception.dart';

/// Minimal Firestore REST v1 client — exactly the reads [MatchApi] needs.
///
/// All requests carry a bearer token supplied by [token] (typically
/// `AuthClient.validToken`). Writes go exclusively through Cloud Functions
/// callables (see [FunctionsClient]); this client is read-only.
class FirestoreRestClient {
  final OnlineConfig config;
  final Future<String> Function() _token;
  final http.Client _http;

  FirestoreRestClient(
    this.config, {
    required Future<String> Function() token,
    http.Client? inner,
  })  : _token = token,
        _http = inner ?? http.Client();

  Future<Map<String, String>> _headers() async => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${await _token()}',
      };

  /// Fetch the document at [path] (relative to the `documents` root, e.g.
  /// `matches/abc`). Returns its decoded fields, or null on 404.
  Future<Map<String, Object?>?> getDocument(String path) async {
    final url = Uri.parse('${config.firestoreDocumentsBase}/$path');
    final res = await _http.get(url, headers: await _headers());
    if (res.statusCode == 404) return null;
    final body = _decodeOrThrow(res);
    final fields = body['fields'] as Map<String, Object?>?;
    return fields == null ? <String, Object?>{} : decodeFields(fields);
  }

  /// Run a structured query over the subcollection [collectionId] under
  /// [parentPath] (relative to the `documents` root, e.g. `matches/abc`).
  ///
  /// When [whereIntGreaterThan] is given, filters `field > value`; when
  /// [orderByField] is given, orders ascending by it. Returns each matched
  /// document's decoded fields, in query order.
  Future<List<Map<String, Object?>>> runQuery(
    String parentPath,
    String collectionId, {
    (String field, int value)? whereIntGreaterThan,
    String? orderByField,
  }) async {
    final structuredQuery = <String, Object?>{
      'from': [
        {'collectionId': collectionId},
      ],
    };
    if (whereIntGreaterThan != null) {
      structuredQuery['where'] = {
        'fieldFilter': {
          'field': {'fieldPath': whereIntGreaterThan.$1},
          'op': 'GREATER_THAN',
          'value': {'integerValue': whereIntGreaterThan.$2.toString()},
        },
      };
    }
    if (orderByField != null) {
      structuredQuery['orderBy'] = [
        {
          'field': {'fieldPath': orderByField},
          'direction': 'ASCENDING',
        },
      ];
    }

    final url = Uri.parse('${config.firestoreDocumentsBase}/$parentPath:runQuery');
    final res = await _http.post(
      url,
      headers: await _headers(),
      body: jsonEncode({'structuredQuery': structuredQuery}),
    );
    final decoded = _decodeListOrThrow(res);
    final out = <Map<String, Object?>>[];
    for (final row in decoded) {
      if (row is! Map) continue;
      final doc = row['document'];
      if (doc is! Map) continue; // read-time-only rows carry no document
      final fields = doc['fields'] as Map<String, Object?>?;
      out.add(fields == null ? <String, Object?>{} : decodeFields(fields));
    }
    return out;
  }

  Map<String, Object?> _decodeOrThrow(http.Response res) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw _errorFor(res);
    }
    return jsonDecode(res.body) as Map<String, Object?>;
  }

  List<Object?> _decodeListOrThrow(http.Response res) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw _errorFor(res);
    }
    return jsonDecode(res.body) as List<Object?>;
  }

  OnlineException _errorFor(http.Response res) {
    try {
      final body = jsonDecode(res.body);
      final err = body is Map ? body['error'] : null;
      if (err is Map) {
        return OnlineException(
          err['status']?.toString() ?? 'http-${res.statusCode}',
          err['message']?.toString() ?? res.body,
        );
      }
    } catch (_) {
      // fall through to raw
    }
    return OnlineException('http-${res.statusCode}', res.body);
  }

  /// Close the underlying HTTP client.
  void close() => _http.close();
}
