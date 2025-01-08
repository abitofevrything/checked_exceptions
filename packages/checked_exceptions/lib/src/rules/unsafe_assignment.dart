import 'package:analyzer/dart/ast/ast.dart' hide Configuration;
import 'package:analyzer/error/error.dart' hide LintCode;
import 'package:analyzer/error/listener.dart';
import 'package:checked_exceptions/src/configuration.dart';
import 'package:checked_exceptions/src/configuration_builder.dart';
import 'package:checked_exceptions/src/util/expression_finder.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

class UnsafeAssignment extends DartLintRule {
  static const _code = LintCode(
    name: 'unsafe_assignment',
    problemMessage: 'This assignment is potentially unsafe',
    errorSeverity: ErrorSeverity.ERROR,
  );

  UnsafeAssignment() : super(code: _code);

  final List<(Expression, Configuration argument, Configuration parameter)>
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
        final parameter = expression.staticParameterElement;
        if (parameter == null) return;

        final parameterConfiguration = await session.configurationBuilder
            .getElementConfiguration(parameter);

        final argumentConfiguration = await session.configurationBuilder
            .getConfiguration(expression);

        this.expressions.add((
          // Report errors on the "actual expression" for named arguments.
          expression is NamedExpression ? expression.expression : expression,
          argumentConfiguration,
          parameterConfiguration,
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
    for (final (expression, argumentConfiguration, parameterConfiguration)
        in expressions) {
      if (!isCompatible(argumentConfiguration, parameterConfiguration)) {
        reporter.atNode(expression, _code);
      }
    }
  }
}

bool isCompatible(Configuration argument, Configuration parameter) {
  if (argument.throws.canThrowUndeclaredErrors &&
      !parameter.throws.canThrowUndeclaredErrors) {
    return false;
  }

  final exceptionType = TypeChecker.fromUrl('dart:core#Exception');

  nextThrownType:
  for (final thrownType in argument.throws.thrownTypes) {
    if (parameter.throws.canThrowUndeclaredErrors &&
        !exceptionType.isAssignableFromType(thrownType)) {
      continue;
    }

    for (final allowedType in parameter.throws.thrownTypes) {
      if (TypeChecker.fromStatic(
        allowedType,
      ).isAssignableFromType(thrownType)) {
        continue nextThrownType;
      }
    }

    return false;
  }

  for (final MapEntry(:key, :value) in parameter.valueConfigurations.entries) {
    if (argument.valueConfigurations[key] case final argumentConfiguration?) {
      if (!isCompatible(argumentConfiguration, value)) {
        return false;
      }
    } else {
      return false;
    }
  }

  return true;
}
