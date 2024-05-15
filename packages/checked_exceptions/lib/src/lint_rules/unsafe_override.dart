import 'package:analyzer/dart/ast/ast.dart' hide Configuration;
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/error/listener.dart';
import 'package:checked_exceptions/src/configuration.dart';
import 'package:checked_exceptions/src/utils.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

class UnsafeOverride extends DartLintRule {
  static const _code = LintCode(
    name: 'unsafe_override',
    problemMessage:
        "This override's configuration isn't compatible with the overridden configuration",
    errorSeverity: ErrorSeverity.ERROR,
  );

  UnsafeOverride() : super(code: _code);

  final computedConfigurations =
      <Element, ({Configuration current, Configuration overridden})>{};

  @override
  Future<void> startUp(
    CustomLintResolver resolver,
    CustomLintContext context,
  ) async {
    await super.startUp(resolver, context);

    final unit = await resolver.getResolvedUnitResult();
    final builder = await unit.session.configurationBuilder;

    computedConfigurations.clear();

    final classMembers = unit.unit.accept(NodeFinder<Declaration>(
      (d) =>
          (d is MethodDeclaration && !d.isStatic) ||
          (d is FieldDeclaration && !d.isStatic),
    ))!;

    await Future.wait(classMembers.map((declaration) async {
      final member = declaration.declaredElement;
      if (member == null) return;

      final interface = member.enclosingElement;
      if (interface is! InterfaceElement) return;

      final inheritedConfiguration = await builder.getInheritedConfiguration(
        interface,
        member,
      );
      if (inheritedConfiguration == null) return;

      final memberConfiguration = await builder.getElementConfiguration(member);
      if (memberConfiguration == null) return;

      computedConfigurations[member] = (
        current: memberConfiguration,
        overridden: inheritedConfiguration,
      );
    }));
  }

  @override
  void run(CustomLintResolver resolver, ErrorReporter reporter,
      CustomLintContext context) {
    for (final MapEntry(key: element, value: (:current, :overridden))
        in computedConfigurations.entries) {
      if (!current.isCompatibleWith(overridden)) {
        reporter.reportErrorForElement(_code, element);
      }
    }
  }
}
