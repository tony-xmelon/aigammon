import 'dart:convert';

import 'package:http/http.dart' as http;

import 'online_config.dart';
import 'online_exception.dart';

/// Invokes Cloud Functions callables over plain HTTP.
///
/// Callables use the `{"data": <payload>}` request envelope and reply with
/// either `{"result": <data>}` or `{"error": {"message","status"}}`. This client
/// maps both an error envelope and any non-2xx status to [OnlineException].
class FunctionsClient {
  final OnlineConfig config;
  final Future<String> Function() _token;
  final http.Client _http;

  FunctionsClient(
    this.config, {
    required Future<String> Function() token,
    http.Client? inner,
  })  : _token = token,
        _http = inner ?? http.Client();

  /// Call the callable named [name] with [data], returning the `result` payload.
  Future<Map<String, Object?>> call(
    String name,
    Map<String, Object?> data,
  ) async {
    final url = Uri.parse('${config.functionsBase}/$name');
    final res = await _http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${await _token()}',
      },
      body: jsonEncode({'data': data}),
    );

    Map<String, Object?> body;
    try {
      body = jsonDecode(res.body) as Map<String, Object?>;
    } catch (_) {
      throw OnlineException('http-${res.statusCode}', res.body);
    }

    final error = body['error'];
    if (error is Map) {
      throw OnlineException(
        error['status']?.toString() ?? 'http-${res.statusCode}',
        error['message']?.toString() ?? 'callable error',
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw OnlineException('http-${res.statusCode}', res.body);
    }

    final result = body['result'];
    if (result is Map<String, Object?>) return result;
    if (result is Map) return Map<String, Object?>.from(result);
    return <String, Object?>{'result': result};
  }

  /// Close the underlying HTTP client.
  void close() => _http.close();
}
