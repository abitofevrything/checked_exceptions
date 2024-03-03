import 'package:analyzer/dart/element/type.dart';

/// The way in which the value of an expression can cause errors to be thrown.
enum PromotionType {
  /// The value is a [Future] that might throw errors when it is awaited.
  await_,

  /// The value is a [Function] that might throw errors when it is invoked.
  invoke,
}

/// Represents the errors thrown by an expression and its value.
class Configuration {
  /// The types of values thrown when evaluating the expression.
  ///
  /// This only lists errors thrown by _exactly_ the expression this [Configuration] is for and not
  /// any sub-expressions.
  final List<DartType> thrownTypes;

  /// A mapping of [PromotionType] to configurations resulting from that promotion on the
  /// expression's value.
  final Map<PromotionType, Configuration> valueConfigurations;

  Configuration(this.thrownTypes, this.valueConfigurations);
}
