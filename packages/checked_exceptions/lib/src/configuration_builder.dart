import 'dart:async';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart' hide Configuration;
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:checked_exceptions/src/configuration.dart';
import 'package:checked_exceptions/src/configuration_overrides.dart';
import 'package:checked_exceptions/src/expression_configuration_visitor.dart';
import 'package:checked_exceptions/src/throw_finder.dart';
import 'package:checked_exceptions_annotations/checked_exceptions_annotations.dart';
import 'package:collection/collection.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

/// The subset of a [Configuration] that the type of an expression can represent.
///
/// This corresponds to [Configuration.valueConfigurations]. Given a type, we can deduce
/// information about the value of an expression with that type, but not information about the
/// expression itself.
typedef TypeConfiguration = Map<PromotionType, Configuration>;

/// The information provided by a combination [safe], [neverThrows], [Throws] and [ThrowsError]
/// annotations on an element.
typedef AnnotationConfiguration = ({List<DartType> thrownTypes, bool canThrowUndeclaredErrors});

/// Provides the means to compute the [Configuration] for an expression.
///
/// The important methods on this class are:
/// - [getExpressionConfiguration], for getting the [Configuration] of an [Expression].
/// - [getElementConfiguration], for getting the [Configuration] of a reference to an [Element].
/// - [computeEquivalentAnnotationConfiguration], for getting the restrictions to apply to a
///   function's body when checking for invalid throws.
class ConfigurationBuilder {
  final _recursionProtectionKey = Object();

  final Expando<Future<Configuration?>> _expressionConfigurationCache = Expando();
  final Expando<Future<Configuration?>> _elementConfigurationCache = Expando();

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

  final futureTypeChecker = TypeChecker.fromUrl('dart:async#Future');

  /// The session this [ConfigurationBuilder] is bound to.
  final AnalysisSession session;

  final DartType objectType;
  final DartType typeErrorType;

  final ConfigurationOverrides overrides;

  ConfigurationBuilder(
    this.session, {
    required this.objectType,
    required this.typeErrorType,
    required this.overrides,
  });

  /// Create a [ConfigurationBuilder] for [session].
  static Future<ConfigurationBuilder> forSession(AnalysisSession session) async {
    final coreLibrary =
        await session.getResolvedLibrary(session.uriConverter.uriToPath(Uri.parse('dart:core'))!)
            as ResolvedLibraryResult;

    return ConfigurationBuilder(
      session,
      objectType: coreLibrary.typeProvider.objectType,
      typeErrorType:
          (coreLibrary.element.exportNamespace.get('TypeError') as InterfaceElement).thisType,
      overrides: await ConfigurationOverrides.forSession(session),
    );
  }

  /// Get the [Configuration] of an [Expression].
  ///
  /// Returns `null` if no configuration could be generated.
  ///
  /// This method caches results.
  Future<Configuration?> getExpressionConfiguration(Expression node) async {
    final cachedValue = _expressionConfigurationCache[node];
    if (cachedValue != null) return await cachedValue;

    return await (_expressionConfigurationCache[node] =
        node.accept(ExpressionConfigurationVisitor(this))!);
  }

  /// Get the [Configuration] of an [Element]. This is the configuration of any [Identifier] whose
  /// [Identifier.staticElement] is [element].
  ///
  /// Returns `null` if no configuration could be generated.
  ///
  /// This method caches results.
  Future<Configuration?> getElementConfiguration(Element element) async {
    final recursionProtectionKey = (element, _recursionProtectionKey);
    if (Zone.current[recursionProtectionKey] != null) {
      return null;
    }

    final cachedValue = _elementConfigurationCache[element];
    if (cachedValue != null) return await cachedValue;

    return await runZoned(
      zoneValues: {recursionProtectionKey: true},
      () => _elementConfigurationCache[element] = computeElementConfiguration(element),
    );
  }

  /// Perform the computation for [getElementConfiguration].
  ///
  /// This method should not be called directly. Instead, call [getElementConfiguration].
  Future<Configuration?> computeElementConfiguration(Element element) async {
    final overriddenConfiguration = overrides.overrides[element.location];
    if (overriddenConfiguration != null) return overriddenConfiguration;

    switch (element) {
      case ExecutableElement():
        final returnTypeConfiguration = await computeTypeConfiguration(element.returnType);

        final declaredConfiguration =
            getExecutableElementAnnotationConfiguration(element, returnTypeConfiguration);
        if (declaredConfiguration != null) return declaredConfiguration;

        if (element.enclosingElement case InterfaceElement interface) {
          final inheritedConfiguration = await getInheritedConfiguration(interface, element);
          if (inheritedConfiguration != null) return inheritedConfiguration;
        }

        return await getExecutableElementThrowsConfiguration(element, returnTypeConfiguration);
      case VariableElement():
        final typeConfiguration =
            element.hasImplicitType ? null : await computeTypeConfiguration(element.type);
        final initializerConfiguration = await getVariableElementInitializerConfiguration(element);

        final declaredConfiguration = await getVariableElementAnnotationConfiguration(
          element,
          element.isLate ? initializerConfiguration?.thrownTypes : null,
          typeConfiguration ?? initializerConfiguration?.valueConfigurations,
        );
        if (declaredConfiguration != null) return declaredConfiguration;

        if (element.enclosingElement case InterfaceElement interface) {
          final inheritedConfiguration = await getInheritedConfiguration(interface, element);
          if (inheritedConfiguration != null) return inheritedConfiguration;
        }

        return initializerConfiguration;
      default:
        print('[BUILDER] Unhandled element type ${element.runtimeType}');
        return null;
    }
  }

  /// Get the [Configuration] for an [ExecutableElement] based solely on annotations on the element.
  Configuration? getExecutableElementAnnotationConfiguration(
    ExecutableElement element,
    TypeConfiguration? returnTypeConfiguration,
  ) {
    final annotationConfiguration = getElementAnnotationConfiguration(element);
    if (annotationConfiguration == null) return null;

    final thrownTypes = [
      ...annotationConfiguration.thrownTypes,
      if (annotationConfiguration.canThrowUndeclaredErrors) objectType,
    ];

    return adaptThrowsToExecutableElementType(element, thrownTypes, returnTypeConfiguration);
  }

  /// Convert a list of types thrown in the body of an [ExecutableElement] to a [Configuration].
  ///
  /// This is needed because errors thrown by an element's body do not always get thrown when the
  /// element is invoked:
  /// - Getters and setters throw when they are accessed (and they cannot be executed).
  /// - Asynchronous functions throw when their result is awaited (and not when invoked).
  Configuration adaptThrowsToExecutableElementType(
    ExecutableElement element,
    List<DartType> thrownTypes,
    TypeConfiguration? returnTypeConfiguration,
  ) {
    var configuration = Configuration(
      thrownTypes,
      returnTypeConfiguration ?? {},
    );

    if (element.isAsynchronous) {
      configuration = Configuration(
        [],
        {PromotionType.await_: configuration},
      );
    }

    if (element.kind != ElementKind.SETTER && element.kind != ElementKind.GETTER) {
      configuration = Configuration(
        [],
        {PromotionType.invoke: configuration},
      );
    }

    return configuration;
  }

  /// Given an [element], compute the restrictions that apply to its body based on its
  /// configuration.
  ///
  /// This method essentially computes which annotations would have to be applied to the element to
  /// reproduce the restrictions applied by its configuration, which might not be created from
  /// annotations on the element.
  ///
  /// It is in spirit opposite to [adaptThrowsToExecutableElementType].
  ///
  /// If the element has annotations, this method returns the same a
  /// [getElementAnnotationConfiguration].
  Future<AnnotationConfiguration?> computeEquivalentAnnotationConfiguration(
    ExecutableElement element,
  ) async {
    final annotatedConfiguration = getElementAnnotationConfiguration(element);
    if (annotatedConfiguration != null) return annotatedConfiguration;

    var configuration = await getElementConfiguration(element);
    if (configuration == null) return null;

    if (element.kind != ElementKind.GETTER && element.kind != ElementKind.SETTER) {
      configuration = configuration.valueConfigurations[PromotionType.invoke];
      if (configuration == null) return null;
    }

    if (element.isAsynchronous) {
      configuration = configuration.valueConfigurations[PromotionType.await_];
      if (configuration == null) return null;
    }

    return (
      canThrowUndeclaredErrors: false,
      thrownTypes: configuration.thrownTypes,
    );
  }

  /// Compute the configuration for [element] based solely on the class members it overrides.
  ///
  /// [interfaceElement] must be the interface element that contains [element].
  Future<Configuration?> getInheritedConfiguration(
    InterfaceElement interfaceElement,
    Element element,
  ) async {
    assert(element.enclosingElement == interfaceElement);

    final inheritedConfigurationFutures = <Future<Configuration?>>[];

    Set<InterfaceElement> getDirectSupertypeElements(InterfaceElement interfaceElement) => {
          if (interfaceElement.supertype case final supertype?) supertype.element,
          for (final interface in interfaceElement.interfaces) interface.element,
          for (final mixin in interfaceElement.mixins) mixin.element,
          if (interfaceElement is MixinElement)
            for (final constraint in interfaceElement.superclassConstraints) constraint.element,
        };

    final elementsToVisit = getDirectSupertypeElements(interfaceElement);
    final visitedElements = <InterfaceElement>{};

    while (elementsToVisit.isNotEmpty) {
      final superclassElement = elementsToVisit.first;
      elementsToVisit.remove(superclassElement);
      visitedElements.add(superclassElement);

      if (element.isPrivate && element.library != superclassElement.library) continue;

      var foundMatching = false;

      for (final superclassElement in superclassElement.children) {
        if (element.name == superclassElement.name) {
          foundMatching = true;
          inheritedConfigurationFutures.add(getElementConfiguration(superclassElement));
          break;
        }
      }

      if (!foundMatching) {
        final nextToVisit = getDirectSupertypeElements(superclassElement);
        elementsToVisit.addAll(nextToVisit.where((element) => !visitedElements.contains(element)));
      }
    }

    final inheritedConfigurations =
        (await Future.wait(inheritedConfigurationFutures)).nonNulls.toList();

    return Configuration.intersectConfigurations(inheritedConfigurations);
  }

  /// Compute the configuration for an [ExecutableElement] based solely on inference from the types
  /// thrown in its body.
  Future<Configuration?> getExecutableElementThrowsConfiguration(
    ExecutableElement element,
    TypeConfiguration? returnTypeConfiguration,
  ) async {
    final parsedLibrary = await session.getResolvedLibraryByElement(element.library);
    if (parsedLibrary is! ResolvedLibraryResult) {
      print('[BUILDER] Got invalid library result ${parsedLibrary.runtimeType}');
      return null;
    }

    final elementDeclaration = parsedLibrary.getElementDeclaration(element);
    if (elementDeclaration == null) {
      print('[BUILDER] Unable to get declaration for ${element.runtimeType}');
      return null;
    }
    final declarationNode = elementDeclaration.node;

    final body = switch (declarationNode) {
      MethodDeclaration() => declarationNode.body,
      FunctionDeclaration() => declarationNode.functionExpression.body,
      // TODO: Constructors also invoke super constructors and field initializers.
      ConstructorDeclaration() => declarationNode.body,
      _ => null,
    };
    if (body == null) {
      print('[BUILDER] Unable to get body of ${declarationNode.runtimeType}');
      return null;
    }

    final throws = await body.accept(ThrowFinder(this))!;
    final thrownTypes = <DartType>{};

    for (final thrownType in throws.values.expand((element) => element)) {
      if (thrownTypes.any(
        (alreadyThrownType) =>
            TypeChecker.fromStatic(alreadyThrownType).isAssignableFromType(thrownType),
      )) {
        continue;
      }

      thrownTypes.removeWhere(
        (alreadyThrownType) =>
            TypeChecker.fromStatic(thrownType).isAssignableFromType(alreadyThrownType),
      );

      thrownTypes.add(thrownType);
    }

    return adaptThrowsToExecutableElementType(
      element,
      List.of(thrownTypes),
      returnTypeConfiguration,
    );
  }

  /// Return the configuration of [element]'s initializer, or `null` if [element] has no
  /// initializer.
  Future<Configuration?> getVariableElementInitializerConfiguration(VariableElement element) async {
    final library = element.library;
    if (library == null) {
      print('[BUILDER] Got element with null library');
      return null;
    }

    final parsedLibrary = await session.getResolvedLibraryByElement(library);
    if (parsedLibrary is! ResolvedLibraryResult) {
      print('[BUILDER] Got invalid library result ${parsedLibrary.runtimeType}');
      return null;
    }

    final elementDeclaration = parsedLibrary.getElementDeclaration(element);
    if (elementDeclaration == null) {
      print('[BUILDER] Unable to get declaration for ${element.runtimeType}');
      return null;
    }
    final declarationNode = elementDeclaration.node;

    final initializer = switch (declarationNode) {
      VariableDeclaration() => declarationNode.initializer,
      DefaultFormalParameter() => declarationNode.defaultValue,
      NormalFormalParameter() => null,
      _ => 0, // Not an Expression
    };
    if (initializer is! Expression?) {
      print('[BUILDER] Unable to get initializer of ${declarationNode.runtimeType}');
      return null;
    }

    if (initializer == null) return null;

    return await getExpressionConfiguration(initializer);
  }

  Future<Configuration?> getVariableElementAnnotationConfiguration(
    VariableElement element,
    List<DartType>? accessThrows,
    TypeConfiguration? existingConfiguration,
  ) async {
    final annotationConfiguration = getElementAnnotationConfiguration(element);
    if (annotationConfiguration == null) return null;

    final thrownTypes = [
      ...annotationConfiguration.thrownTypes,
      if (annotationConfiguration.canThrowUndeclaredErrors) objectType,
    ];

    final isFuture = futureTypeChecker.isAssignableFromType(element.type);
    final isCallable = switch (element.type) {
      InterfaceType(:final element) => element.children.any(
          (element) =>
              element is MethodElement &&
              !element.isStatic &&
              element.name == FunctionElement.CALL_METHOD_NAME,
        ),
      FunctionType() => true,
      _ => false,
    };

    var valueConfigurations = existingConfiguration;
    if (isFuture && !isCallable) {
      valueConfigurations = {
        PromotionType.await_: Configuration(
          thrownTypes,
          existingConfiguration?[PromotionType.await_]?.valueConfigurations ?? {},
        ),
      };
    } else if (isCallable && !isFuture) {
      valueConfigurations = {
        PromotionType.invoke: Configuration(
          thrownTypes,
          existingConfiguration?[PromotionType.invoke]?.valueConfigurations ?? {},
        ),
      };
    } else {
      // Ambiguous annotation or non-applicable.
      return null;
    }

    return Configuration(
      accessThrows ?? [],
      valueConfigurations,
    );
  }

  /// Returns the configuration information provided by annotations on [element], or `null` if
  /// [element] has no annotations.
  AnnotationConfiguration? getElementAnnotationConfiguration(
    Element element,
  ) {
    final thrownTypes = <DartType>[];
    var canThrowUndeclaredErrors = true;
    var hasFoundConfiguration = false;

    for (final annotation in element.metadata) {
      final type = annotation.computeConstantValue()?.type;
      if (type is! InterfaceType) continue;

      if (safeTypeChecker.isAssignableFromType(type)) {
        hasFoundConfiguration = true;
        if (neverThrowsTypeChecker.isAssignableFromType(type)) canThrowUndeclaredErrors = false;
      } else if (throwsErrorTypeChecker.isAssignableFromType(type)) {
        hasFoundConfiguration = true;

        final throwsErrorInstanciation =
            [type, ...type.allSupertypes].firstWhere(throwsErrorTypeChecker.isExactlyType);
        thrownTypes.add(throwsErrorInstanciation.typeArguments.single);

        if (throwsTypeChecker.isAssignableFromType(type)) canThrowUndeclaredErrors = false;
      }
    }

    if (!hasFoundConfiguration) return null;
    return (thrownTypes: thrownTypes, canThrowUndeclaredErrors: canThrowUndeclaredErrors);
  }

  /// Compute the configuration information provided by a type to any expression of that type.
  Future<TypeConfiguration?> computeTypeConfiguration(
    DartType type,
  ) async {
    switch (type) {
      case FunctionType():
        List<DartType>? thrownTypes;
        final returnTypeConfiguration = await computeTypeConfiguration(type.returnType);

        if (type.alias?.element case final aliasElement?) {
          final declaredConfiguration = getElementAnnotationConfiguration(aliasElement);
          if (declaredConfiguration != null) {
            thrownTypes = [
              ...declaredConfiguration.thrownTypes,
              if (declaredConfiguration.canThrowUndeclaredErrors) objectType,
            ];
          } else {
            return await computeTypeConfiguration(aliasElement.aliasedType);
          }
        }

        if (thrownTypes == null && returnTypeConfiguration == null) return null;

        return {
          PromotionType.invoke: Configuration(
            thrownTypes ?? [],
            returnTypeConfiguration ?? {},
          ),
        };
      case InterfaceType():
        final futureInstanciation =
            [type, ...type.allSupertypes].firstWhereOrNull(futureTypeChecker.isExactlyType);
        final callMethod = type.element.children.singleWhereOrNull((element) =>
            element is MethodElement && element.name == FunctionElement.CALL_METHOD_NAME);

        if (futureInstanciation == null && callMethod == null) return null;

        final declaredConfiguration = switch (type.alias?.element) {
          // Declared configuration would be ambiguous in this case.
          _ when callMethod != null && futureInstanciation != null => null,
          final aliasElement? => getElementAnnotationConfiguration(aliasElement),
          _ => null,
        };
        final declaredThrownTypes = switch (declaredConfiguration) {
          final configuration? => [
              ...configuration.thrownTypes,
              if (configuration.canThrowUndeclaredErrors) objectType,
            ],
          _ => null,
        };

        return {
          if (futureInstanciation != null)
            PromotionType.await_: Configuration(
              declaredThrownTypes ?? [],
              await computeTypeConfiguration(futureInstanciation.typeArguments.single) ?? {},
            ),
          if (callMethod != null)
            PromotionType.invoke: Configuration(
              declaredThrownTypes ?? [],
              (await getElementConfiguration(callMethod))?.valueConfigurations ?? {},
            ),
        };
      default:
        print('[BUILDER] Unhandled type ${type.runtimeType}');
        return null;
    }
  }
}
