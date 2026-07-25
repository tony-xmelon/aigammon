import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';

import 'auth_client.dart';
import 'firestore_client.dart';
import 'functions_client.dart';
import 'online_exception.dart';

/// A client's claimed terminal result for a game, submitted alongside the
/// game-ending event. Matches the `{winner, points, outcome}` shape the
/// `submitEvent` callable validates (see firebase/functions/src/index.ts).
class GameResultClaim {
  final Player winner;
  final int points;
  final GameOutcome outcome;

  const GameResultClaim({
    required this.winner,
    required this.points,
    required this.outcome,
  });

  Map<String, Object?> toJson() => {
        'winner': winner.name,
        'points': points,
        'outcome': outcome.name,
      };
}

/// One stored event from a match's `events` subcollection, decoded.
///
/// The functions store an event's JSON fields FLAT in the doc alongside `seq`
/// and `gameNo` (see index.ts), so the whole field map round-trips through
/// [GameEvent.fromJson] (extra keys like `seq`/`gameNo`/`createdAt` are ignored).
class RemoteEvent {
  final int seq;
  final int gameNo;
  final GameEvent event;

  const RemoteEvent({
    required this.seq,
    required this.gameNo,
    required this.event,
  });

  /// Decode from a match-event document's field map.
  factory RemoteEvent.fromFields(Map<String, Object?> fields) => RemoteEvent(
        seq: (fields['seq'] as num).toInt(),
        gameNo: (fields['gameNo'] as num).toInt(),
        event: GameEvent.fromJson(Map<String, dynamic>.from(fields)),
      );
}

/// Decoded summary of a `matches/{id}` document.
class MatchSnapshot {
  final String status; // 'waiting' | 'active' | 'complete'
  final String code;
  final int matchLength;
  final int gameNo;
  final int seq;

  /// Seat → uid. `black` is absent (null) until an opponent joins.
  final String whiteUid;
  final String? blackUid;

  final int whiteScore;
  final int blackScore;

  final Player? turn;
  final GamePhase? phase;
  final bool isCrawford;
  final bool crawfordPlayed;
  final Player? winner;

  const MatchSnapshot({
    required this.status,
    required this.code,
    required this.matchLength,
    required this.gameNo,
    required this.seq,
    required this.whiteUid,
    required this.blackUid,
    required this.whiteScore,
    required this.blackScore,
    required this.turn,
    required this.phase,
    required this.isCrawford,
    required this.crawfordPlayed,
    required this.winner,
  });

  factory MatchSnapshot.fromFields(Map<String, Object?> f) {
    final seats = (f['seats'] as Map).cast<String, Object?>();
    final scores = (f['scores'] as Map).cast<String, Object?>();
    return MatchSnapshot(
      status: f['status'] as String,
      code: f['code'] as String,
      matchLength: (f['matchLength'] as num).toInt(),
      gameNo: (f['gameNo'] as num).toInt(),
      seq: (f['seq'] as num).toInt(),
      whiteUid: seats['white'] as String,
      blackUid: seats['black'] as String?,
      whiteScore: (scores['white'] as num).toInt(),
      blackScore: (scores['black'] as num).toInt(),
      turn: _player(f['turn']),
      phase: _phase(f['phase']),
      isCrawford: (f['isCrawford'] as bool?) ?? false,
      crawfordPlayed: (f['crawfordPlayed'] as bool?) ?? false,
      winner: _player(f['winner']),
    );
  }

  static Player? _player(Object? raw) =>
      raw is String ? Player.values.byName(raw) : null;

  static GamePhase? _phase(Object? raw) =>
      raw is String ? GamePhase.values.byName(raw) : null;
}

/// High-level facade over the auth / Firestore / Functions REST clients. Every
/// online-play operation the app needs goes through here.
class MatchApi {
  final AuthClient auth;
  final FirestoreRestClient firestore;
  final FunctionsClient functions;

  MatchApi(this.auth, this.firestore, this.functions);

  /// Create a new match of [matchLength] points. Returns the id and share code.
  Future<({String matchId, String code})> createMatch(int matchLength) async {
    final r = await functions.call('createMatch', {'matchLength': matchLength});
    return (matchId: r['matchId'] as String, code: r['code'] as String);
  }

  /// Join the match identified by [code]. Returns its match id.
  Future<String> joinMatch(String code) async {
    final r = await functions.call('joinMatch', {'code': code});
    return r['matchId'] as String;
  }

  /// Request a server-authoritative dice roll for [matchId].
  Future<Dice> rollDice(String matchId) async {
    final r = await functions.call('rollDice', {'matchId': matchId});
    return Dice((r['die1'] as num).toInt(), (r['die2'] as num).toInt());
  }

  /// Submit a client [event] (optionally carrying a terminal [result] claim).
  /// Returns the assigned sequence number.
  Future<int> submitEvent(
    String matchId,
    GameEvent event, {
    GameResultClaim? result,
  }) async {
    final data = <String, Object?>{
      'matchId': matchId,
      'event': event.toJson(),
      if (result != null) 'result': result.toJson(),
    };
    final r = await functions.call('submitEvent', data);
    return (r['seq'] as num).toInt();
  }

  /// Fetch the current match summary. Throws [OnlineException] `not-found` if
  /// the match does not exist.
  Future<MatchSnapshot> fetchMatch(String matchId) async {
    final fields = await firestore.getDocument('matches/$matchId');
    if (fields == null) {
      throw OnlineException('not-found', 'match $matchId not found');
    }
    return MatchSnapshot.fromFields(fields);
  }

  /// Fetch events with `seq > afterSeq`, ordered ascending by seq.
  Future<List<RemoteEvent>> fetchEventsSince(
    String matchId,
    int afterSeq,
  ) async {
    final rows = await firestore.runQuery(
      'matches/$matchId',
      'events',
      whereIntGreaterThan: ('seq', afterSeq),
      orderByField: 'seq',
    );
    return [for (final r in rows) RemoteEvent.fromFields(r)];
  }

  /// Poll for new events, emitting each exactly once in strictly increasing seq
  /// order. Polling starts on first listen, repeats every [interval], and stops
  /// when the subscription is cancelled.
  Stream<RemoteEvent> pollEvents(
    String matchId, {
    Duration interval = const Duration(seconds: 2),
  }) {
    late StreamController<RemoteEvent> controller;
    var cancelled = false;
    var lastSeq = -1;

    Future<void> loop() async {
      while (!cancelled) {
        try {
          final events = await fetchEventsSince(matchId, lastSeq);
          for (final e in events) {
            if (cancelled) return;
            if (e.seq > lastSeq) {
              controller.add(e);
              lastSeq = e.seq;
            }
          }
        } catch (err, st) {
          if (!cancelled) controller.addError(err, st);
        }
        if (cancelled) return;
        await Future<void>.delayed(interval);
      }
    }

    controller = StreamController<RemoteEvent>(
      onListen: loop,
      onCancel: () {
        cancelled = true;
      },
    );
    return controller.stream;
  }
}
