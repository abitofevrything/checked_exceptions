import 'package:meta/meta_meta.dart';

const _configurationTarget = Target({
  // Targets that can contain a value that has a configuration
  TargetKind.field,
  TargetKind.parameter,
  TargetKind.topLevelVariable,
  // Targets that are elements that have a configuration
  TargetKind.function,
  TargetKind.getter,
  TargetKind.method,
  TargetKind.setter,
  // Targets that represent the type of a value with a configuration
  TargetKind.typedefType,
});

/// {@template safe}
/// Used to annotate a type, function or variable to indicate it will not throw [Exception]s.
///
/// Elements annotated with [safe] may not throw any [Exception]s. They may however still throw any
/// error that is not an [Exception]. To indicate an element never throws, use [neverThrows].
///
/// - Fields and variables annotated with [safe] may not contain values that might throw an
///   [Exception].
/// - Functions, methods, getters and setters annotated with [safe] may not throw any [Exception]s
///   in their body.
/// - Variables whose type is a typedef annotated with [safe] may not contain values that might
///   throw an [Exception].
/// {@endtemplate}
@_configurationTarget
class Safe {
  /// {@macro safe}
  const Safe();
}

/// {@macro safe}
const safe = Safe();

/// {@template never_throws}
/// Used to annotate a type, function or variable to indicate it will never throw.
///
/// - Fields and variables annotated with [neverThrows] may not contain values that might throw.
/// - Functions, methods, getters and setters annotated with [neverThrows] may not throw in their
///   body.
/// - Variables whose type is a typedef annotated with [neverThrows] may not contain values that
///   might throw.
/// {@endtemplate}
@_configurationTarget
class NeverThrows extends Safe {
  /// {@macro never_throws}
  const NeverThrows();
}

/// {@macro never_throws}
const neverThrows = NeverThrows();

/// {@template throws_error}
/// Used to annotate a type, function or variable to list the types of values it may potentially
/// throw.
///
/// Use multiple [ThrowsError] annotations on an element to list the types of all the values it may
/// potentially throw.
///
/// - Fields and variables annotated with [ThrowsError] may not contain values that might throw a
///   value whose type is not listed in the element's annotations.
/// - Functions, methods, getters and setters annotated with [ThrowsError] may not throw values that
///   are not listed in the element's annotations in their body.
/// - Variables whose type is a typedef annotated with [ThrowsError] may not contain values that
///   might throw a value whose type is not listed in the typedef's annotations.
/// {@endtemplate}
@_configurationTarget
class ThrowsError<T extends Object> {
  /// {@macro throws_error}
  const ThrowsError();
}

/// {@template throws}
/// Used to annotate a type, function or variable to list the types of [Exception]s it may
/// potentially throw.
///
/// Use multiple [Throws] annotations on an element to list the types of [Exception]s it may throw.
///
/// Elements annotated with [Throws] may still throw values that are not [Exception]s. Use
/// [ThrowsError] instead to list the types of all the values potentially thrown by the element.
///
/// - Fields and variables annotated with [Throws] may not contain values that might throw an
///   [Exception] whose type is not listed in the element's annotations.
/// - Functions, methods, getters and setters annotated with [Throws] may not throw [Exception]s
///   that are not listed in the element's annotations in their body.
/// - Variables whose type is a typedef annotated with [Throws] may contain values that might
///   throw an [Exception] whose type is not listed in the typedef's annotations.
/// {@endtemplate}
@_configurationTarget
class Throws<T extends Exception> extends ThrowsError<T> {
  /// {@macro throws}
  const Throws();
}
