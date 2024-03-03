import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:checked_exceptions/src/configuration_builder.dart';

class ElementFinder<T extends Element> extends GeneralizingAstVisitor<List<Declaration>> {
  @override
  List<Declaration> visitNode(AstNode node) => [
        for (final child in node.childEntities)
          if (child is AstNode) ...child.accept(this)!,
      ];

  @override
  List<Declaration> visitDeclaration(Declaration node) => [
        if (node.declaredElement is T) node,
        ...super.visitDeclaration(node)!,
      ];
}

final Expando<Future<ConfigurationBuilder>> _sessionBuilders = Expando();

extension SessionConfigurationBuilder on AnalysisSession {
  Future<ConfigurationBuilder> get configurationBuilder async =>
      await (_sessionBuilders[this] ??= ConfigurationBuilder.forSession(this));
}
