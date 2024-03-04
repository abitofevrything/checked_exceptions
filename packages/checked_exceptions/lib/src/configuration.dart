import 'package:analyzer/dart/element/type.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';
import 'package:checked_exceptions_annotations/checked_exceptions_annotations.dart';

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
typedef Throws = ({List<DartType> thrownTypes, bool canThrowUndeclaredErrors});

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

  Configuration(this.throws, this.valueConfigurations);

  /// Whether an expression with this configuration can be assigned to a variable with the [other]
  /// configuration.
  bool isCompatibleWith(Configuration other, {int atLevel = 0}) {
    if (atLevel <= 0) {
      if (throws.canThrowUndeclaredErrors && !other.throws.canThrowUndeclaredErrors) {
        return other.throws.thrownTypes.any((element) => element.isDartCoreObject);
      }

      final exceptionTypeChecker = TypeChecker.fromUrl('dart:core#Exception');

      for (final thrownType in throws.thrownTypes) {
        if (!other.throws.thrownTypes.any((allowedType) =>
            TypeChecker.fromStatic(allowedType).isAssignableFromType(thrownType))) {
          if (!other.throws.canThrowUndeclaredErrors ||
              exceptionTypeChecker.isAssignableFromType(thrownType)) {
            return false;
          }
        }
      }
    }

    for (final MapEntry(:key, :value) in valueConfigurations.entries) {
      final otherValue = other.valueConfigurations[key];
      if (otherValue == null || value.isCompatibleWith(otherValue, atLevel: atLevel - 1)) continue;

      return false;
    }

    return true;
  }

  /// Returns a configuration that is compatible with all of [configurations].
  static Configuration? intersectConfigurations(List<Configuration> configurations) {
    if (configurations.isEmpty) return null;

    final canThrowUndeclaredErrors =
        configurations.every((element) => element.throws.canThrowUndeclaredErrors);

    final exceptionTypeChecker = TypeChecker.fromUrl('dart:core#Exception');

    // All of the types thrown by the first configuration...
    final thrownTypes = configurations.first.throws.thrownTypes.where(
      // ...where every other configuration...
      (thrownType) => configurations.skip(1).every(
            // ...declares at least one thrown type...
            (configuration) =>
                configuration.throws.thrownTypes.any(
                  // ...which matches the type thrown by the first configuration...
                  (declaredThrownType) =>
                      TypeChecker.fromStatic(declaredThrownType).isAssignableFromType(thrownType),
                ) ||
                // ...or allows undeclared errors, if the thrown type isn't an exception.
                (!exceptionTypeChecker.isAssignableFromType(thrownType) &&
                    configuration.throws.canThrowUndeclaredErrors),
          ),
    );

    return Configuration(
      (canThrowUndeclaredErrors: canThrowUndeclaredErrors, thrownTypes: thrownTypes.toList()),
      {
        for (final promotionType in PromotionType.values)
          if (configurations.map((c) => c.valueConfigurations[promotionType]).nonNulls.toList()
              case final configurationsToIntersect when configurationsToIntersect.isNotEmpty)
            promotionType: intersectConfigurations(configurationsToIntersect)!,
      },
    );
  }

  /// Returns a configuration that every element of [configurations] is compatible with.
  static Configuration? unionConfigurations(List<Configuration> configurations) {
    if (configurations.isEmpty) return null;

    final canThrowUndeclaredErrors =
        configurations.any((element) => element.throws.canThrowUndeclaredErrors);

    final thrownTypes = <DartType>{};

    for (final thrownType in configurations.expand((element) => element.throws.thrownTypes)) {
      if (thrownTypes.any(
        (alreadyThrownType) =>
            TypeChecker.fromStatic(alreadyThrownType).isAssignableFromType(thrownType),
      )) {
        continue;
      }

      thrownTypes.removeWhere(
        (alreadyThrownType) =>
            TypeChecker.fromStatic(thrownType).isAssignableFromType(alreadyThrownType),
      );

      thrownTypes.add(thrownType);
    }

    return Configuration(
      (canThrowUndeclaredErrors: canThrowUndeclaredErrors, thrownTypes: thrownTypes.toList()),
      {
        for (final promotionType in PromotionType.values)
          if (configurations.map((c) => c.valueConfigurations[promotionType]).nonNulls.toList()
              case final configurationsToIntersect when configurationsToIntersect.isNotEmpty)
            promotionType: unionConfigurations(configurationsToIntersect)!,
      },
    );
  }
}
