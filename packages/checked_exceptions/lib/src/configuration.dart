import 'package:analyzer/dart/element/type.dart';
import 'package:collection/collection.dart';
import 'package:checked_exceptions_annotations/checked_exceptions_annotations.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

/// The way in which the value of an expression can cause errors to be thrown.
enum PromotionType {
  /// The value is a [Future] that might throw errors when it is awaited.
  await_('await'),

  /// The value is a [Function] that might throw errors when it is invoked.
  invoke('invoke');

  final String key;
  const PromotionType(this.key);
}

/// The subset of a [Configuration] that the type of an expression can represent.
///
/// This corresponds to [Configuration.valueConfigurations]. Given a type, we can deduce
/// information about the value of an expression with that type, but not information about the
/// expression itself.
typedef ValueThrows = Map<PromotionType, Configuration>;

/// The information provided by a combination [safe], [neverThrows], [Throws] and [ThrowsError]
/// annotations on an element.

class Throws {
  static final Throws empty = Throws(
    thrownTypes: {},
    canThrowUndeclaredErrors: false,
    isInferred: true,
  );

  final Set<DartType> thrownTypes;

  final bool canThrowUndeclaredErrors;

  final bool isInferred;

  Throws({
    required this.thrownTypes,
    required this.canThrowUndeclaredErrors,
    this.isInferred = true,
  });

  Throws.exactly(this.thrownTypes, {this.isInferred = true})
    : canThrowUndeclaredErrors = false;

  Throws.explicit(this.thrownTypes, {required this.canThrowUndeclaredErrors})
    : isInferred = false;

  @override
  int get hashCode => Object.hash(
    const SetEquality().hash(thrownTypes),
    canThrowUndeclaredErrors,
    isInferred,
  );

  @override
  bool operator ==(Object other) =>
      other is Throws &&
      const SetEquality().equals(thrownTypes, other.thrownTypes) &&
      other.canThrowUndeclaredErrors == canThrowUndeclaredErrors &&
      other.isInferred == isInferred;

  @override
  String toString() =>
      'Throws($thrownTypes, can throw undeclared: $canThrowUndeclaredErrors, inferred: $isInferred)';
}

/// Represents the errors thrown by an expression and its value.
class Configuration {
  /// The types of values thrown when evaluating the expression.
  ///
  /// This only lists errors thrown by _exactly_ the expression this [Configuration] is for and not
  /// any sub-expressions.
  final Throws throws;

  /// A mapping of [PromotionType] to configurations resulting from that promotion on the
  /// expression's value.
  final ValueThrows valueConfigurations;

  static final Configuration empty = Configuration(Throws.empty, {});

  Configuration(this.throws, this.valueConfigurations);

  Configuration.throwsExactly(DartType error)
    : throws = Throws.exactly({error}),
      valueConfigurations = {};

  Configuration.throws(this.throws) : valueConfigurations = {};

  Configuration.forValue(this.valueConfigurations) : throws = Throws.empty;

  bool isCompatible(Configuration parameter) {
    if (throws.canThrowUndeclaredErrors &&
        !parameter.throws.canThrowUndeclaredErrors) {
      return false;
    }

    final exceptionType = TypeChecker.fromUrl('dart:core#Exception');

    nextThrownType:
    for (final thrownType in throws.thrownTypes) {
      if (parameter.throws.canThrowUndeclaredErrors &&
          !exceptionType.isAssignableFromType(thrownType)) {
        continue;
      }

      for (final allowedType in parameter.throws.thrownTypes) {
        if (TypeChecker.fromStatic(
          allowedType,
        ).isAssignableFromType(thrownType)) {
          continue nextThrownType;
        }
      }

      return false;
    }

    for (final MapEntry(:key, :value)
        in parameter.valueConfigurations.entries) {
      if (valueConfigurations[key] case final argumentConfiguration?) {
        if (!argumentConfiguration.isCompatible(value)) {
          return false;
        }
      } else {
        return false;
      }
    }

    return true;
  }

  @override
  int get hashCode =>
      Object.hash(throws, const MapEquality().hash(valueConfigurations));

  @override
  bool operator ==(Object other) =>
      other is Configuration &&
      const MapEquality().equals(
        other.valueConfigurations,
        valueConfigurations,
      ) &&
      other.throws == throws;

  @override
  String toString() => 'Configuration($throws, $valueConfigurations)';
}
