void simpleThrows() {
  throw Exception('Uncaught exception');
}

void indirect() => simpleThrows();

final callsSimpleThrows = simpleThrows();
