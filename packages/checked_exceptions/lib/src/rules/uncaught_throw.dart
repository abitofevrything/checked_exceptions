import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart' hide LintCode;
import 'package:analyzer/error/listener.dart';
import 'package:checked_exceptions/src/configuration.dart';
import 'package:checked_exceptions/src/configuration_builder.dart';
import 'package:checked_exceptions/src/util/expression_finder.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

class UncaughtThrow extends DartLintRule {
  static const _code = LintCode(
    name: 'uncaught_throw',
    problemMessage: "{0} can't be thrown here",
    errorSeverity: ErrorSeverity.ERROR,
  );

  UncaughtThrow() : super(code: _code);

  final List<(Expression, Throws computedThrows, Throws allowedThrows)>
  expressions = [];

  @override
  Future<void> startUp(
    CustomLintResolver resolver,
    CustomLintContext context,
  ) async {
    this.expressions.clear();

    final unitResult = await resolver.getResolvedUnitResult();
    final session = unitResult.session;

    final expressions = unitResult.unit.accept(ExpressionFinder())!;

    await Future.wait(
      expressions.map((expression) async {
        final configuration = await session.configurationBuilder
            .getConfiguration(expression);

        AstNode? parentProvidingConfiguration;

        List<DartType> caughtTypes = [];

        do {
          parentProvidingConfiguration = expression.thisOrAncestorMatching(
            (parent) =>
                parent != expression && parent is FunctionExpression ||
                parent is TryStatement,
          );

          if (parentProvidingConfiguration is TryStatement) {
            for (final catchClause
                in parentProvidingConfiguration.catchClauses) {
              if (catchClause.exceptionType case final type?) {
                caughtTypes.add(type.type!);
              } else {
                // Catch-all, expression can throw anything. We don't need to
                // check it.
                return;
              }
            }
          }
        } while (parentProvidingConfiguration is TryStatement);

        if (parentProvidingConfiguration == null) {
          return;
        }

        if (parentProvidingConfiguration.parent is FunctionDeclaration) {
          parentProvidingConfiguration = parentProvidingConfiguration.parent;
        }

        assert(
          parentProvidingConfiguration is FunctionDeclaration ||
              parentProvidingConfiguration is MethodDeclaration,
        );

        final parentConfiguration = await session.configurationBuilder
            .getConfiguration(parentProvidingConfiguration!);

        var bodyConfiguration =
            parentConfiguration.valueConfigurations[PromotionType.invoke]!;
        if (parentProvidingConfiguration is FunctionDeclaration &&
            parentProvidingConfiguration
                .functionExpression
                .body
                .isAsynchronous) {
          bodyConfiguration =
              bodyConfiguration.valueConfigurations[PromotionType.await_]!;
        } else if (parentProvidingConfiguration is FunctionExpression &&
            parentProvidingConfiguration.body.isAsynchronous) {
          bodyConfiguration =
              bodyConfiguration.valueConfigurations[PromotionType.await_]!;
        }

        this.expressions.add((
          expression,
          configuration.throws,
          Throws(
            thrownTypes: {
              ...bodyConfiguration.throws.thrownTypes,
              ...caughtTypes,
            },
            canThrowUndeclaredErrors:
                bodyConfiguration.throws.canThrowUndeclaredErrors,
          ),
        ));
      }),
    );
  }

  @override
  void run(
    CustomLintResolver resolver,
    ErrorReporter reporter,
    CustomLintContext context,
  ) {
    final exceptionType = TypeChecker.fromUrl('dart:core#Exception');

    for (final (expression, computed, allowed) in expressions) {
      if (computed.canThrowUndeclaredErrors &&
          !allowed.canThrowUndeclaredErrors) {
        reporter.atNode(expression, _code, arguments: ['Object']);
      }

      for (final thrownType in computed.thrownTypes) {
        if (allowed.canThrowUndeclaredErrors &&
            !exceptionType.isAssignableFromType(thrownType)) {
          continue;
        }

        if (allowed.thrownTypes.any(
          (allowedType) => TypeChecker.fromStatic(
            allowedType,
          ).isAssignableFromType(thrownType),
        )) {
          continue;
        }

        reporter.atNode(
          expression,
          _code,
          arguments: [thrownType.getDisplayString()],
        );
      }
    }
  }
}
