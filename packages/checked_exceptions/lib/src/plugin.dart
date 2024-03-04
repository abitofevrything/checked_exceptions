import 'package:checked_exceptions/src/lint_rules/uncaught_throw.dart';
import 'package:checked_exceptions/src/lint_rules/unsafe_assignment.dart';
import 'package:checked_exceptions/src/lint_rules/unsafe_override.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

class CheckedExceptionsPlugin extends PluginBase {
  @override
  List<LintRule> getLintRules(CustomLintConfigs configs) => [
        UncaughtThrow(),
        UnsafeAssignment(),
        UnsafeOverride(),
      ];
}
