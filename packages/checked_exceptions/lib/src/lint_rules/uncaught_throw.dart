import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/error/listener.dart';
import 'package:checked_exceptions/src/configuration_builder.dart';
import 'package:checked_exceptions/src/throw_finder.dart';
import 'package:checked_exceptions/src/utils.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

/// Reports an error when evaluating some code would result in an error being thrown that is not
/// allowed by the configuration of the function the code appears in.
class UncaughtThrow extends DartLintRule {
  static const _code = LintCode(
    name: 'uncaught_throw',
    problemMessage: "{0} can't be thrown here.",
    errorSeverity: ErrorSeverity.ERROR,
  );

  UncaughtThrow() : super(code: _code);

  final computedConfigurations =
      <Element, (AnnotationConfiguration, Map<AstNode, List<DartType>>)>{};

  @override
  Future<void> startUp(
    CustomLintResolver resolver,
    CustomLintContext context,
  ) async {
    await super.startUp(resolver, context);

    var unit = await resolver.getResolvedUnitResult();
    final builder = await unit.session.configurationBuilder;

    final functions = unit.unit.accept(ElementFinder<ExecutableElement>())!;

    await Future.wait(functions.map((function) async {
      final body = switch (function) {
        MethodDeclaration() => function.body,
        FunctionDeclaration() => function.functionExpression.body,
        _ => null,
      };
      if (body == null) {
        print('[UNCAUGHT_THROW] Unable to get body of ${function.runtimeType}');
        return;
      }

      final configuration = await builder
          .computeEquivalentAnnotationConfiguration(function.declaredElement as ExecutableElement);
      if (configuration == null) return null;

      computedConfigurations[function.declaredElement!] =
          (configuration, await body.accept(ThrowFinder(builder))!);
    }));
  }

  @override
  void run(CustomLintResolver resolver, ErrorReporter reporter, CustomLintContext context) {
    final exceptionTypeChecker = TypeChecker.fromUrl('dart:core#Exception');

    for (final (configuration, throwingNodes) in computedConfigurations.values) {
      for (final MapEntry(key: location, value: thrownTypes) in throwingNodes.entries) {
        nextType:
        for (final thrownType in thrownTypes) {
          if (!exceptionTypeChecker.isAssignableFromType(thrownType) &&
              configuration.canThrowUndeclaredErrors) {
            continue;
          }

          for (final allowedType in configuration.thrownTypes) {
            if (TypeChecker.fromStatic(allowedType).isAssignableFromType(thrownType)) {
              continue nextType;
            }
          }

          reporter.reportErrorForNode(
            _code,
            location,
            [thrownType.getDisplayString(withNullability: true)],
          );
        }
      }
    }
  }
}
