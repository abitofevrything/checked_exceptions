import 'package:analyzer/dart/ast/ast.dart' hide Configuration;
import 'package:analyzer/error/error.dart';
import 'package:analyzer/error/listener.dart';
import 'package:checked_exceptions/src/configuration.dart';
import 'package:checked_exceptions/src/utils.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

class UnsafeAssignment extends DartLintRule {
  static const _code = LintCode(
    name: 'unsafe_assignment',
    problemMessage: "This expression can't be used here because its configuration is incompatible",
    errorSeverity: ErrorSeverity.ERROR,
  );

  final computedAssignments =
      <Expression, ({Configuration parameterConfiguration, Configuration argumentConfiguration})>{};

  UnsafeAssignment() : super(code: _code);

  @override
  Future<void> startUp(
    CustomLintResolver resolver,
    CustomLintContext context,
  ) async {
    await super.startUp(resolver, context);

    final unit = await resolver.getResolvedUnitResult();
    final builder = await unit.session.configurationBuilder;

    computedAssignments.clear();

    final arguments =
        unit.unit.accept(NodeFinder<Expression>((e) => e.staticParameterElement != null))!;
    final assignments = unit.unit.accept(
        NodeFinder<AssignmentExpression>((e) => e.rightHandSide.staticParameterElement == null))!;
    final variableDeclarations = unit.unit.accept(NodeFinder<VariableDeclaration>(
        (d) => d.initializer != null && d.declaredElement != null))!;

    await Future.wait(arguments.map((argument) async {
      final parameterConfiguration =
          await builder.getElementConfiguration(argument.staticParameterElement!);
      if (parameterConfiguration == null) return;

      final argumentConfiguration = await builder.getExpressionConfiguration(argument);
      if (argumentConfiguration == null) return;

      computedAssignments[argument] = (
        parameterConfiguration: parameterConfiguration,
        argumentConfiguration: argumentConfiguration,
      );
    }));

    await Future.wait(assignments.map((assignment) async {
      final targetConfiguration = await builder.getExpressionConfiguration(assignment.leftHandSide);
      if (targetConfiguration == null) return;

      final expressionConfiguration =
          await builder.getExpressionConfiguration(assignment.rightHandSide);
      if (expressionConfiguration == null) return;

      computedAssignments[assignment.rightHandSide] = (
        parameterConfiguration: targetConfiguration,
        argumentConfiguration: expressionConfiguration,
      );
    }));

    await Future.wait(variableDeclarations.map((declaration) async {
      final variableConfiguration =
          await builder.getElementConfiguration(declaration.declaredElement!);
      if (variableConfiguration == null) return;

      final expressionConfiguration =
          await builder.getExpressionConfiguration(declaration.initializer!);
      if (expressionConfiguration == null) return;

      computedAssignments[declaration.initializer!] = (
        parameterConfiguration: variableConfiguration,
        argumentConfiguration: expressionConfiguration,
      );
    }));
  }

  @override
  void run(CustomLintResolver resolver, ErrorReporter reporter, CustomLintContext context) {
    for (final MapEntry(key: argument, value: (:parameterConfiguration, :argumentConfiguration))
        in computedAssignments.entries) {
      // Skip one level because we don't care about what evaluating the expression throws, only what
      // its value throws - since only the value is passed to the parameter.
      if (!argumentConfiguration.isCompatibleWith(parameterConfiguration, atLevel: 1)) {
        reporter.reportErrorForNode(
          _code,
          argument,
        );
      }
    }
  }
}
