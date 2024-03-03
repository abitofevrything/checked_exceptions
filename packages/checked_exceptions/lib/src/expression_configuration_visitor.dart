import 'package:analyzer/dart/ast/ast.dart' hide Configuration;
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:checked_exceptions/src/configuration.dart';
import 'package:checked_exceptions/src/configuration_builder.dart';

/// A visitor that computes the [Configuration] for an [Expression].
class ExpressionConfigurationVisitor extends GeneralizingAstVisitor<Future<Configuration?>> {
  /// The [ConfigurationBuilder] this [ExpressionConfigurationVisitor] is associated with.
  final ConfigurationBuilder builder;

  ExpressionConfigurationVisitor(this.builder);

  @override
  Future<Configuration?> visitNode(AstNode node) async {
    print('[BUILDER] Unexpectedly visited ${node.runtimeType}');
    return null;
  }

  @override
  Future<Configuration?> visitExpression(Expression node) async {
    print('[BUILDER] Unhandled expression type ${node.runtimeType}');
    return null;
  }

  @override
  Future<Configuration?> visitThrowExpression(ThrowExpression node) async {
    return Configuration(
      [if (node.expression.staticType case final type?) type],
      (await builder.getExpressionConfiguration(node.expression))?.valueConfigurations ?? {},
    );
  }
}
