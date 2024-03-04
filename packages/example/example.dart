import 'package:checked_exceptions_annotations/checked_exceptions_annotations.dart';

@neverThrows
@safe
void foo() async {
  bar();
  baz();
  (1 > 0 ? bar : () {})();
  (bar as dynamic)();

  2.0 as int;
  2.0 as dynamic;

  final future = awaitTime();
  await future;

  ~Test();

  int.parse('not an int');

  needsSafeArgument(() => throw Exception());
  needsSafeArgument(baz);

  @safe
  var localFn = baz;
  localFn = baz;

  @safe
  final foo = baz();
}

void bar() {
  throw Exception();
}

@Throws<Exception>()
void Function() baz() => () {};

void needsSafeArgument(@safe void Function() f) {}

Future<void> awaitTime() async {
  throw Exception();
}

class Test {
  @Throws<Exception>()
  void operator ~() {}

  @safe
  void safeMember() {}
}

class Test1 extends Test {
  @override
  void safeMember() => throw Exception();
}

class Test2 extends Test {
  @override
  @Throws<Exception>()
  void safeMember() {}
}
