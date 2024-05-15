import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:checked_exceptions/src/configuration_builder.dart';

class NodeFinder<T extends AstNode> extends UnifyingAstVisitor<List<T>> {
  final bool Function(T)? predicate;

  NodeFinder([this.predicate]);

  @override
  List<T> visitNode(AstNode node) => [
        if (node is T && (predicate == null || predicate!(node))) node,
        for (final childNode in node.childEntities.whereType<AstNode>())
          ...childNode.accept(this)!
      ];
}

final Expando<Future<ConfigurationBuilder>> _sessionBuilders = Expando();

extension SessionConfigurationBuilder on AnalysisSession {
  Future<ConfigurationBuilder> get configurationBuilder async =>
      await (_sessionBuilders[this] ??= ConfigurationBuilder.forSession(this));
}
