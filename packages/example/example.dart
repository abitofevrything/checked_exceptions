import 'package:checked_exceptions_annotations/checked_exceptions_annotations.dart';

@neverThrows
void foo() async {
  bar();
  baz();
  (1 > 0 ? () bar : () {})();
  (bar as dynamic)():

  2.0 as int;
  2.0 as dynamic;


  final future = awaitTime();
  await future;

  ~Test();

  int.parse('not an int');

  needsSafeArgument(() => throw Exception());
}

void bar() {
  throw Exception();
}

@Throws<Exception>()
void baz() {}

void needsSafeArgument(@safe void Function() f) {}

Future<void> awaitTime() async {
  throw Exception();
}

class Test {
  @Throws<Exception>()
  void operator~() {}
}
