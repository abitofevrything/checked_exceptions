import 'package:checked_exceptions_annotations/checked_exceptions_annotations.dart';

// ignore_for_file: unused_local_variable

void inferThrowsException() => throw Exception();

void inferThrowsError() => throw Error();

void indirectlyThrowsException() => inferThrowsException();

void indirectlyThrowsError() => inferThrowsError();

@Throws<Exception>()
void explicitThrowsException() {}

@ThrowsError<Error>()
void explicitThrowsError() {}

@safe
void safeFunction() {
  if (1 == 1) throw Exception();
  if (1 == 1) throw Error();

  inferThrowsException();
  inferThrowsError();

  indirectlyThrowsException();
  indirectlyThrowsError();

  explicitThrowsException();
  explicitThrowsError();

  safeFunction();
  neverThrowsFunction();
}

@neverThrows
void neverThrowsFunction() {
  if (1 == 1) throw Exception();
  if (1 == 1) throw Error();

  inferThrowsException();
  inferThrowsError();

  indirectlyThrowsException();
  indirectlyThrowsError();

  explicitThrowsException();
  explicitThrowsError();

  safeFunction();
  neverThrowsFunction();
}

void parameterTests({
  @safe required void Function() safeFunction,
  @neverThrows required void Function() neverThrowsFunction,
  @Throws<Exception>() required void Function() throwsExceptionFunction,
  @ThrowsError<Error>() required void Function() throwsErrorFunction,
}) {}

void main() {
  parameterTests(
    safeFunction: safeFunction,
    neverThrowsFunction: safeFunction,
    throwsExceptionFunction: safeFunction,
    throwsErrorFunction: safeFunction,
  );
  parameterTests(
    safeFunction: neverThrowsFunction,
    neverThrowsFunction: neverThrowsFunction,
    throwsExceptionFunction: neverThrowsFunction,
    throwsErrorFunction: neverThrowsFunction,
  );
  parameterTests(
    safeFunction: inferThrowsException,
    neverThrowsFunction: inferThrowsException,
    throwsExceptionFunction: inferThrowsException,
    throwsErrorFunction: inferThrowsException,
  );
  parameterTests(
    safeFunction: inferThrowsError,
    neverThrowsFunction: inferThrowsError,
    throwsExceptionFunction: inferThrowsError,
    throwsErrorFunction: inferThrowsError,
  );
}
