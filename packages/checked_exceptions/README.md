# checked_exceptions

An analyzer plugin adding support for checked exceptions to Dart.

Checked exceptions are a way to statically declare which errors might be thrown by a function and check that they are handled at compile time. Doing so can allow developers to know in advance if their code may crash unexpectedly.

## Installation

Install `checked_exceptions_annotations` as a normal dependency, then install `checked_exceptions` and `custom_lint` as dev dependencies:
```
$ dart pub add checked_exceptions_annotations
$ dart pub add -d checked_exceptions custom_lint
```

Finally, add `custom_lint` to your analyzer plugins by adding the following to your `analysis_options.yaml`:
```yaml
analyzer:
  plugins:
    - custom_lint
```

## Usage

Most developers will want to ensure their functions to _not_ throw any errors. For that, they can annotate the function with `@safe`, and `checked_exceptions` will warn them if their code throws any errors:
```dart
@safe
void mySafeFunction() {
  throw Exception(); // LINT
}
```

If your function intentionally throws exceptions, you can annotate it with `@Throws` to indicate which types of exceptions it may throw:
```dart
@Throws<FormatException>()
void checkFormat(String source) {
  if (!hasCorrectFormat(source)) {
    throw FormatException();
  }
}
```
