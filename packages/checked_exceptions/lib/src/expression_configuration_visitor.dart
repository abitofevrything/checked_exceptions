import 'package:analyzer/dart/ast/ast.dart' hide Configuration;
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:checked_exceptions/src/configuration.dart';
import 'package:checked_exceptions/src/configuration_builder.dart';
import 'package:checked_exceptions/src/throw_finder.dart';

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
  Future<Configuration?> visitAsExpression(AsExpression node) async {
    final thrownTypes = switch (node.type.type) {
      DynamicType() => <DartType>[],
      InterfaceType(isDartCoreObject: true, nullabilitySuffix: NullabilitySuffix.question) =>
        <DartType>[],
      _ => [builder.typeErrorType],
    };

    return Configuration(
      (thrownTypes: thrownTypes, canThrowUndeclaredErrors: false),
      (await builder.getExpressionConfiguration(node.expression))?.valueConfigurations ?? {},
    );
  }

  @override
  Future<Configuration?> visitAssignmentExpression(AssignmentExpression node) async {
    final valueConfiguration = await builder.getExpressionConfiguration(node.leftHandSide);
    final writeElement = node.writeElement;
    if (valueConfiguration == null ||
        writeElement is! PropertyAccessorElement ||
        !writeElement.isSetter) {
      return null;
    }

    final writeConfiguration = await builder.getElementConfiguration(writeElement);
    if (writeConfiguration == null) return null;

    return Configuration(
      writeConfiguration.throws,
      valueConfiguration.valueConfigurations,
    );
  }

  @override
  Future<Configuration?> visitAwaitExpression(AwaitExpression node) async {
    final nestedConfiguration = await builder.getExpressionConfiguration(node.expression);
    return nestedConfiguration?.valueConfigurations[PromotionType.await_];
  }

  @override
  Future<Configuration?> visitBinaryExpression(BinaryExpression node) async {
    final method = node.staticElement;
    if (method == null) return null;
    return (await builder.getElementConfiguration(method))
        ?.valueConfigurations[PromotionType.invoke];
  }

  @override
  Future<Configuration?> visitCascadeExpression(CascadeExpression node) async {
    final nestedConfiguration = await builder.getExpressionConfiguration(node.target);
    if (nestedConfiguration == null) return null;
    return Configuration(
      (thrownTypes: [], canThrowUndeclaredErrors: false),
      nestedConfiguration.valueConfigurations,
    );
  }

  @override
  Future<Configuration?> visitConditionalExpression(ConditionalExpression node) async {
    final thenConfiguration = await builder.getExpressionConfiguration(node.thenExpression);
    final elseConfiguration = await builder.getExpressionConfiguration(node.elseExpression);

    final configurations = [
      if (thenConfiguration != null) thenConfiguration,
      if (elseConfiguration != null) elseConfiguration,
    ];

    return Configuration.unionConfigurations(configurations);
  }

  @override
  Future<Configuration?> visitConstructorReference(ConstructorReference node) async {
    final constructorElement = node.constructorName.staticElement;
    if (constructorElement == null) return null;
    return await builder.getElementConfiguration(constructorElement);
  }

  @override
  Future<Configuration?> visitFunctionExpression(FunctionExpression node) async {
    final staticParameterElement = node.staticParameterElement;
    if (staticParameterElement != null) {
      final parameterConfiguration = await builder.getElementConfiguration(staticParameterElement);
      if (parameterConfiguration != null) return parameterConfiguration;
    }

    final throws = await node.body.accept(ThrowFinder(builder))!;

    // If we find no throws, we want to return a configuration that throws nothing, and not `null`,
    // which would be returned by Configuration.unionConfigurations.
    if (throws.isEmpty) {
      return Configuration(
        (thrownTypes: [], canThrowUndeclaredErrors: false),
        {
          PromotionType.invoke:
              Configuration((thrownTypes: [], canThrowUndeclaredErrors: false), {})
        },
      );
    }

    return Configuration.unionConfigurations([
      for (final throws in throws.values)
        Configuration(
          (thrownTypes: [], canThrowUndeclaredErrors: false),
          {PromotionType.invoke: Configuration(throws, {})},
        ),
    ]);
  }

  @override
  Future<Configuration?> visitFunctionReference(FunctionReference node) async {
    final nestedConfiguration = await builder.getExpressionConfiguration(node.function);
    if (nestedConfiguration == null) return null;

    return Configuration(
      (thrownTypes: [], canThrowUndeclaredErrors: false),
      nestedConfiguration.valueConfigurations,
    );
  }

  @override
  Future<Configuration?> visitIdentifier(Identifier node) async {
    final staticElement = node.staticElement;
    if (staticElement == null) return null;
    return await builder.getElementConfiguration(staticElement);
  }

  @override
  Future<Configuration?> visitIndexExpression(IndexExpression node) async {
    final staticElement = node.staticElement;
    if (staticElement == null) return null;
    return (await builder.getElementConfiguration(staticElement))
        ?.valueConfigurations[PromotionType.invoke];
  }

  @override
  Future<Configuration?> visitInstanceCreationExpression(InstanceCreationExpression node) async {
    final constructorElement = node.constructorName.staticElement;
    if (constructorElement == null) return null;
    return (await builder.getElementConfiguration(constructorElement))
        ?.valueConfigurations[PromotionType.invoke];
  }

  @override
  Future<Configuration?> visitInvocationExpression(InvocationExpression node) async {
    final functionConfig = await builder.getExpressionConfiguration(node.function);
    return functionConfig?.valueConfigurations[PromotionType.invoke];
  }

  @override
  Future<Configuration?> visitIsExpression(IsExpression node) async {
    return Configuration((thrownTypes: [], canThrowUndeclaredErrors: false), {});
  }

  @override
  Future<Configuration?> visitLiteral(Literal node) async {
    return Configuration((thrownTypes: [], canThrowUndeclaredErrors: false), {});
  }

  @override
  Future<Configuration?> visitNamedExpression(NamedExpression node) async {
    final nestedConfiguration = await builder.getExpressionConfiguration(node.expression);
    if (nestedConfiguration == null) return null;

    return Configuration(
      (thrownTypes: [], canThrowUndeclaredErrors: false),
      nestedConfiguration.valueConfigurations,
    );
  }

  @override
  Future<Configuration?> visitParenthesizedExpression(ParenthesizedExpression node) async {
    final nestedConfiguration = await builder.getExpressionConfiguration(node.expression);
    if (nestedConfiguration == null) return null;

    return Configuration(
      (thrownTypes: [], canThrowUndeclaredErrors: false),
      nestedConfiguration.valueConfigurations,
    );
  }

  @override
  Future<Configuration?> visitPostfixExpression(PostfixExpression node) async {
    final staticElement = node.staticElement;
    if (staticElement == null) {
      if (node.operator.type == TokenType.BANG) {
        final nestedConfiguration = await builder.getExpressionConfiguration(node.operand);
        return Configuration(
          (thrownTypes: [builder.typeErrorType], canThrowUndeclaredErrors: false),
          nestedConfiguration?.valueConfigurations ?? {},
        );
      }
      return null;
    }
    return (await builder.getElementConfiguration(staticElement))
        ?.valueConfigurations[PromotionType.invoke];
  }

  @override
  Future<Configuration?> visitPrefixExpression(PrefixExpression node) async {
    final staticElement = node.staticElement;
    if (staticElement == null) return null;
    return (await builder.getElementConfiguration(staticElement))
        ?.valueConfigurations[PromotionType.invoke];
  }

  @override
  Future<Configuration?> visitPropertyAccess(PropertyAccess node) async {
    final staticElement = node.propertyName.staticElement;
    if (staticElement == null) return null;
    return await builder.getElementConfiguration(staticElement);
  }

  @override
  Future<Configuration?> visitRethrowExpression(RethrowExpression node) async {
    var catchClause = node.parent;
    while (catchClause is! CatchClause?) {
      catchClause = catchClause.parent;
    }
    if (catchClause is! CatchClause) return null;

    return Configuration(
      (
        thrownTypes: [catchClause.exceptionType?.type ?? builder.objectType],
        canThrowUndeclaredErrors: false
      ),
      {},
    );
  }

  @override
  Future<Configuration?> visitSuperExpression(SuperExpression node) async {
    final type = node.staticType;
    if (type == null) return null;

    return Configuration(
      (thrownTypes: [], canThrowUndeclaredErrors: false),
      await builder.computeTypeConfiguration(type) ?? {},
    );
  }

  @override
  Future<Configuration?> visitSwitchExpression(SwitchExpression node) async {
    final caseConfigurations = await Future.wait(
      node.cases.map((e) => e.expression).map(builder.getExpressionConfiguration),
    );
    return Configuration.unionConfigurations(caseConfigurations.nonNulls.toList());
  }

  @override
  Future<Configuration?> visitThisExpression(ThisExpression node) async {
    final type = node.staticType;
    if (type == null) return null;

    return Configuration(
      (thrownTypes: [], canThrowUndeclaredErrors: false),
      await builder.computeTypeConfiguration(type) ?? {},
    );
  }

  @override
  Future<Configuration?> visitTypeLiteral(TypeLiteral node) async {
    return Configuration((thrownTypes: [], canThrowUndeclaredErrors: false), {});
  }

  @override
  Future<Configuration?> visitThrowExpression(ThrowExpression node) async {
    return Configuration(
      (
        thrownTypes: [if (node.expression.staticType case final type?) type],
        canThrowUndeclaredErrors: false,
      ),
      (await builder.getExpressionConfiguration(node.expression))?.valueConfigurations ?? {},
    );
  }
}
