import 'package:checked_exceptions/src/lint_rules/uncaught_throw.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

class CheckedExceptionsPlugin extends PluginBase {
  @override
  List<LintRule> getLintRules(CustomLintConfigs configs) => [UncaughtThrow()];
}
