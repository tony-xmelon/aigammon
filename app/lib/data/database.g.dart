// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $MatchesTable extends Matches with TableInfo<$MatchesTable, MatchRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MatchesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _matchLengthMeta = const VerificationMeta(
    'matchLength',
  );
  @override
  late final GeneratedColumn<int> matchLength = GeneratedColumn<int>(
    'match_length',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _modeMeta = const VerificationMeta('mode');
  @override
  late final GeneratedColumn<String> mode = GeneratedColumn<String>(
    'mode',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _whiteTypeMeta = const VerificationMeta(
    'whiteType',
  );
  @override
  late final GeneratedColumn<String> whiteType = GeneratedColumn<String>(
    'white_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _blackTypeMeta = const VerificationMeta(
    'blackType',
  );
  @override
  late final GeneratedColumn<String> blackType = GeneratedColumn<String>(
    'black_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _whiteScoreMeta = const VerificationMeta(
    'whiteScore',
  );
  @override
  late final GeneratedColumn<int> whiteScore = GeneratedColumn<int>(
    'white_score',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _blackScoreMeta = const VerificationMeta(
    'blackScore',
  );
  @override
  late final GeneratedColumn<int> blackScore = GeneratedColumn<int>(
    'black_score',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _winnerMeta = const VerificationMeta('winner');
  @override
  late final GeneratedColumn<String> winner = GeneratedColumn<String>(
    'winner',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _completedMeta = const VerificationMeta(
    'completed',
  );
  @override
  late final GeneratedColumn<bool> completed = GeneratedColumn<bool>(
    'completed',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("completed" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    createdAt,
    matchLength,
    mode,
    whiteType,
    blackType,
    whiteScore,
    blackScore,
    winner,
    completed,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'matches';
  @override
  VerificationContext validateIntegrity(
    Insertable<MatchRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('match_length')) {
      context.handle(
        _matchLengthMeta,
        matchLength.isAcceptableOrUnknown(
          data['match_length']!,
          _matchLengthMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_matchLengthMeta);
    }
    if (data.containsKey('mode')) {
      context.handle(
        _modeMeta,
        mode.isAcceptableOrUnknown(data['mode']!, _modeMeta),
      );
    } else if (isInserting) {
      context.missing(_modeMeta);
    }
    if (data.containsKey('white_type')) {
      context.handle(
        _whiteTypeMeta,
        whiteType.isAcceptableOrUnknown(data['white_type']!, _whiteTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_whiteTypeMeta);
    }
    if (data.containsKey('black_type')) {
      context.handle(
        _blackTypeMeta,
        blackType.isAcceptableOrUnknown(data['black_type']!, _blackTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_blackTypeMeta);
    }
    if (data.containsKey('white_score')) {
      context.handle(
        _whiteScoreMeta,
        whiteScore.isAcceptableOrUnknown(data['white_score']!, _whiteScoreMeta),
      );
    }
    if (data.containsKey('black_score')) {
      context.handle(
        _blackScoreMeta,
        blackScore.isAcceptableOrUnknown(data['black_score']!, _blackScoreMeta),
      );
    }
    if (data.containsKey('winner')) {
      context.handle(
        _winnerMeta,
        winner.isAcceptableOrUnknown(data['winner']!, _winnerMeta),
      );
    }
    if (data.containsKey('completed')) {
      context.handle(
        _completedMeta,
        completed.isAcceptableOrUnknown(data['completed']!, _completedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MatchRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MatchRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      matchLength: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}match_length'],
      )!,
      mode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mode'],
      )!,
      whiteType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}white_type'],
      )!,
      blackType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}black_type'],
      )!,
      whiteScore: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}white_score'],
      )!,
      blackScore: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}black_score'],
      )!,
      winner: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}winner'],
      ),
      completed: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}completed'],
      )!,
    );
  }

  @override
  $MatchesTable createAlias(String alias) {
    return $MatchesTable(attachedDatabase, alias);
  }
}

class MatchRow extends DataClass implements Insertable<MatchRow> {
  final int id;
  final DateTime createdAt;
  final int matchLength;

  /// 'vsComputer' | 'hotSeat'.
  final String mode;

  /// Player identity strings, e.g. 'human' or 'ai:expert'.
  final String whiteType;
  final String blackType;
  final int whiteScore;
  final int blackScore;

  /// 'white' | 'black' once the match is decided; null while in progress.
  final String? winner;
  final bool completed;
  const MatchRow({
    required this.id,
    required this.createdAt,
    required this.matchLength,
    required this.mode,
    required this.whiteType,
    required this.blackType,
    required this.whiteScore,
    required this.blackScore,
    this.winner,
    required this.completed,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['match_length'] = Variable<int>(matchLength);
    map['mode'] = Variable<String>(mode);
    map['white_type'] = Variable<String>(whiteType);
    map['black_type'] = Variable<String>(blackType);
    map['white_score'] = Variable<int>(whiteScore);
    map['black_score'] = Variable<int>(blackScore);
    if (!nullToAbsent || winner != null) {
      map['winner'] = Variable<String>(winner);
    }
    map['completed'] = Variable<bool>(completed);
    return map;
  }

  MatchesCompanion toCompanion(bool nullToAbsent) {
    return MatchesCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      matchLength: Value(matchLength),
      mode: Value(mode),
      whiteType: Value(whiteType),
      blackType: Value(blackType),
      whiteScore: Value(whiteScore),
      blackScore: Value(blackScore),
      winner: winner == null && nullToAbsent
          ? const Value.absent()
          : Value(winner),
      completed: Value(completed),
    );
  }

  factory MatchRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MatchRow(
      id: serializer.fromJson<int>(json['id']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      matchLength: serializer.fromJson<int>(json['matchLength']),
      mode: serializer.fromJson<String>(json['mode']),
      whiteType: serializer.fromJson<String>(json['whiteType']),
      blackType: serializer.fromJson<String>(json['blackType']),
      whiteScore: serializer.fromJson<int>(json['whiteScore']),
      blackScore: serializer.fromJson<int>(json['blackScore']),
      winner: serializer.fromJson<String?>(json['winner']),
      completed: serializer.fromJson<bool>(json['completed']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'matchLength': serializer.toJson<int>(matchLength),
      'mode': serializer.toJson<String>(mode),
      'whiteType': serializer.toJson<String>(whiteType),
      'blackType': serializer.toJson<String>(blackType),
      'whiteScore': serializer.toJson<int>(whiteScore),
      'blackScore': serializer.toJson<int>(blackScore),
      'winner': serializer.toJson<String?>(winner),
      'completed': serializer.toJson<bool>(completed),
    };
  }

  MatchRow copyWith({
    int? id,
    DateTime? createdAt,
    int? matchLength,
    String? mode,
    String? whiteType,
    String? blackType,
    int? whiteScore,
    int? blackScore,
    Value<String?> winner = const Value.absent(),
    bool? completed,
  }) => MatchRow(
    id: id ?? this.id,
    createdAt: createdAt ?? this.createdAt,
    matchLength: matchLength ?? this.matchLength,
    mode: mode ?? this.mode,
    whiteType: whiteType ?? this.whiteType,
    blackType: blackType ?? this.blackType,
    whiteScore: whiteScore ?? this.whiteScore,
    blackScore: blackScore ?? this.blackScore,
    winner: winner.present ? winner.value : this.winner,
    completed: completed ?? this.completed,
  );
  MatchRow copyWithCompanion(MatchesCompanion data) {
    return MatchRow(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      matchLength: data.matchLength.present
          ? data.matchLength.value
          : this.matchLength,
      mode: data.mode.present ? data.mode.value : this.mode,
      whiteType: data.whiteType.present ? data.whiteType.value : this.whiteType,
      blackType: data.blackType.present ? data.blackType.value : this.blackType,
      whiteScore: data.whiteScore.present
          ? data.whiteScore.value
          : this.whiteScore,
      blackScore: data.blackScore.present
          ? data.blackScore.value
          : this.blackScore,
      winner: data.winner.present ? data.winner.value : this.winner,
      completed: data.completed.present ? data.completed.value : this.completed,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MatchRow(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('matchLength: $matchLength, ')
          ..write('mode: $mode, ')
          ..write('whiteType: $whiteType, ')
          ..write('blackType: $blackType, ')
          ..write('whiteScore: $whiteScore, ')
          ..write('blackScore: $blackScore, ')
          ..write('winner: $winner, ')
          ..write('completed: $completed')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    createdAt,
    matchLength,
    mode,
    whiteType,
    blackType,
    whiteScore,
    blackScore,
    winner,
    completed,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MatchRow &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.matchLength == this.matchLength &&
          other.mode == this.mode &&
          other.whiteType == this.whiteType &&
          other.blackType == this.blackType &&
          other.whiteScore == this.whiteScore &&
          other.blackScore == this.blackScore &&
          other.winner == this.winner &&
          other.completed == this.completed);
}

class MatchesCompanion extends UpdateCompanion<MatchRow> {
  final Value<int> id;
  final Value<DateTime> createdAt;
  final Value<int> matchLength;
  final Value<String> mode;
  final Value<String> whiteType;
  final Value<String> blackType;
  final Value<int> whiteScore;
  final Value<int> blackScore;
  final Value<String?> winner;
  final Value<bool> completed;
  const MatchesCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.matchLength = const Value.absent(),
    this.mode = const Value.absent(),
    this.whiteType = const Value.absent(),
    this.blackType = const Value.absent(),
    this.whiteScore = const Value.absent(),
    this.blackScore = const Value.absent(),
    this.winner = const Value.absent(),
    this.completed = const Value.absent(),
  });
  MatchesCompanion.insert({
    this.id = const Value.absent(),
    required DateTime createdAt,
    required int matchLength,
    required String mode,
    required String whiteType,
    required String blackType,
    this.whiteScore = const Value.absent(),
    this.blackScore = const Value.absent(),
    this.winner = const Value.absent(),
    this.completed = const Value.absent(),
  }) : createdAt = Value(createdAt),
       matchLength = Value(matchLength),
       mode = Value(mode),
       whiteType = Value(whiteType),
       blackType = Value(blackType);
  static Insertable<MatchRow> custom({
    Expression<int>? id,
    Expression<DateTime>? createdAt,
    Expression<int>? matchLength,
    Expression<String>? mode,
    Expression<String>? whiteType,
    Expression<String>? blackType,
    Expression<int>? whiteScore,
    Expression<int>? blackScore,
    Expression<String>? winner,
    Expression<bool>? completed,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (matchLength != null) 'match_length': matchLength,
      if (mode != null) 'mode': mode,
      if (whiteType != null) 'white_type': whiteType,
      if (blackType != null) 'black_type': blackType,
      if (whiteScore != null) 'white_score': whiteScore,
      if (blackScore != null) 'black_score': blackScore,
      if (winner != null) 'winner': winner,
      if (completed != null) 'completed': completed,
    });
  }

  MatchesCompanion copyWith({
    Value<int>? id,
    Value<DateTime>? createdAt,
    Value<int>? matchLength,
    Value<String>? mode,
    Value<String>? whiteType,
    Value<String>? blackType,
    Value<int>? whiteScore,
    Value<int>? blackScore,
    Value<String?>? winner,
    Value<bool>? completed,
  }) {
    return MatchesCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      matchLength: matchLength ?? this.matchLength,
      mode: mode ?? this.mode,
      whiteType: whiteType ?? this.whiteType,
      blackType: blackType ?? this.blackType,
      whiteScore: whiteScore ?? this.whiteScore,
      blackScore: blackScore ?? this.blackScore,
      winner: winner ?? this.winner,
      completed: completed ?? this.completed,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (matchLength.present) {
      map['match_length'] = Variable<int>(matchLength.value);
    }
    if (mode.present) {
      map['mode'] = Variable<String>(mode.value);
    }
    if (whiteType.present) {
      map['white_type'] = Variable<String>(whiteType.value);
    }
    if (blackType.present) {
      map['black_type'] = Variable<String>(blackType.value);
    }
    if (whiteScore.present) {
      map['white_score'] = Variable<int>(whiteScore.value);
    }
    if (blackScore.present) {
      map['black_score'] = Variable<int>(blackScore.value);
    }
    if (winner.present) {
      map['winner'] = Variable<String>(winner.value);
    }
    if (completed.present) {
      map['completed'] = Variable<bool>(completed.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MatchesCompanion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('matchLength: $matchLength, ')
          ..write('mode: $mode, ')
          ..write('whiteType: $whiteType, ')
          ..write('blackType: $blackType, ')
          ..write('whiteScore: $whiteScore, ')
          ..write('blackScore: $blackScore, ')
          ..write('winner: $winner, ')
          ..write('completed: $completed')
          ..write(')'))
        .toString();
  }
}

class $GamesTable extends Games with TableInfo<$GamesTable, GameRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GamesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _matchIdMeta = const VerificationMeta(
    'matchId',
  );
  @override
  late final GeneratedColumn<int> matchId = GeneratedColumn<int>(
    'match_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL REFERENCES matches (id) ON DELETE CASCADE',
  );
  static const VerificationMeta _gameNumberMeta = const VerificationMeta(
    'gameNumber',
  );
  @override
  late final GeneratedColumn<int> gameNumber = GeneratedColumn<int>(
    'game_number',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isCrawfordMeta = const VerificationMeta(
    'isCrawford',
  );
  @override
  late final GeneratedColumn<bool> isCrawford = GeneratedColumn<bool>(
    'is_crawford',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_crawford" IN (0, 1))',
    ),
  );
  static const VerificationMeta _eventsJsonMeta = const VerificationMeta(
    'eventsJson',
  );
  @override
  late final GeneratedColumn<String> eventsJson = GeneratedColumn<String>(
    'events_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _resultWinnerMeta = const VerificationMeta(
    'resultWinner',
  );
  @override
  late final GeneratedColumn<String> resultWinner = GeneratedColumn<String>(
    'result_winner',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _resultPointsMeta = const VerificationMeta(
    'resultPoints',
  );
  @override
  late final GeneratedColumn<int> resultPoints = GeneratedColumn<int>(
    'result_points',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _resultOutcomeMeta = const VerificationMeta(
    'resultOutcome',
  );
  @override
  late final GeneratedColumn<String> resultOutcome = GeneratedColumn<String>(
    'result_outcome',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _analysisJsonMeta = const VerificationMeta(
    'analysisJson',
  );
  @override
  late final GeneratedColumn<String> analysisJson = GeneratedColumn<String>(
    'analysis_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    matchId,
    gameNumber,
    isCrawford,
    eventsJson,
    resultWinner,
    resultPoints,
    resultOutcome,
    analysisJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'games';
  @override
  VerificationContext validateIntegrity(
    Insertable<GameRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('match_id')) {
      context.handle(
        _matchIdMeta,
        matchId.isAcceptableOrUnknown(data['match_id']!, _matchIdMeta),
      );
    } else if (isInserting) {
      context.missing(_matchIdMeta);
    }
    if (data.containsKey('game_number')) {
      context.handle(
        _gameNumberMeta,
        gameNumber.isAcceptableOrUnknown(data['game_number']!, _gameNumberMeta),
      );
    } else if (isInserting) {
      context.missing(_gameNumberMeta);
    }
    if (data.containsKey('is_crawford')) {
      context.handle(
        _isCrawfordMeta,
        isCrawford.isAcceptableOrUnknown(data['is_crawford']!, _isCrawfordMeta),
      );
    } else if (isInserting) {
      context.missing(_isCrawfordMeta);
    }
    if (data.containsKey('events_json')) {
      context.handle(
        _eventsJsonMeta,
        eventsJson.isAcceptableOrUnknown(data['events_json']!, _eventsJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_eventsJsonMeta);
    }
    if (data.containsKey('result_winner')) {
      context.handle(
        _resultWinnerMeta,
        resultWinner.isAcceptableOrUnknown(
          data['result_winner']!,
          _resultWinnerMeta,
        ),
      );
    }
    if (data.containsKey('result_points')) {
      context.handle(
        _resultPointsMeta,
        resultPoints.isAcceptableOrUnknown(
          data['result_points']!,
          _resultPointsMeta,
        ),
      );
    }
    if (data.containsKey('result_outcome')) {
      context.handle(
        _resultOutcomeMeta,
        resultOutcome.isAcceptableOrUnknown(
          data['result_outcome']!,
          _resultOutcomeMeta,
        ),
      );
    }
    if (data.containsKey('analysis_json')) {
      context.handle(
        _analysisJsonMeta,
        analysisJson.isAcceptableOrUnknown(
          data['analysis_json']!,
          _analysisJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  GameRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return GameRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      matchId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}match_id'],
      )!,
      gameNumber: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}game_number'],
      )!,
      isCrawford: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_crawford'],
      )!,
      eventsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}events_json'],
      )!,
      resultWinner: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}result_winner'],
      ),
      resultPoints: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}result_points'],
      ),
      resultOutcome: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}result_outcome'],
      ),
      analysisJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}analysis_json'],
      ),
    );
  }

  @override
  $GamesTable createAlias(String alias) {
    return $GamesTable(attachedDatabase, alias);
  }
}

class GameRow extends DataClass implements Insertable<GameRow> {
  final int id;

  /// A REAL SQL foreign key (emitted via [customConstraint], so the generated
  /// DDL carries `REFERENCES matches (id) ON DELETE CASCADE`). drift's
  /// `.references()` only wires the Dart-side relation; it does not emit the SQL
  /// constraint, so a customConstraint is used to enforce integrity at the
  /// database level. Cascade delete relies on `PRAGMA foreign_keys = ON`, which
  /// [AppDatabase.migration] enables in `beforeOpen`. Because this column drops
  /// the default `NOT NULL`, it is restated here explicitly.
  final int matchId;
  final int gameNumber;
  final bool isCrawford;

  /// A JSON array of `GameEvent.toJson()` maps (the full event log).
  final String eventsJson;

  /// The folded [GameResult], flattened. Null only for an unfinished game
  /// (not persisted in v1 — games are recorded once complete).
  final String? resultWinner;
  final int? resultPoints;
  final String? resultOutcome;

  /// Cached analysis payload (Task 8), attached lazily after the game ends.
  final String? analysisJson;
  const GameRow({
    required this.id,
    required this.matchId,
    required this.gameNumber,
    required this.isCrawford,
    required this.eventsJson,
    this.resultWinner,
    this.resultPoints,
    this.resultOutcome,
    this.analysisJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['match_id'] = Variable<int>(matchId);
    map['game_number'] = Variable<int>(gameNumber);
    map['is_crawford'] = Variable<bool>(isCrawford);
    map['events_json'] = Variable<String>(eventsJson);
    if (!nullToAbsent || resultWinner != null) {
      map['result_winner'] = Variable<String>(resultWinner);
    }
    if (!nullToAbsent || resultPoints != null) {
      map['result_points'] = Variable<int>(resultPoints);
    }
    if (!nullToAbsent || resultOutcome != null) {
      map['result_outcome'] = Variable<String>(resultOutcome);
    }
    if (!nullToAbsent || analysisJson != null) {
      map['analysis_json'] = Variable<String>(analysisJson);
    }
    return map;
  }

  GamesCompanion toCompanion(bool nullToAbsent) {
    return GamesCompanion(
      id: Value(id),
      matchId: Value(matchId),
      gameNumber: Value(gameNumber),
      isCrawford: Value(isCrawford),
      eventsJson: Value(eventsJson),
      resultWinner: resultWinner == null && nullToAbsent
          ? const Value.absent()
          : Value(resultWinner),
      resultPoints: resultPoints == null && nullToAbsent
          ? const Value.absent()
          : Value(resultPoints),
      resultOutcome: resultOutcome == null && nullToAbsent
          ? const Value.absent()
          : Value(resultOutcome),
      analysisJson: analysisJson == null && nullToAbsent
          ? const Value.absent()
          : Value(analysisJson),
    );
  }

  factory GameRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return GameRow(
      id: serializer.fromJson<int>(json['id']),
      matchId: serializer.fromJson<int>(json['matchId']),
      gameNumber: serializer.fromJson<int>(json['gameNumber']),
      isCrawford: serializer.fromJson<bool>(json['isCrawford']),
      eventsJson: serializer.fromJson<String>(json['eventsJson']),
      resultWinner: serializer.fromJson<String?>(json['resultWinner']),
      resultPoints: serializer.fromJson<int?>(json['resultPoints']),
      resultOutcome: serializer.fromJson<String?>(json['resultOutcome']),
      analysisJson: serializer.fromJson<String?>(json['analysisJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'matchId': serializer.toJson<int>(matchId),
      'gameNumber': serializer.toJson<int>(gameNumber),
      'isCrawford': serializer.toJson<bool>(isCrawford),
      'eventsJson': serializer.toJson<String>(eventsJson),
      'resultWinner': serializer.toJson<String?>(resultWinner),
      'resultPoints': serializer.toJson<int?>(resultPoints),
      'resultOutcome': serializer.toJson<String?>(resultOutcome),
      'analysisJson': serializer.toJson<String?>(analysisJson),
    };
  }

  GameRow copyWith({
    int? id,
    int? matchId,
    int? gameNumber,
    bool? isCrawford,
    String? eventsJson,
    Value<String?> resultWinner = const Value.absent(),
    Value<int?> resultPoints = const Value.absent(),
    Value<String?> resultOutcome = const Value.absent(),
    Value<String?> analysisJson = const Value.absent(),
  }) => GameRow(
    id: id ?? this.id,
    matchId: matchId ?? this.matchId,
    gameNumber: gameNumber ?? this.gameNumber,
    isCrawford: isCrawford ?? this.isCrawford,
    eventsJson: eventsJson ?? this.eventsJson,
    resultWinner: resultWinner.present ? resultWinner.value : this.resultWinner,
    resultPoints: resultPoints.present ? resultPoints.value : this.resultPoints,
    resultOutcome: resultOutcome.present
        ? resultOutcome.value
        : this.resultOutcome,
    analysisJson: analysisJson.present ? analysisJson.value : this.analysisJson,
  );
  GameRow copyWithCompanion(GamesCompanion data) {
    return GameRow(
      id: data.id.present ? data.id.value : this.id,
      matchId: data.matchId.present ? data.matchId.value : this.matchId,
      gameNumber: data.gameNumber.present
          ? data.gameNumber.value
          : this.gameNumber,
      isCrawford: data.isCrawford.present
          ? data.isCrawford.value
          : this.isCrawford,
      eventsJson: data.eventsJson.present
          ? data.eventsJson.value
          : this.eventsJson,
      resultWinner: data.resultWinner.present
          ? data.resultWinner.value
          : this.resultWinner,
      resultPoints: data.resultPoints.present
          ? data.resultPoints.value
          : this.resultPoints,
      resultOutcome: data.resultOutcome.present
          ? data.resultOutcome.value
          : this.resultOutcome,
      analysisJson: data.analysisJson.present
          ? data.analysisJson.value
          : this.analysisJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('GameRow(')
          ..write('id: $id, ')
          ..write('matchId: $matchId, ')
          ..write('gameNumber: $gameNumber, ')
          ..write('isCrawford: $isCrawford, ')
          ..write('eventsJson: $eventsJson, ')
          ..write('resultWinner: $resultWinner, ')
          ..write('resultPoints: $resultPoints, ')
          ..write('resultOutcome: $resultOutcome, ')
          ..write('analysisJson: $analysisJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    matchId,
    gameNumber,
    isCrawford,
    eventsJson,
    resultWinner,
    resultPoints,
    resultOutcome,
    analysisJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is GameRow &&
          other.id == this.id &&
          other.matchId == this.matchId &&
          other.gameNumber == this.gameNumber &&
          other.isCrawford == this.isCrawford &&
          other.eventsJson == this.eventsJson &&
          other.resultWinner == this.resultWinner &&
          other.resultPoints == this.resultPoints &&
          other.resultOutcome == this.resultOutcome &&
          other.analysisJson == this.analysisJson);
}

class GamesCompanion extends UpdateCompanion<GameRow> {
  final Value<int> id;
  final Value<int> matchId;
  final Value<int> gameNumber;
  final Value<bool> isCrawford;
  final Value<String> eventsJson;
  final Value<String?> resultWinner;
  final Value<int?> resultPoints;
  final Value<String?> resultOutcome;
  final Value<String?> analysisJson;
  const GamesCompanion({
    this.id = const Value.absent(),
    this.matchId = const Value.absent(),
    this.gameNumber = const Value.absent(),
    this.isCrawford = const Value.absent(),
    this.eventsJson = const Value.absent(),
    this.resultWinner = const Value.absent(),
    this.resultPoints = const Value.absent(),
    this.resultOutcome = const Value.absent(),
    this.analysisJson = const Value.absent(),
  });
  GamesCompanion.insert({
    this.id = const Value.absent(),
    required int matchId,
    required int gameNumber,
    required bool isCrawford,
    required String eventsJson,
    this.resultWinner = const Value.absent(),
    this.resultPoints = const Value.absent(),
    this.resultOutcome = const Value.absent(),
    this.analysisJson = const Value.absent(),
  }) : matchId = Value(matchId),
       gameNumber = Value(gameNumber),
       isCrawford = Value(isCrawford),
       eventsJson = Value(eventsJson);
  static Insertable<GameRow> custom({
    Expression<int>? id,
    Expression<int>? matchId,
    Expression<int>? gameNumber,
    Expression<bool>? isCrawford,
    Expression<String>? eventsJson,
    Expression<String>? resultWinner,
    Expression<int>? resultPoints,
    Expression<String>? resultOutcome,
    Expression<String>? analysisJson,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (matchId != null) 'match_id': matchId,
      if (gameNumber != null) 'game_number': gameNumber,
      if (isCrawford != null) 'is_crawford': isCrawford,
      if (eventsJson != null) 'events_json': eventsJson,
      if (resultWinner != null) 'result_winner': resultWinner,
      if (resultPoints != null) 'result_points': resultPoints,
      if (resultOutcome != null) 'result_outcome': resultOutcome,
      if (analysisJson != null) 'analysis_json': analysisJson,
    });
  }

  GamesCompanion copyWith({
    Value<int>? id,
    Value<int>? matchId,
    Value<int>? gameNumber,
    Value<bool>? isCrawford,
    Value<String>? eventsJson,
    Value<String?>? resultWinner,
    Value<int?>? resultPoints,
    Value<String?>? resultOutcome,
    Value<String?>? analysisJson,
  }) {
    return GamesCompanion(
      id: id ?? this.id,
      matchId: matchId ?? this.matchId,
      gameNumber: gameNumber ?? this.gameNumber,
      isCrawford: isCrawford ?? this.isCrawford,
      eventsJson: eventsJson ?? this.eventsJson,
      resultWinner: resultWinner ?? this.resultWinner,
      resultPoints: resultPoints ?? this.resultPoints,
      resultOutcome: resultOutcome ?? this.resultOutcome,
      analysisJson: analysisJson ?? this.analysisJson,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (matchId.present) {
      map['match_id'] = Variable<int>(matchId.value);
    }
    if (gameNumber.present) {
      map['game_number'] = Variable<int>(gameNumber.value);
    }
    if (isCrawford.present) {
      map['is_crawford'] = Variable<bool>(isCrawford.value);
    }
    if (eventsJson.present) {
      map['events_json'] = Variable<String>(eventsJson.value);
    }
    if (resultWinner.present) {
      map['result_winner'] = Variable<String>(resultWinner.value);
    }
    if (resultPoints.present) {
      map['result_points'] = Variable<int>(resultPoints.value);
    }
    if (resultOutcome.present) {
      map['result_outcome'] = Variable<String>(resultOutcome.value);
    }
    if (analysisJson.present) {
      map['analysis_json'] = Variable<String>(analysisJson.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GamesCompanion(')
          ..write('id: $id, ')
          ..write('matchId: $matchId, ')
          ..write('gameNumber: $gameNumber, ')
          ..write('isCrawford: $isCrawford, ')
          ..write('eventsJson: $eventsJson, ')
          ..write('resultWinner: $resultWinner, ')
          ..write('resultPoints: $resultPoints, ')
          ..write('resultOutcome: $resultOutcome, ')
          ..write('analysisJson: $analysisJson')
          ..write(')'))
        .toString();
  }
}

class $SettingsTable extends Settings
    with TableInfo<$SettingsTable, SettingsRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _themeModeMeta = const VerificationMeta(
    'themeMode',
  );
  @override
  late final GeneratedColumn<String> themeMode = GeneratedColumn<String>(
    'theme_mode',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('system'),
  );
  static const VerificationMeta _animationSpeedMeta = const VerificationMeta(
    'animationSpeed',
  );
  @override
  late final GeneratedColumn<String> animationSpeed = GeneratedColumn<String>(
    'animation_speed',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('normal'),
  );
  static const VerificationMeta _defaultMatchLengthMeta =
      const VerificationMeta('defaultMatchLength');
  @override
  late final GeneratedColumn<int> defaultMatchLength = GeneratedColumn<int>(
    'default_match_length',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(5),
  );
  static const VerificationMeta _defaultDifficultyMeta = const VerificationMeta(
    'defaultDifficulty',
  );
  @override
  late final GeneratedColumn<String> defaultDifficulty =
      GeneratedColumn<String>(
        'default_difficulty',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant('medium'),
      );
  static const VerificationMeta _tutorOverrideMeta = const VerificationMeta(
    'tutorOverride',
  );
  @override
  late final GeneratedColumn<String> tutorOverride = GeneratedColumn<String>(
    'tutor_override',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _showHighlightsMeta = const VerificationMeta(
    'showHighlights',
  );
  @override
  late final GeneratedColumn<bool> showHighlights = GeneratedColumn<bool>(
    'show_highlights',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("show_highlights" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _enableDragMeta = const VerificationMeta(
    'enableDrag',
  );
  @override
  late final GeneratedColumn<bool> enableDrag = GeneratedColumn<bool>(
    'enable_drag',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("enable_drag" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _enableCombinedTapsMeta =
      const VerificationMeta('enableCombinedTaps');
  @override
  late final GeneratedColumn<bool> enableCombinedTaps = GeneratedColumn<bool>(
    'enable_combined_taps',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("enable_combined_taps" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _showScoringMeta = const VerificationMeta(
    'showScoring',
  );
  @override
  late final GeneratedColumn<bool> showScoring = GeneratedColumn<bool>(
    'show_scoring',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("show_scoring" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    themeMode,
    animationSpeed,
    defaultMatchLength,
    defaultDifficulty,
    tutorOverride,
    showHighlights,
    enableDrag,
    enableCombinedTaps,
    showScoring,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<SettingsRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('theme_mode')) {
      context.handle(
        _themeModeMeta,
        themeMode.isAcceptableOrUnknown(data['theme_mode']!, _themeModeMeta),
      );
    }
    if (data.containsKey('animation_speed')) {
      context.handle(
        _animationSpeedMeta,
        animationSpeed.isAcceptableOrUnknown(
          data['animation_speed']!,
          _animationSpeedMeta,
        ),
      );
    }
    if (data.containsKey('default_match_length')) {
      context.handle(
        _defaultMatchLengthMeta,
        defaultMatchLength.isAcceptableOrUnknown(
          data['default_match_length']!,
          _defaultMatchLengthMeta,
        ),
      );
    }
    if (data.containsKey('default_difficulty')) {
      context.handle(
        _defaultDifficultyMeta,
        defaultDifficulty.isAcceptableOrUnknown(
          data['default_difficulty']!,
          _defaultDifficultyMeta,
        ),
      );
    }
    if (data.containsKey('tutor_override')) {
      context.handle(
        _tutorOverrideMeta,
        tutorOverride.isAcceptableOrUnknown(
          data['tutor_override']!,
          _tutorOverrideMeta,
        ),
      );
    }
    if (data.containsKey('show_highlights')) {
      context.handle(
        _showHighlightsMeta,
        showHighlights.isAcceptableOrUnknown(
          data['show_highlights']!,
          _showHighlightsMeta,
        ),
      );
    }
    if (data.containsKey('enable_drag')) {
      context.handle(
        _enableDragMeta,
        enableDrag.isAcceptableOrUnknown(data['enable_drag']!, _enableDragMeta),
      );
    }
    if (data.containsKey('enable_combined_taps')) {
      context.handle(
        _enableCombinedTapsMeta,
        enableCombinedTaps.isAcceptableOrUnknown(
          data['enable_combined_taps']!,
          _enableCombinedTapsMeta,
        ),
      );
    }
    if (data.containsKey('show_scoring')) {
      context.handle(
        _showScoringMeta,
        showScoring.isAcceptableOrUnknown(
          data['show_scoring']!,
          _showScoringMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SettingsRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SettingsRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      themeMode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}theme_mode'],
      )!,
      animationSpeed: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}animation_speed'],
      )!,
      defaultMatchLength: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}default_match_length'],
      )!,
      defaultDifficulty: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}default_difficulty'],
      )!,
      tutorOverride: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tutor_override'],
      ),
      showHighlights: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}show_highlights'],
      )!,
      enableDrag: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}enable_drag'],
      )!,
      enableCombinedTaps: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}enable_combined_taps'],
      )!,
      showScoring: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}show_scoring'],
      )!,
    );
  }

  @override
  $SettingsTable createAlias(String alias) {
    return $SettingsTable(attachedDatabase, alias);
  }
}

class SettingsRow extends DataClass implements Insertable<SettingsRow> {
  /// Always 1 (enforced by [customConstraints]). Defaulted so a bare
  /// `INSERT (id) VALUES (1)` fills every other column from its default.
  final int id;
  final String themeMode;
  final String animationSpeed;
  final int defaultMatchLength;
  final String defaultDifficulty;

  /// 'on' | 'off' | null (null = per-mode tutor default).
  final String? tutorOverride;

  /// Gameplay option toggles (schema v3). Everything besides the base tap-to-move
  /// play is optional (see Plan 7 Task 5).
  /// Whether the board paints selection rings and destination highlights.
  final bool showHighlights;

  /// Whether drag-to-move is enabled (off by default: tap-to-move is the base).
  final bool enableDrag;

  /// Whether combined (multi-hop, same-checker) landing taps are enabled.
  final bool enableCombinedTaps;

  /// Whether the HUD shows the running match score.
  final bool showScoring;
  const SettingsRow({
    required this.id,
    required this.themeMode,
    required this.animationSpeed,
    required this.defaultMatchLength,
    required this.defaultDifficulty,
    this.tutorOverride,
    required this.showHighlights,
    required this.enableDrag,
    required this.enableCombinedTaps,
    required this.showScoring,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['theme_mode'] = Variable<String>(themeMode);
    map['animation_speed'] = Variable<String>(animationSpeed);
    map['default_match_length'] = Variable<int>(defaultMatchLength);
    map['default_difficulty'] = Variable<String>(defaultDifficulty);
    if (!nullToAbsent || tutorOverride != null) {
      map['tutor_override'] = Variable<String>(tutorOverride);
    }
    map['show_highlights'] = Variable<bool>(showHighlights);
    map['enable_drag'] = Variable<bool>(enableDrag);
    map['enable_combined_taps'] = Variable<bool>(enableCombinedTaps);
    map['show_scoring'] = Variable<bool>(showScoring);
    return map;
  }

  SettingsCompanion toCompanion(bool nullToAbsent) {
    return SettingsCompanion(
      id: Value(id),
      themeMode: Value(themeMode),
      animationSpeed: Value(animationSpeed),
      defaultMatchLength: Value(defaultMatchLength),
      defaultDifficulty: Value(defaultDifficulty),
      tutorOverride: tutorOverride == null && nullToAbsent
          ? const Value.absent()
          : Value(tutorOverride),
      showHighlights: Value(showHighlights),
      enableDrag: Value(enableDrag),
      enableCombinedTaps: Value(enableCombinedTaps),
      showScoring: Value(showScoring),
    );
  }

  factory SettingsRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SettingsRow(
      id: serializer.fromJson<int>(json['id']),
      themeMode: serializer.fromJson<String>(json['themeMode']),
      animationSpeed: serializer.fromJson<String>(json['animationSpeed']),
      defaultMatchLength: serializer.fromJson<int>(json['defaultMatchLength']),
      defaultDifficulty: serializer.fromJson<String>(json['defaultDifficulty']),
      tutorOverride: serializer.fromJson<String?>(json['tutorOverride']),
      showHighlights: serializer.fromJson<bool>(json['showHighlights']),
      enableDrag: serializer.fromJson<bool>(json['enableDrag']),
      enableCombinedTaps: serializer.fromJson<bool>(json['enableCombinedTaps']),
      showScoring: serializer.fromJson<bool>(json['showScoring']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'themeMode': serializer.toJson<String>(themeMode),
      'animationSpeed': serializer.toJson<String>(animationSpeed),
      'defaultMatchLength': serializer.toJson<int>(defaultMatchLength),
      'defaultDifficulty': serializer.toJson<String>(defaultDifficulty),
      'tutorOverride': serializer.toJson<String?>(tutorOverride),
      'showHighlights': serializer.toJson<bool>(showHighlights),
      'enableDrag': serializer.toJson<bool>(enableDrag),
      'enableCombinedTaps': serializer.toJson<bool>(enableCombinedTaps),
      'showScoring': serializer.toJson<bool>(showScoring),
    };
  }

  SettingsRow copyWith({
    int? id,
    String? themeMode,
    String? animationSpeed,
    int? defaultMatchLength,
    String? defaultDifficulty,
    Value<String?> tutorOverride = const Value.absent(),
    bool? showHighlights,
    bool? enableDrag,
    bool? enableCombinedTaps,
    bool? showScoring,
  }) => SettingsRow(
    id: id ?? this.id,
    themeMode: themeMode ?? this.themeMode,
    animationSpeed: animationSpeed ?? this.animationSpeed,
    defaultMatchLength: defaultMatchLength ?? this.defaultMatchLength,
    defaultDifficulty: defaultDifficulty ?? this.defaultDifficulty,
    tutorOverride: tutorOverride.present
        ? tutorOverride.value
        : this.tutorOverride,
    showHighlights: showHighlights ?? this.showHighlights,
    enableDrag: enableDrag ?? this.enableDrag,
    enableCombinedTaps: enableCombinedTaps ?? this.enableCombinedTaps,
    showScoring: showScoring ?? this.showScoring,
  );
  SettingsRow copyWithCompanion(SettingsCompanion data) {
    return SettingsRow(
      id: data.id.present ? data.id.value : this.id,
      themeMode: data.themeMode.present ? data.themeMode.value : this.themeMode,
      animationSpeed: data.animationSpeed.present
          ? data.animationSpeed.value
          : this.animationSpeed,
      defaultMatchLength: data.defaultMatchLength.present
          ? data.defaultMatchLength.value
          : this.defaultMatchLength,
      defaultDifficulty: data.defaultDifficulty.present
          ? data.defaultDifficulty.value
          : this.defaultDifficulty,
      tutorOverride: data.tutorOverride.present
          ? data.tutorOverride.value
          : this.tutorOverride,
      showHighlights: data.showHighlights.present
          ? data.showHighlights.value
          : this.showHighlights,
      enableDrag: data.enableDrag.present
          ? data.enableDrag.value
          : this.enableDrag,
      enableCombinedTaps: data.enableCombinedTaps.present
          ? data.enableCombinedTaps.value
          : this.enableCombinedTaps,
      showScoring: data.showScoring.present
          ? data.showScoring.value
          : this.showScoring,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SettingsRow(')
          ..write('id: $id, ')
          ..write('themeMode: $themeMode, ')
          ..write('animationSpeed: $animationSpeed, ')
          ..write('defaultMatchLength: $defaultMatchLength, ')
          ..write('defaultDifficulty: $defaultDifficulty, ')
          ..write('tutorOverride: $tutorOverride, ')
          ..write('showHighlights: $showHighlights, ')
          ..write('enableDrag: $enableDrag, ')
          ..write('enableCombinedTaps: $enableCombinedTaps, ')
          ..write('showScoring: $showScoring')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    themeMode,
    animationSpeed,
    defaultMatchLength,
    defaultDifficulty,
    tutorOverride,
    showHighlights,
    enableDrag,
    enableCombinedTaps,
    showScoring,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SettingsRow &&
          other.id == this.id &&
          other.themeMode == this.themeMode &&
          other.animationSpeed == this.animationSpeed &&
          other.defaultMatchLength == this.defaultMatchLength &&
          other.defaultDifficulty == this.defaultDifficulty &&
          other.tutorOverride == this.tutorOverride &&
          other.showHighlights == this.showHighlights &&
          other.enableDrag == this.enableDrag &&
          other.enableCombinedTaps == this.enableCombinedTaps &&
          other.showScoring == this.showScoring);
}

class SettingsCompanion extends UpdateCompanion<SettingsRow> {
  final Value<int> id;
  final Value<String> themeMode;
  final Value<String> animationSpeed;
  final Value<int> defaultMatchLength;
  final Value<String> defaultDifficulty;
  final Value<String?> tutorOverride;
  final Value<bool> showHighlights;
  final Value<bool> enableDrag;
  final Value<bool> enableCombinedTaps;
  final Value<bool> showScoring;
  const SettingsCompanion({
    this.id = const Value.absent(),
    this.themeMode = const Value.absent(),
    this.animationSpeed = const Value.absent(),
    this.defaultMatchLength = const Value.absent(),
    this.defaultDifficulty = const Value.absent(),
    this.tutorOverride = const Value.absent(),
    this.showHighlights = const Value.absent(),
    this.enableDrag = const Value.absent(),
    this.enableCombinedTaps = const Value.absent(),
    this.showScoring = const Value.absent(),
  });
  SettingsCompanion.insert({
    this.id = const Value.absent(),
    this.themeMode = const Value.absent(),
    this.animationSpeed = const Value.absent(),
    this.defaultMatchLength = const Value.absent(),
    this.defaultDifficulty = const Value.absent(),
    this.tutorOverride = const Value.absent(),
    this.showHighlights = const Value.absent(),
    this.enableDrag = const Value.absent(),
    this.enableCombinedTaps = const Value.absent(),
    this.showScoring = const Value.absent(),
  });
  static Insertable<SettingsRow> custom({
    Expression<int>? id,
    Expression<String>? themeMode,
    Expression<String>? animationSpeed,
    Expression<int>? defaultMatchLength,
    Expression<String>? defaultDifficulty,
    Expression<String>? tutorOverride,
    Expression<bool>? showHighlights,
    Expression<bool>? enableDrag,
    Expression<bool>? enableCombinedTaps,
    Expression<bool>? showScoring,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (themeMode != null) 'theme_mode': themeMode,
      if (animationSpeed != null) 'animation_speed': animationSpeed,
      if (defaultMatchLength != null)
        'default_match_length': defaultMatchLength,
      if (defaultDifficulty != null) 'default_difficulty': defaultDifficulty,
      if (tutorOverride != null) 'tutor_override': tutorOverride,
      if (showHighlights != null) 'show_highlights': showHighlights,
      if (enableDrag != null) 'enable_drag': enableDrag,
      if (enableCombinedTaps != null)
        'enable_combined_taps': enableCombinedTaps,
      if (showScoring != null) 'show_scoring': showScoring,
    });
  }

  SettingsCompanion copyWith({
    Value<int>? id,
    Value<String>? themeMode,
    Value<String>? animationSpeed,
    Value<int>? defaultMatchLength,
    Value<String>? defaultDifficulty,
    Value<String?>? tutorOverride,
    Value<bool>? showHighlights,
    Value<bool>? enableDrag,
    Value<bool>? enableCombinedTaps,
    Value<bool>? showScoring,
  }) {
    return SettingsCompanion(
      id: id ?? this.id,
      themeMode: themeMode ?? this.themeMode,
      animationSpeed: animationSpeed ?? this.animationSpeed,
      defaultMatchLength: defaultMatchLength ?? this.defaultMatchLength,
      defaultDifficulty: defaultDifficulty ?? this.defaultDifficulty,
      tutorOverride: tutorOverride ?? this.tutorOverride,
      showHighlights: showHighlights ?? this.showHighlights,
      enableDrag: enableDrag ?? this.enableDrag,
      enableCombinedTaps: enableCombinedTaps ?? this.enableCombinedTaps,
      showScoring: showScoring ?? this.showScoring,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (themeMode.present) {
      map['theme_mode'] = Variable<String>(themeMode.value);
    }
    if (animationSpeed.present) {
      map['animation_speed'] = Variable<String>(animationSpeed.value);
    }
    if (defaultMatchLength.present) {
      map['default_match_length'] = Variable<int>(defaultMatchLength.value);
    }
    if (defaultDifficulty.present) {
      map['default_difficulty'] = Variable<String>(defaultDifficulty.value);
    }
    if (tutorOverride.present) {
      map['tutor_override'] = Variable<String>(tutorOverride.value);
    }
    if (showHighlights.present) {
      map['show_highlights'] = Variable<bool>(showHighlights.value);
    }
    if (enableDrag.present) {
      map['enable_drag'] = Variable<bool>(enableDrag.value);
    }
    if (enableCombinedTaps.present) {
      map['enable_combined_taps'] = Variable<bool>(enableCombinedTaps.value);
    }
    if (showScoring.present) {
      map['show_scoring'] = Variable<bool>(showScoring.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SettingsCompanion(')
          ..write('id: $id, ')
          ..write('themeMode: $themeMode, ')
          ..write('animationSpeed: $animationSpeed, ')
          ..write('defaultMatchLength: $defaultMatchLength, ')
          ..write('defaultDifficulty: $defaultDifficulty, ')
          ..write('tutorOverride: $tutorOverride, ')
          ..write('showHighlights: $showHighlights, ')
          ..write('enableDrag: $enableDrag, ')
          ..write('enableCombinedTaps: $enableCombinedTaps, ')
          ..write('showScoring: $showScoring')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $MatchesTable matches = $MatchesTable(this);
  late final $GamesTable games = $GamesTable(this);
  late final $SettingsTable settings = $SettingsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    matches,
    games,
    settings,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'matches',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('games', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$MatchesTableCreateCompanionBuilder =
    MatchesCompanion Function({
      Value<int> id,
      required DateTime createdAt,
      required int matchLength,
      required String mode,
      required String whiteType,
      required String blackType,
      Value<int> whiteScore,
      Value<int> blackScore,
      Value<String?> winner,
      Value<bool> completed,
    });
typedef $$MatchesTableUpdateCompanionBuilder =
    MatchesCompanion Function({
      Value<int> id,
      Value<DateTime> createdAt,
      Value<int> matchLength,
      Value<String> mode,
      Value<String> whiteType,
      Value<String> blackType,
      Value<int> whiteScore,
      Value<int> blackScore,
      Value<String?> winner,
      Value<bool> completed,
    });

final class $$MatchesTableReferences
    extends BaseReferences<_$AppDatabase, $MatchesTable, MatchRow> {
  $$MatchesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$GamesTable, List<GameRow>> _gamesRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.games,
    aliasName: $_aliasNameGenerator(db.matches.id, db.games.matchId),
  );

  $$GamesTableProcessedTableManager get gamesRefs {
    final manager = $$GamesTableTableManager(
      $_db,
      $_db.games,
    ).filter((f) => f.matchId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_gamesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$MatchesTableFilterComposer
    extends Composer<_$AppDatabase, $MatchesTable> {
  $$MatchesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get matchLength => $composableBuilder(
    column: $table.matchLength,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mode => $composableBuilder(
    column: $table.mode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get whiteType => $composableBuilder(
    column: $table.whiteType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get blackType => $composableBuilder(
    column: $table.blackType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get whiteScore => $composableBuilder(
    column: $table.whiteScore,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get blackScore => $composableBuilder(
    column: $table.blackScore,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get winner => $composableBuilder(
    column: $table.winner,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get completed => $composableBuilder(
    column: $table.completed,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> gamesRefs(
    Expression<bool> Function($$GamesTableFilterComposer f) f,
  ) {
    final $$GamesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.games,
      getReferencedColumn: (t) => t.matchId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GamesTableFilterComposer(
            $db: $db,
            $table: $db.games,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MatchesTableOrderingComposer
    extends Composer<_$AppDatabase, $MatchesTable> {
  $$MatchesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get matchLength => $composableBuilder(
    column: $table.matchLength,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mode => $composableBuilder(
    column: $table.mode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get whiteType => $composableBuilder(
    column: $table.whiteType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get blackType => $composableBuilder(
    column: $table.blackType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get whiteScore => $composableBuilder(
    column: $table.whiteScore,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get blackScore => $composableBuilder(
    column: $table.blackScore,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get winner => $composableBuilder(
    column: $table.winner,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get completed => $composableBuilder(
    column: $table.completed,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MatchesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MatchesTable> {
  $$MatchesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get matchLength => $composableBuilder(
    column: $table.matchLength,
    builder: (column) => column,
  );

  GeneratedColumn<String> get mode =>
      $composableBuilder(column: $table.mode, builder: (column) => column);

  GeneratedColumn<String> get whiteType =>
      $composableBuilder(column: $table.whiteType, builder: (column) => column);

  GeneratedColumn<String> get blackType =>
      $composableBuilder(column: $table.blackType, builder: (column) => column);

  GeneratedColumn<int> get whiteScore => $composableBuilder(
    column: $table.whiteScore,
    builder: (column) => column,
  );

  GeneratedColumn<int> get blackScore => $composableBuilder(
    column: $table.blackScore,
    builder: (column) => column,
  );

  GeneratedColumn<String> get winner =>
      $composableBuilder(column: $table.winner, builder: (column) => column);

  GeneratedColumn<bool> get completed =>
      $composableBuilder(column: $table.completed, builder: (column) => column);

  Expression<T> gamesRefs<T extends Object>(
    Expression<T> Function($$GamesTableAnnotationComposer a) f,
  ) {
    final $$GamesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.games,
      getReferencedColumn: (t) => t.matchId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GamesTableAnnotationComposer(
            $db: $db,
            $table: $db.games,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MatchesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MatchesTable,
          MatchRow,
          $$MatchesTableFilterComposer,
          $$MatchesTableOrderingComposer,
          $$MatchesTableAnnotationComposer,
          $$MatchesTableCreateCompanionBuilder,
          $$MatchesTableUpdateCompanionBuilder,
          (MatchRow, $$MatchesTableReferences),
          MatchRow,
          PrefetchHooks Function({bool gamesRefs})
        > {
  $$MatchesTableTableManager(_$AppDatabase db, $MatchesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MatchesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MatchesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MatchesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> matchLength = const Value.absent(),
                Value<String> mode = const Value.absent(),
                Value<String> whiteType = const Value.absent(),
                Value<String> blackType = const Value.absent(),
                Value<int> whiteScore = const Value.absent(),
                Value<int> blackScore = const Value.absent(),
                Value<String?> winner = const Value.absent(),
                Value<bool> completed = const Value.absent(),
              }) => MatchesCompanion(
                id: id,
                createdAt: createdAt,
                matchLength: matchLength,
                mode: mode,
                whiteType: whiteType,
                blackType: blackType,
                whiteScore: whiteScore,
                blackScore: blackScore,
                winner: winner,
                completed: completed,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required DateTime createdAt,
                required int matchLength,
                required String mode,
                required String whiteType,
                required String blackType,
                Value<int> whiteScore = const Value.absent(),
                Value<int> blackScore = const Value.absent(),
                Value<String?> winner = const Value.absent(),
                Value<bool> completed = const Value.absent(),
              }) => MatchesCompanion.insert(
                id: id,
                createdAt: createdAt,
                matchLength: matchLength,
                mode: mode,
                whiteType: whiteType,
                blackType: blackType,
                whiteScore: whiteScore,
                blackScore: blackScore,
                winner: winner,
                completed: completed,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$MatchesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({gamesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (gamesRefs) db.games],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (gamesRefs)
                    await $_getPrefetchedData<MatchRow, $MatchesTable, GameRow>(
                      currentTable: table,
                      referencedTable: $$MatchesTableReferences._gamesRefsTable(
                        db,
                      ),
                      managerFromTypedResult: (p0) =>
                          $$MatchesTableReferences(db, table, p0).gamesRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.matchId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$MatchesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MatchesTable,
      MatchRow,
      $$MatchesTableFilterComposer,
      $$MatchesTableOrderingComposer,
      $$MatchesTableAnnotationComposer,
      $$MatchesTableCreateCompanionBuilder,
      $$MatchesTableUpdateCompanionBuilder,
      (MatchRow, $$MatchesTableReferences),
      MatchRow,
      PrefetchHooks Function({bool gamesRefs})
    >;
typedef $$GamesTableCreateCompanionBuilder =
    GamesCompanion Function({
      Value<int> id,
      required int matchId,
      required int gameNumber,
      required bool isCrawford,
      required String eventsJson,
      Value<String?> resultWinner,
      Value<int?> resultPoints,
      Value<String?> resultOutcome,
      Value<String?> analysisJson,
    });
typedef $$GamesTableUpdateCompanionBuilder =
    GamesCompanion Function({
      Value<int> id,
      Value<int> matchId,
      Value<int> gameNumber,
      Value<bool> isCrawford,
      Value<String> eventsJson,
      Value<String?> resultWinner,
      Value<int?> resultPoints,
      Value<String?> resultOutcome,
      Value<String?> analysisJson,
    });

final class $$GamesTableReferences
    extends BaseReferences<_$AppDatabase, $GamesTable, GameRow> {
  $$GamesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $MatchesTable _matchIdTable(_$AppDatabase db) => db.matches
      .createAlias($_aliasNameGenerator(db.games.matchId, db.matches.id));

  $$MatchesTableProcessedTableManager get matchId {
    final $_column = $_itemColumn<int>('match_id')!;

    final manager = $$MatchesTableTableManager(
      $_db,
      $_db.matches,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_matchIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$GamesTableFilterComposer extends Composer<_$AppDatabase, $GamesTable> {
  $$GamesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get gameNumber => $composableBuilder(
    column: $table.gameNumber,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isCrawford => $composableBuilder(
    column: $table.isCrawford,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get eventsJson => $composableBuilder(
    column: $table.eventsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resultWinner => $composableBuilder(
    column: $table.resultWinner,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get resultPoints => $composableBuilder(
    column: $table.resultPoints,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resultOutcome => $composableBuilder(
    column: $table.resultOutcome,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get analysisJson => $composableBuilder(
    column: $table.analysisJson,
    builder: (column) => ColumnFilters(column),
  );

  $$MatchesTableFilterComposer get matchId {
    final $$MatchesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.matchId,
      referencedTable: $db.matches,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MatchesTableFilterComposer(
            $db: $db,
            $table: $db.matches,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$GamesTableOrderingComposer
    extends Composer<_$AppDatabase, $GamesTable> {
  $$GamesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get gameNumber => $composableBuilder(
    column: $table.gameNumber,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isCrawford => $composableBuilder(
    column: $table.isCrawford,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get eventsJson => $composableBuilder(
    column: $table.eventsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resultWinner => $composableBuilder(
    column: $table.resultWinner,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get resultPoints => $composableBuilder(
    column: $table.resultPoints,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resultOutcome => $composableBuilder(
    column: $table.resultOutcome,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get analysisJson => $composableBuilder(
    column: $table.analysisJson,
    builder: (column) => ColumnOrderings(column),
  );

  $$MatchesTableOrderingComposer get matchId {
    final $$MatchesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.matchId,
      referencedTable: $db.matches,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MatchesTableOrderingComposer(
            $db: $db,
            $table: $db.matches,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$GamesTableAnnotationComposer
    extends Composer<_$AppDatabase, $GamesTable> {
  $$GamesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get gameNumber => $composableBuilder(
    column: $table.gameNumber,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isCrawford => $composableBuilder(
    column: $table.isCrawford,
    builder: (column) => column,
  );

  GeneratedColumn<String> get eventsJson => $composableBuilder(
    column: $table.eventsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get resultWinner => $composableBuilder(
    column: $table.resultWinner,
    builder: (column) => column,
  );

  GeneratedColumn<int> get resultPoints => $composableBuilder(
    column: $table.resultPoints,
    builder: (column) => column,
  );

  GeneratedColumn<String> get resultOutcome => $composableBuilder(
    column: $table.resultOutcome,
    builder: (column) => column,
  );

  GeneratedColumn<String> get analysisJson => $composableBuilder(
    column: $table.analysisJson,
    builder: (column) => column,
  );

  $$MatchesTableAnnotationComposer get matchId {
    final $$MatchesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.matchId,
      referencedTable: $db.matches,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MatchesTableAnnotationComposer(
            $db: $db,
            $table: $db.matches,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$GamesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $GamesTable,
          GameRow,
          $$GamesTableFilterComposer,
          $$GamesTableOrderingComposer,
          $$GamesTableAnnotationComposer,
          $$GamesTableCreateCompanionBuilder,
          $$GamesTableUpdateCompanionBuilder,
          (GameRow, $$GamesTableReferences),
          GameRow,
          PrefetchHooks Function({bool matchId})
        > {
  $$GamesTableTableManager(_$AppDatabase db, $GamesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GamesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GamesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GamesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> matchId = const Value.absent(),
                Value<int> gameNumber = const Value.absent(),
                Value<bool> isCrawford = const Value.absent(),
                Value<String> eventsJson = const Value.absent(),
                Value<String?> resultWinner = const Value.absent(),
                Value<int?> resultPoints = const Value.absent(),
                Value<String?> resultOutcome = const Value.absent(),
                Value<String?> analysisJson = const Value.absent(),
              }) => GamesCompanion(
                id: id,
                matchId: matchId,
                gameNumber: gameNumber,
                isCrawford: isCrawford,
                eventsJson: eventsJson,
                resultWinner: resultWinner,
                resultPoints: resultPoints,
                resultOutcome: resultOutcome,
                analysisJson: analysisJson,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int matchId,
                required int gameNumber,
                required bool isCrawford,
                required String eventsJson,
                Value<String?> resultWinner = const Value.absent(),
                Value<int?> resultPoints = const Value.absent(),
                Value<String?> resultOutcome = const Value.absent(),
                Value<String?> analysisJson = const Value.absent(),
              }) => GamesCompanion.insert(
                id: id,
                matchId: matchId,
                gameNumber: gameNumber,
                isCrawford: isCrawford,
                eventsJson: eventsJson,
                resultWinner: resultWinner,
                resultPoints: resultPoints,
                resultOutcome: resultOutcome,
                analysisJson: analysisJson,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) =>
                    (e.readTable(table), $$GamesTableReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback: ({matchId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (matchId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.matchId,
                                referencedTable: $$GamesTableReferences
                                    ._matchIdTable(db),
                                referencedColumn: $$GamesTableReferences
                                    ._matchIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$GamesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $GamesTable,
      GameRow,
      $$GamesTableFilterComposer,
      $$GamesTableOrderingComposer,
      $$GamesTableAnnotationComposer,
      $$GamesTableCreateCompanionBuilder,
      $$GamesTableUpdateCompanionBuilder,
      (GameRow, $$GamesTableReferences),
      GameRow,
      PrefetchHooks Function({bool matchId})
    >;
typedef $$SettingsTableCreateCompanionBuilder =
    SettingsCompanion Function({
      Value<int> id,
      Value<String> themeMode,
      Value<String> animationSpeed,
      Value<int> defaultMatchLength,
      Value<String> defaultDifficulty,
      Value<String?> tutorOverride,
      Value<bool> showHighlights,
      Value<bool> enableDrag,
      Value<bool> enableCombinedTaps,
      Value<bool> showScoring,
    });
typedef $$SettingsTableUpdateCompanionBuilder =
    SettingsCompanion Function({
      Value<int> id,
      Value<String> themeMode,
      Value<String> animationSpeed,
      Value<int> defaultMatchLength,
      Value<String> defaultDifficulty,
      Value<String?> tutorOverride,
      Value<bool> showHighlights,
      Value<bool> enableDrag,
      Value<bool> enableCombinedTaps,
      Value<bool> showScoring,
    });

class $$SettingsTableFilterComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get themeMode => $composableBuilder(
    column: $table.themeMode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get animationSpeed => $composableBuilder(
    column: $table.animationSpeed,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get defaultMatchLength => $composableBuilder(
    column: $table.defaultMatchLength,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get defaultDifficulty => $composableBuilder(
    column: $table.defaultDifficulty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tutorOverride => $composableBuilder(
    column: $table.tutorOverride,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get showHighlights => $composableBuilder(
    column: $table.showHighlights,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get enableDrag => $composableBuilder(
    column: $table.enableDrag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get enableCombinedTaps => $composableBuilder(
    column: $table.enableCombinedTaps,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get showScoring => $composableBuilder(
    column: $table.showScoring,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get themeMode => $composableBuilder(
    column: $table.themeMode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get animationSpeed => $composableBuilder(
    column: $table.animationSpeed,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get defaultMatchLength => $composableBuilder(
    column: $table.defaultMatchLength,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get defaultDifficulty => $composableBuilder(
    column: $table.defaultDifficulty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tutorOverride => $composableBuilder(
    column: $table.tutorOverride,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get showHighlights => $composableBuilder(
    column: $table.showHighlights,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get enableDrag => $composableBuilder(
    column: $table.enableDrag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get enableCombinedTaps => $composableBuilder(
    column: $table.enableCombinedTaps,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get showScoring => $composableBuilder(
    column: $table.showScoring,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get themeMode =>
      $composableBuilder(column: $table.themeMode, builder: (column) => column);

  GeneratedColumn<String> get animationSpeed => $composableBuilder(
    column: $table.animationSpeed,
    builder: (column) => column,
  );

  GeneratedColumn<int> get defaultMatchLength => $composableBuilder(
    column: $table.defaultMatchLength,
    builder: (column) => column,
  );

  GeneratedColumn<String> get defaultDifficulty => $composableBuilder(
    column: $table.defaultDifficulty,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tutorOverride => $composableBuilder(
    column: $table.tutorOverride,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get showHighlights => $composableBuilder(
    column: $table.showHighlights,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get enableDrag => $composableBuilder(
    column: $table.enableDrag,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get enableCombinedTaps => $composableBuilder(
    column: $table.enableCombinedTaps,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get showScoring => $composableBuilder(
    column: $table.showScoring,
    builder: (column) => column,
  );
}

class $$SettingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SettingsTable,
          SettingsRow,
          $$SettingsTableFilterComposer,
          $$SettingsTableOrderingComposer,
          $$SettingsTableAnnotationComposer,
          $$SettingsTableCreateCompanionBuilder,
          $$SettingsTableUpdateCompanionBuilder,
          (
            SettingsRow,
            BaseReferences<_$AppDatabase, $SettingsTable, SettingsRow>,
          ),
          SettingsRow,
          PrefetchHooks Function()
        > {
  $$SettingsTableTableManager(_$AppDatabase db, $SettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> themeMode = const Value.absent(),
                Value<String> animationSpeed = const Value.absent(),
                Value<int> defaultMatchLength = const Value.absent(),
                Value<String> defaultDifficulty = const Value.absent(),
                Value<String?> tutorOverride = const Value.absent(),
                Value<bool> showHighlights = const Value.absent(),
                Value<bool> enableDrag = const Value.absent(),
                Value<bool> enableCombinedTaps = const Value.absent(),
                Value<bool> showScoring = const Value.absent(),
              }) => SettingsCompanion(
                id: id,
                themeMode: themeMode,
                animationSpeed: animationSpeed,
                defaultMatchLength: defaultMatchLength,
                defaultDifficulty: defaultDifficulty,
                tutorOverride: tutorOverride,
                showHighlights: showHighlights,
                enableDrag: enableDrag,
                enableCombinedTaps: enableCombinedTaps,
                showScoring: showScoring,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> themeMode = const Value.absent(),
                Value<String> animationSpeed = const Value.absent(),
                Value<int> defaultMatchLength = const Value.absent(),
                Value<String> defaultDifficulty = const Value.absent(),
                Value<String?> tutorOverride = const Value.absent(),
                Value<bool> showHighlights = const Value.absent(),
                Value<bool> enableDrag = const Value.absent(),
                Value<bool> enableCombinedTaps = const Value.absent(),
                Value<bool> showScoring = const Value.absent(),
              }) => SettingsCompanion.insert(
                id: id,
                themeMode: themeMode,
                animationSpeed: animationSpeed,
                defaultMatchLength: defaultMatchLength,
                defaultDifficulty: defaultDifficulty,
                tutorOverride: tutorOverride,
                showHighlights: showHighlights,
                enableDrag: enableDrag,
                enableCombinedTaps: enableCombinedTaps,
                showScoring: showScoring,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SettingsTable,
      SettingsRow,
      $$SettingsTableFilterComposer,
      $$SettingsTableOrderingComposer,
      $$SettingsTableAnnotationComposer,
      $$SettingsTableCreateCompanionBuilder,
      $$SettingsTableUpdateCompanionBuilder,
      (SettingsRow, BaseReferences<_$AppDatabase, $SettingsTable, SettingsRow>),
      SettingsRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$MatchesTableTableManager get matches =>
      $$MatchesTableTableManager(_db, _db.matches);
  $$GamesTableTableManager get games =>
      $$GamesTableTableManager(_db, _db.games);
  $$SettingsTableTableManager get settings =>
      $$SettingsTableTableManager(_db, _db.settings);
}
