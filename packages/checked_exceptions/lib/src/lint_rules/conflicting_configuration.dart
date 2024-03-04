import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/error/listener.dart';
import 'package:checked_exceptions/src/utils.dart';
import 'package:collection/collection.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

class ConflictingConfiguration extends DartLintRule {
  static const _code = LintCode(
    name: 'conflicting_configuration',
    problemMessage: "{0} and {1} can't both be used on the same element",
    errorSeverity: ErrorSeverity.WARNING,
  );

  ConflictingConfiguration() : super(code: _code);

  final declarations = <Declaration>[];

  @override
  Future<void> startUp(
    CustomLintResolver resolver,
    CustomLintContext context,
  ) async {
    await super.startUp(resolver, context);

    final unit = await resolver.getResolvedUnitResult();

    declarations
      ..clear()
      ..addAll(unit.unit.accept(NodeFinder<Declaration>())!);
  }

  @override
  void run(CustomLintResolver resolver, ErrorReporter reporter, CustomLintContext context) {
    final safeTypeChecker = TypeChecker.fromName(
      'Safe',
      packageName: 'checked_exceptions_annotations',
    );
    final neverThrowsTypeChecker = TypeChecker.fromName(
      'NeverThrows',
      packageName: 'checked_exceptions_annotations',
    );
    final throwsTypeChecker = TypeChecker.fromName(
      'Throws',
      packageName: 'checked_exceptions_annotations',
    );
    final throwsErrorTypeChecker = TypeChecker.fromName(
      'ThrowsError',
      packageName: 'checked_exceptions_annotations',
    );

    final predicates = <(String, bool Function(DartType))>[
      (
        'safe',
        (type) =>
            safeTypeChecker.isAssignableFromType(type) &&
            !neverThrowsTypeChecker.isAssignableFromType(type)
      ),
      ('neverThrows', neverThrowsTypeChecker.isAssignableFromType),
      (
        'ThrowsError',
        (type) =>
            throwsErrorTypeChecker.isAssignableFromType(type) &&
            !throwsTypeChecker.isAssignableFromType(type)
      ),
      ('Throws', throwsTypeChecker.isAssignableFromType),
    ];

    for (final declaration in declarations) {
      final annotations = declaration.metadata
          .map((e) => (e, e.elementAnnotation?.computeConstantValue()?.type))
          .whereType<(Annotation, DartType)>();

      for (final (index, (_, firstAnnotationType)) in annotations.indexed) {
        final firstAnnotationKnownType =
            predicates.firstWhereOrNull((element) => element.$2(firstAnnotationType))?.$1;
        if (firstAnnotationKnownType == null) continue;

        for (final (secondAnnotation, secondAnnotationType) in annotations.skip(index + 1)) {
          final secondAnnotationKnownType =
              predicates.firstWhereOrNull((element) => element.$2(secondAnnotationType))?.$1;
          if (secondAnnotationKnownType == null) continue;

          if (firstAnnotationKnownType != secondAnnotationKnownType) {
            reporter.reportErrorForNode(
              _code,
              secondAnnotation,
              [firstAnnotationKnownType, secondAnnotationKnownType],
            );
          }
        }
      }
    }
  }
}
