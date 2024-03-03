import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:checked_exceptions/src/configuration_builder.dart';

/// A visitor that computes the locations errors may be thrown in a function's body.
class ThrowFinder extends UnifyingAstVisitor<Future<Map<AstNode, List<DartType>>>> {
  /// The [ConfigurationBuilder] this [ThrowFinder] is for.
  final ConfigurationBuilder builder;

  ThrowFinder(this.builder);

  @override
  Future<Map<AstNode, List<DartType>>> visitNode(AstNode node) async {
    final childResults = await Future.wait(
      node.childEntities.whereType<AstNode>().map((e) => e.accept(this)!),
    );

    if (childResults.isEmpty) return {};

    final result = childResults.reduce((value, element) => {...value, ...element});

    if (node is Expression) {
      final nodeConfiguration = await builder.getExpressionConfiguration(node);
      if (nodeConfiguration != null) result[node] = nodeConfiguration.thrownTypes;
    }

    return result;
  }
}
