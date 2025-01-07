import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

class ExpressionFinder extends GeneralizingAstVisitor<List<Expression>> {
  @override
  List<Expression> visitNode(AstNode node) => [
        if (node is Expression) node,
        for (final child in node.childEntities)
          if (child is AstNode) ...child.accept(this)!,
      ];
}
