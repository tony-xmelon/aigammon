import 'package:aigammon_app/data/database.dart';
import 'package:drift/native.dart';

/// A fresh in-memory [AppDatabase] for tests.
///
/// [NativeDatabase.memory] loads the `sqlite3` native library. On this repo's
/// Windows dev host and on ubuntu-latest CI the library is available (the
/// `sqlite3` dev-dependency's loader finds the system lib / bundled binary), so
/// plain `flutter test` runs these without any device or override. If a host
/// ever lacks sqlite3, this call throws a clear "failed to load sqlite3" error
/// rather than skipping silently.
AppDatabase newTestDatabase() => AppDatabase(NativeDatabase.memory());
