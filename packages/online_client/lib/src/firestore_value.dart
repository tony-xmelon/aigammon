/// Encode/decode helpers for Firestore REST "typed value" JSON.
///
/// The REST API wraps every field in a single-key object naming its type, e.g.
/// `{"integerValue":"3"}`, `{"stringValue":"hi"}`, `{"mapValue":{"fields":{...}}}`.
/// These helpers convert between that representation and plain Dart values.
library;

/// Convert a plain Dart value into a Firestore typed-value map.
///
/// Supported: `null`, [bool], [int], [double], [String], [DateTime] (encoded as
/// `timestampValue`), [List] (recursively), and `Map<String, ...>` (recursively,
/// as `mapValue`). Throws [ArgumentError] for anything else.
Map<String, Object?> toFirestoreValue(Object? value) {
  if (value == null) return {'nullValue': null};
  if (value is bool) return {'booleanValue': value};
  if (value is int) return {'integerValue': value.toString()};
  if (value is double) return {'doubleValue': value};
  if (value is String) return {'stringValue': value};
  if (value is DateTime) {
    return {'timestampValue': value.toUtc().toIso8601String()};
  }
  if (value is List) {
    return {
      'arrayValue': {
        'values': [for (final e in value) toFirestoreValue(e)],
      },
    };
  }
  if (value is Map) {
    return {
      'mapValue': {
        'fields': {
          for (final entry in value.entries)
            entry.key.toString(): toFirestoreValue(entry.value),
        },
      },
    };
  }
  throw ArgumentError('unsupported Firestore value: ${value.runtimeType}');
}

/// Convert a Firestore typed-value map back into a plain Dart value.
///
/// `integerValue` decodes to [int], `doubleValue` to [double], `timestampValue`
/// to a UTC [DateTime], `mapValue`/`arrayValue` recursively. Throws
/// [FormatException] on an unrecognised or malformed wrapper.
Object? fromFirestoreValue(Map<String, Object?> value) {
  if (value.containsKey('nullValue')) return null;
  if (value.containsKey('booleanValue')) return value['booleanValue'] as bool;
  if (value.containsKey('integerValue')) {
    final raw = value['integerValue'];
    return raw is int ? raw : int.parse(raw as String);
  }
  if (value.containsKey('doubleValue')) {
    return (value['doubleValue'] as num).toDouble();
  }
  if (value.containsKey('stringValue')) return value['stringValue'] as String;
  if (value.containsKey('timestampValue')) {
    return DateTime.parse(value['timestampValue'] as String).toUtc();
  }
  if (value.containsKey('mapValue')) {
    final map = value['mapValue'] as Map<String, Object?>?;
    final fields = (map?['fields'] as Map<String, Object?>?) ?? const {};
    return {
      for (final entry in fields.entries)
        entry.key: fromFirestoreValue(entry.value as Map<String, Object?>),
    };
  }
  if (value.containsKey('arrayValue')) {
    final arr = value['arrayValue'] as Map<String, Object?>?;
    final values = (arr?['values'] as List?) ?? const [];
    return [
      for (final e in values) fromFirestoreValue(e as Map<String, Object?>),
    ];
  }
  throw FormatException('unrecognised Firestore value: $value');
}

/// Decode a document's `fields` object (a map of field-name → typed value) into
/// a plain `Map<String, Object?>`.
Map<String, Object?> decodeFields(Map<String, Object?> fields) => {
      for (final entry in fields.entries)
        entry.key: fromFirestoreValue(entry.value as Map<String, Object?>),
    };

/// Encode a plain field map into a Firestore `fields` object.
Map<String, Object?> encodeFields(Map<String, Object?> fields) => {
      for (final entry in fields.entries)
        entry.key: toFirestoreValue(entry.value),
    };
