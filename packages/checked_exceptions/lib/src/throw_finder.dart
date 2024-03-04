import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:checked_exceptions/src/configuration.dart';
import 'package:checked_exceptions/src/configuration_builder.dart';

/// A visitor that computes the locations errors may be thrown in a function's body.
class ThrowFinder extends UnifyingAstVisitor<Future<Map<AstNode, Throws>>> {
  /// The [ConfigurationBuilder] this [ThrowFinder] is for.
  final ConfigurationBuilder builder;

  ThrowFinder(this.builder);

  @override
  Future<Map<AstNode, Throws>> visitNode(AstNode node) async {
    final results = await Future.wait(
      node.childEntities.whereType<AstNode>().map((e) => e.accept(this)!),
    );

    if (node is Expression) {
      final nodeConfiguration = await builder.getExpressionConfiguration(node);
      if (nodeConfiguration != null) {
        results.add({node: nodeConfiguration.throws});
      }
    }

    if (results.isEmpty) return {};
    return results.reduce((value, element) => {...value, ...element});
  }

  @override
  Future<Map<AstNode, Throws>> visitFunctionExpression(FunctionExpression node) async => {};

  @override
  Future<Map<AstNode, Throws>> visitVariableDeclaration(VariableDeclaration node) async =>
      node.isLate ? {} : await super.visitVariableDeclaration(node)!;
}
