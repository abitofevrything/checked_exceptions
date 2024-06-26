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
import 'package:collection/collection.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

/// Provides the means to compute the [Configuration] for an expression.
///
/// The important methods on this class are:
/// - [getExpressionConfiguration], for getting the [Configuration] of an [Expression].
/// - [getElementConfiguration], for getting the [Configuration] of a reference to an [Element].
/// - [computeEquivalentAnnotationConfiguration], for getting the restrictions to apply to a
///   function's body when checking for invalid throws.
class ConfigurationBuilder {
  final _recursionProtectionKey = Object();

  final Expando<({Zone zone, Future<Configuration?> result})>
      _elementConfigurationCache = Expando();

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
  static Future<ConfigurationBuilder> forSession(
    AnalysisSession session, {
    ConfigurationOverrides? overrides,
  }) async {
    final coreLibrary = await session.getResolvedLibrary(
            session.uriConverter.uriToPath(Uri.parse('dart:core'))!)
        as ResolvedLibraryResult;

    return ConfigurationBuilder(
      session,
      objectType: coreLibrary.typeProvider.objectType,
      typeErrorType: (coreLibrary.element.exportNamespace.get('TypeError')
              as InterfaceElement)
          .thisType,
      overrides: overrides ?? await ConfigurationOverrides.forSession(session),
    );
  }

  /// Get the [Configuration] of an [Expression].
  ///
  /// Returns `null` if no configuration could be generated.
  Future<Configuration?> getExpressionConfiguration(Expression node) async {
    return await node
        .accept<Future<Configuration?>>(ExpressionConfigurationVisitor(this))!;
  }

  /// Get the [Configuration] of an [Element]. This is the configuration of any [Identifier] whose
  /// [Identifier.staticElement] is [element].
  ///
  /// Returns `null` if no configuration could be generated.
  ///
  /// This method caches results.
  Future<Configuration?> getElementConfiguration(Element element) async {
    final location = element.location;
    if (location == null) return null;

    final recursionProtectionKey = (location, _recursionProtectionKey);
    if (Zone.current[recursionProtectionKey] != null) {
      // Don't recompute the configuration if we're already computing it.
      return null;
    }

    final cachedComputation = _elementConfigurationCache[location];
    if (cachedComputation != null) {
      // Don't use a computation that is depending on our computation.
      if (cachedComputation.zone[recursionProtectionKey] != null) {
        return null;
      }
      return await cachedComputation.result;
    }

    return await runZoned(
      zoneValues: {recursionProtectionKey: true},
      () => _elementConfigurationCache[location] =
          (zone: Zone.current, result: computeElementConfiguration(element)),
    ).result;
  }

  /// Perform the computation for [getElementConfiguration].
  ///
  /// This method should not be called directly. Instead, call [getElementConfiguration].
  Future<Configuration?> computeElementConfiguration(Element element) async {
    final overriddenConfiguration = overrides.overrides[element.location];
    if (overriddenConfiguration != null) return overriddenConfiguration;

    switch (element) {
      case ExecutableElement():
        final returnTypeConfiguration =
            await computeTypeConfiguration(element.returnType);

        final declaredConfiguration =
            getExecutableElementAnnotationConfiguration(
                element, returnTypeConfiguration);
        if (declaredConfiguration != null) return declaredConfiguration;

        if (element.enclosingElement case InterfaceElement interface) {
          final inheritedConfiguration =
              await getInheritedConfiguration(interface, element);
          if (inheritedConfiguration != null) return inheritedConfiguration;
        }

        return await getExecutableElementThrowsConfiguration(
            element, returnTypeConfiguration);
      case VariableElement():
        final typeConfiguration = element.hasImplicitType
            ? null
            : await computeTypeConfiguration(element.type);
        final initializerConfiguration =
            await getVariableElementInitializerConfiguration(element);

        final declaredConfiguration =
            await getVariableElementAnnotationConfiguration(
          element,
          element.isLate ? initializerConfiguration?.throws : null,
          typeConfiguration ?? initializerConfiguration?.valueConfigurations,
        );
        if (declaredConfiguration != null) return declaredConfiguration;

        if (element.enclosingElement case InterfaceElement interface) {
          final inheritedConfiguration =
              await getInheritedConfiguration(interface, element);
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
    ValueThrows? returnTypeConfiguration,
  ) {
    final annotationConfiguration = getElementAnnotationConfiguration(element);
    if (annotationConfiguration == null) return null;

    return adaptThrowsToExecutableElementType(
      element,
      annotationConfiguration,
      returnTypeConfiguration,
    );
  }

  /// Convert a list of types thrown in the body of an [ExecutableElement] to a [Configuration].
  ///
  /// This is needed because errors thrown by an element's body do not always get thrown when the
  /// element is invoked:
  /// - Getters and setters throw when they are accessed (and they cannot be executed).
  /// - Asynchronous functions throw when their result is awaited (and not when invoked).
  Configuration adaptThrowsToExecutableElementType(
    ExecutableElement element,
    Throws thrownTypes,
    ValueThrows? returnTypeConfiguration,
  ) {
    var configuration = Configuration(
      thrownTypes,
      returnTypeConfiguration ?? {},
    );

    if (element.isAsynchronous) {
      configuration = Configuration(
        (thrownTypes: [], canThrowUndeclaredErrors: false),
        {PromotionType.await_: configuration},
      );
    }

    if (element.kind != ElementKind.SETTER &&
        element.kind != ElementKind.GETTER) {
      configuration = Configuration(
        (thrownTypes: [], canThrowUndeclaredErrors: false),
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
  Future<Throws?> computeEquivalentAnnotationConfiguration(
    Element element, {
    required bool isGetterOrSetter,
    required bool isAsynchronous,
  }) async {
    var configuration = await getElementConfiguration(element);
    if (configuration == null) return null;

    if (!isGetterOrSetter) {
      configuration = configuration.valueConfigurations[PromotionType.invoke];
      if (configuration == null) return null;
    }

    if (isAsynchronous) {
      configuration = configuration.valueConfigurations[PromotionType.await_];
      if (configuration == null) return null;
    }

    return configuration.throws;
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

    Set<InterfaceElement> getDirectSupertypeElements(
            InterfaceElement interfaceElement) =>
        {
          if (interfaceElement.supertype case final supertype?)
            supertype.element,
          for (final interface in interfaceElement.interfaces)
            interface.element,
          for (final mixin in interfaceElement.mixins) mixin.element,
          if (interfaceElement is MixinElement)
            for (final constraint in interfaceElement.superclassConstraints)
              constraint.element,
        };

    final elementsToVisit = getDirectSupertypeElements(interfaceElement);
    final visitedElements = <InterfaceElement>{};

    while (elementsToVisit.isNotEmpty) {
      final superclassElement = elementsToVisit.first;
      elementsToVisit.remove(superclassElement);
      visitedElements.add(superclassElement);

      if ((element.isPrivate && element.library != superclassElement.library) ||
          (element is ClassMemberElement && element.isStatic) ||
          element is ConstructorElement) {
        continue;
      }

      var foundMatching = false;

      for (final superclassElement in superclassElement.children) {
        if (element.name == superclassElement.name &&
            (superclassElement is ClassMemberElement &&
                !superclassElement.isStatic) &&
            superclassElement is! ConstructorElement) {
          foundMatching = true;
          inheritedConfigurationFutures
              .add(getElementConfiguration(superclassElement));
          break;
        }
      }

      if (!foundMatching) {
        final nextToVisit = getDirectSupertypeElements(superclassElement);
        elementsToVisit.addAll(
            nextToVisit.where((element) => !visitedElements.contains(element)));
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
    ValueThrows? returnTypeConfiguration,
  ) async {
    final parsedLibrary =
        await session.getResolvedLibraryByElement(element.library);
    if (parsedLibrary is! ResolvedLibraryResult) {
      print(
          '[BUILDER] Got invalid library result ${parsedLibrary.runtimeType}');
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

    final bodyThrows = await body.accept(ThrowFinder(this))!;

    return adaptThrowsToExecutableElementType(
      element,
      bodyThrows.isEmpty
          ? (thrownTypes: [], canThrowUndeclaredErrors: false)
          : Configuration.unionConfigurations([
              for (final throws in bodyThrows.values) Configuration(throws, {}),
            ])!
              .throws,
      returnTypeConfiguration,
    );
  }

  /// Return the configuration of [element]'s initializer, or `null` if [element] has no
  /// initializer.
  Future<Configuration?> getVariableElementInitializerConfiguration(
      VariableElement element) async {
    final library = element.library;
    if (library == null) {
      print('[BUILDER] Got element with null library');
      return null;
    }

    final parsedLibrary = await session.getResolvedLibraryByElement(library);
    if (parsedLibrary is! ResolvedLibraryResult) {
      print(
          '[BUILDER] Got invalid library result ${parsedLibrary.runtimeType}');
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
      print(
          '[BUILDER] Unable to get initializer of ${declarationNode.runtimeType}');
      return null;
    }

    if (initializer == null) return null;

    return await getExpressionConfiguration(initializer);
  }

  Future<Configuration?> getVariableElementAnnotationConfiguration(
    VariableElement element,
    Throws? accessThrows,
    ValueThrows? existingConfiguration,
  ) async {
    final annotationConfiguration = getElementAnnotationConfiguration(element);
    if (annotationConfiguration == null) return null;

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
          annotationConfiguration,
          existingConfiguration?[PromotionType.await_]?.valueConfigurations ??
              {},
        ),
      };
    } else if (isCallable && !isFuture) {
      valueConfigurations = {
        PromotionType.invoke: Configuration(
          annotationConfiguration,
          existingConfiguration?[PromotionType.invoke]?.valueConfigurations ??
              {},
        ),
      };
    } else {
      // Ambiguous annotation or non-applicable.
      return null;
    }

    return Configuration(
      accessThrows ?? (thrownTypes: [], canThrowUndeclaredErrors: false),
      valueConfigurations,
    );
  }

  /// Returns the configuration information provided by annotations on [element], or `null` if
  /// [element] has no annotations.
  Throws? getElementAnnotationConfiguration(
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
        if (neverThrowsTypeChecker.isAssignableFromType(type))
          canThrowUndeclaredErrors = false;
      } else if (throwsErrorTypeChecker.isAssignableFromType(type)) {
        hasFoundConfiguration = true;

        final throwsErrorInstanciation = [type, ...type.allSupertypes]
            .firstWhere(throwsErrorTypeChecker.isExactlyType);
        thrownTypes.add(throwsErrorInstanciation.typeArguments.single);

        if (throwsTypeChecker.isAssignableFromType(type))
          canThrowUndeclaredErrors = false;
      }
    }

    if (!hasFoundConfiguration) return null;
    return (
      thrownTypes: thrownTypes,
      canThrowUndeclaredErrors: canThrowUndeclaredErrors
    );
  }

  /// Compute the configuration information provided by a type to any expression of that type.
  Future<ValueThrows?> computeTypeConfiguration(
    DartType type,
  ) async {
    switch (type) {
      case FunctionType():
        Throws? throws;
        final returnTypeConfiguration =
            await computeTypeConfiguration(type.returnType);

        if (type.alias?.element case final aliasElement?) {
          final declaredConfiguration =
              getElementAnnotationConfiguration(aliasElement);
          if (declaredConfiguration != null) {
            throws = declaredConfiguration;
          } else {
            return await computeTypeConfiguration(aliasElement.aliasedType);
          }
        }

        if (throws == null && returnTypeConfiguration == null) return null;

        return {
          PromotionType.invoke: Configuration(
            throws ?? (thrownTypes: [], canThrowUndeclaredErrors: false),
            returnTypeConfiguration ?? {},
          ),
        };
      case InterfaceType():
        final futureInstanciation = [type, ...type.allSupertypes]
            .firstWhereOrNull(futureTypeChecker.isExactlyType);
        final callMethod = type.element.children.singleWhereOrNull((element) =>
            element is MethodElement &&
            element.name == FunctionElement.CALL_METHOD_NAME);

        if (futureInstanciation == null && callMethod == null) return null;

        final declaredConfiguration = switch (type.alias?.element) {
          // Declared configuration would be ambiguous in this case.
          _ when callMethod != null && futureInstanciation != null => null,
          final aliasElement? =>
            getElementAnnotationConfiguration(aliasElement),
          _ => null,
        };
        return {
          if (futureInstanciation != null)
            PromotionType.await_: Configuration(
              declaredConfiguration ??
                  (thrownTypes: [], canThrowUndeclaredErrors: false),
              await computeTypeConfiguration(
                      futureInstanciation.typeArguments.single) ??
                  {},
            ),
          if (callMethod != null)
            PromotionType.invoke: Configuration(
              declaredConfiguration ??
                  (thrownTypes: [], canThrowUndeclaredErrors: false),
              (await getElementConfiguration(callMethod))
                      ?.valueConfigurations ??
                  {},
            ),
        };
      case VoidType():
        return null;
      case TypeParameterType():
        return null; // TODO
      default:
        print('[BUILDER] Unhandled type ${type.runtimeType}');
        return null;
    }
  }
}
