import 'package:aigammon_app/data/database.dart';
import 'package:aigammon_app/online/online_session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_client/online_client.dart';

import '../data/test_database.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = newTestDatabase());
  tearDown(() => db.close());

  test('an empty store reads as no session', () async {
    final store = OnlineSessionStore(db);
    expect(await store.read(), isNull);
    expect(await store.lastMatchCode(), isNull);
  });

  test('the anonymous session survives a "restart" (a new store over the '
      'same database)', () async {
    // This is the whole point: the uid is what firestore.rules gates every
    // match document on, so losing it on relaunch strands both seats.
    await OnlineSessionStore(db)
        .write(const StoredSession(uid: 'uid-1', refreshToken: 'refresh-1'));

    final afterRestart = await OnlineSessionStore(db).read();
    expect(afterRestart,
        const StoredSession(uid: 'uid-1', refreshToken: 'refresh-1'));
  });

  test('a rotated refresh token replaces the stored one', () async {
    final store = OnlineSessionStore(db);
    await store
        .write(const StoredSession(uid: 'uid-1', refreshToken: 'refresh-1'));
    await store
        .write(const StoredSession(uid: 'uid-1', refreshToken: 'refresh-2'));
    expect((await store.read())!.refreshToken, 'refresh-2');
  });

  test('clear drops the credentials but KEEPS the match pointer', () async {
    // They answer different questions and expire on different terms: the token
    // is dead when the server says so, the pointer when the match ends.
    final store = OnlineSessionStore(db);
    await store
        .write(const StoredSession(uid: 'uid-1', refreshToken: 'refresh-1'));
    await store.rememberMatch('ABCD2345');

    await store.clear();

    expect(await store.read(), isNull);
    expect(await store.lastMatchCode(), 'ABCD2345');
  });

  test('the match pointer round-trips and can be forgotten', () async {
    final store = OnlineSessionStore(db);
    await store.rememberMatch('ABCD2345');
    expect(await OnlineSessionStore(db).lastMatchCode(), 'ABCD2345');

    await store.forgetMatch();
    expect(await store.lastMatchCode(), isNull);
  });

  test('a closed database degrades to nulls rather than throwing', () async {
    // A broken store must cost a fresh anonymous user, never a launch that
    // cannot sign in at all.
    final store = OnlineSessionStore(db);
    await db.close();

    expect(await store.read(), isNull);
    expect(await store.lastMatchCode(), isNull);
    await expectLater(
        store.write(
            const StoredSession(uid: 'u', refreshToken: 'r')),
        completes);
    await expectLater(store.forgetMatch(), completes);

    // Re-open one for the tearDown to close.
    db = newTestDatabase();
  });
}
