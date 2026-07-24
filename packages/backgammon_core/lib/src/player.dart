enum Player {
  white,
  black;

  Player get opponent => this == white ? black : white;
}
