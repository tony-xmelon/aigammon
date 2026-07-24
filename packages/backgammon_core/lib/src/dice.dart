class Dice {
  final int die1;
  final int die2;

  Dice(this.die1, this.die2) {
    if (die1 < 1 || die1 > 6 || die2 < 1 || die2 > 6) {
      throw ArgumentError('dice must be 1-6, got $die1/$die2');
    }
  }

  bool get isDouble => die1 == die2;
  int get high => die1 > die2 ? die1 : die2;
  int get low => die1 < die2 ? die1 : die2;

  @override
  bool operator ==(Object other) =>
      other is Dice && other.die1 == die1 && other.die2 == die2;

  @override
  int get hashCode => Object.hash(die1, die2);

  @override
  String toString() => '$die1$die2';
}
