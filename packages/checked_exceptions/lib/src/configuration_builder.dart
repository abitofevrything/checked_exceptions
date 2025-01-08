import 'dart:async';
import 'dart:collection';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart' hide Configuration;
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_system.dart';
import 'package:checked_exceptions/src/configuration.dart';
import 'package:collection/collection.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

extension SharedConfigurationBuilder on AnalysisSession {
  static final Expando<ConfigurationBuilder> _builders = Expando();

  ConfigurationBuilder get configurationBuilder =>
      _builders[this] ??= ConfigurationBuilder(this);
}

class ConfigurationBuilder {
  final ConfigurationResolver _resolver;
  Future<void> _resolverLock = Future.value();

  ConfigurationBuilder(AnalysisSession session)
    : _resolver = ConfigurationResolver(session);

  Future<Configuration> getConfiguration(AstNode node) async {
    Future<void> lock;
    do {
      lock = _resolverLock;
      await lock;
    } while (lock != _resolverLock);

    final result = _resolver.resolveConfiguration(node);
    _resolverLock = result;
    return await result;
  }

  Future<Configuration> getElementConfiguration(Element element) async {
    Future<void> lock;
    do {
      lock = _resolverLock;
      await lock;
    } while (lock != _resolverLock);

    final result = _resolver.resolveElementConfiguration(element);
    _resolverLock = result;
    return await result;
  }
}

class ConfigurationResolver {
  static const dependentKey = #_dependent;
  static const implicitDependent = #_noDependent;

  final AnalysisSession session;

  final Future<LibraryElement> coreLibrary;

  Future<DartType> get objectType =>
      coreLibrary.then((l) => l.getClass('Object')!.thisType);

  Future<DartType> get exceptionType =>
      coreLibrary.then((l) => l.getClass('Exception')!.thisType);

  Future<DartType> get typeErrorType =>
      coreLibrary.then((l) => l.getClass('TypeError')!.thisType);

  Future<DartType> get stateErrorType =>
      coreLibrary.then((l) => l.getClass('StateError')!.thisType);

  Future<DartType> get noSuchMethodErrorType =>
      coreLibrary.then((l) => l.getClass('NoSuchMethodError')!.thisType);

  Future<TypeSystem> get typeSystem => coreLibrary.then((l) => l.typeSystem);

  late final ConfigurationGenerator generator = ConfigurationGenerator(this);

  static bool _astNodeEquals(AstNode a, AstNode b) {
    if (a.offset != b.offset ||
        a.length != b.length ||
        a.runtimeType != b.runtimeType) {
      return false;
    }

    final aUnit = a.thisOrAncestorOfType<CompilationUnit>()?.declaredElement;
    final bUnit = a.thisOrAncestorOfType<CompilationUnit>()?.declaredElement;

    return aUnit == bUnit;
  }

  // Intentionally don't hash the node's compilation unit since accessing it is
  // O(n) and this method should be fast. We can afford a few hash collisions.
  static int _astNodeHash(AstNode node) =>
      Object.hash(node.offset, node.length, node.runtimeType);

  final Map<AstNode, Configuration> configurations = LinkedHashMap(
    equals: _astNodeEquals,
    hashCode: _astNodeHash,
  );

  final LinkedHashMap<AstNode, LinkedHashSet<AstNode>> dependents =
      LinkedHashMap(equals: _astNodeEquals, hashCode: _astNodeHash);

  LinkedHashSet<AstNode> needsRecomputing = LinkedHashSet(
    equals: _astNodeEquals,
    hashCode: _astNodeHash,
  );

  ConfigurationResolver(this.session)
    : coreLibrary = Future(() async {
        final result =
            await session.getLibraryByUri('dart:core') as LibraryElementResult;
        return result.element;
      });

  Future<Configuration> resolveConfiguration(AstNode node) async {
    assert(needsRecomputing.isEmpty);

    if (configurations[node] case final configuration?) {
      return configuration;
    }

    needsRecomputing.add(node);

    await runUntilSettled();

    return configurations[node]!;
  }

  Future<Configuration> resolveElementConfiguration(Element element) async {
    assert(needsRecomputing.isEmpty);

    return runZoned(zoneValues: {dependentKey: implicitDependent}, () async {
      final alreadyKnown = await getElementConfiguration(element);
      if (needsRecomputing.isEmpty) {
        return alreadyKnown;
      }

      await runUntilSettled();

      return await getElementConfiguration(element);
    });
  }

  Future<void> runUntilSettled() async {
    while (needsRecomputing.isNotEmpty) {
      final nodes = needsRecomputing;
      needsRecomputing = LinkedHashSet(
        equals: _astNodeEquals,
        hashCode: _astNodeHash,
      );

      Future<void> process(AstNode node) =>
          runZoned(zoneValues: {dependentKey: node}, () async {
            final oldConfiguration = configurations[node];
            final newConfiguration = await node.accept(generator)!;

            if (oldConfiguration != newConfiguration) {
              configurations[node] = newConfiguration;
              needsRecomputing.addAll(dependents[node] ?? {});
            }
          });

      await Future.wait(nodes.map(process));
    }
  }

  Configuration getConfiguration(AstNode node) {
    final dependent = Zone.current[dependentKey]!;

    if (dependent is AstNode) {
      (dependents[node] ??= LinkedHashSet(
            equals: _astNodeEquals,
            hashCode: _astNodeHash,
          ))
          .add(dependent);
    } else {
      assert(dependent == implicitDependent);
    }

    if (configurations[node] case final configuration?) {
      return configuration;
    } else {
      needsRecomputing.add(node);
      return configurations[node] = Configuration.empty;
    }
  }

  Throws readConfiguration(List<ElementAnnotation> annotations) {
    final safeType = TypeChecker.fromName(
      'Safe',
      packageName: 'checked_exceptions_annotations',
    );
    final throwsErrorType = TypeChecker.fromName(
      'ThrowsError',
      packageName: 'checked_exceptions_annotations',
    );
    final neverThrowsType = TypeChecker.fromName(
      'NeverThrows',
      packageName: 'checked_exceptions_annotations',
    );
    final throwsType = TypeChecker.fromName(
      'Throws',
      packageName: 'checked_exceptions_annotations',
    );

    var canThrowUndeclaredErrors = false;
    final thrownTypes = <DartType>{};

    for (final annotation in annotations) {
      final value = annotation.computeConstantValue();
      final type = value?.type;

      if (type is! InterfaceType) continue;

      if (neverThrowsType.isAssignableFromType(type)) {
        return Throws.explicit({}, canThrowUndeclaredErrors: false);
      } else if (safeType.isAssignableFromType(type)) {
        return Throws.explicit({}, canThrowUndeclaredErrors: true);
      } else if (throwsErrorType.isAssignableFromType(type)) {
        canThrowUndeclaredErrors =
            canThrowUndeclaredErrors || throwsType.isAssignableFromType(type);
        thrownTypes.add(type.typeArguments.single);
      }
    }

    if (thrownTypes.isNotEmpty) {
      return Throws.explicit(
        thrownTypes,
        canThrowUndeclaredErrors: canThrowUndeclaredErrors,
      );
    }

    return Throws.empty;
  }

  ValueThrows getTypeConfiguration(DartType type) {
    final explicit = switch (type.alias) {
      final alias? => readConfiguration(alias.element.metadata),
      _ => Throws.empty,
    };

    switch (type) {
      case FunctionType():
        final returnConfiguration = getTypeConfiguration(type.returnType);

        return {
          PromotionType.invoke: Configuration(explicit, returnConfiguration),
        };

      case InterfaceType()
          when type.isDartAsyncFuture || type.isDartAsyncFutureOr:
        final resultConfiguration = getTypeConfiguration(
          type.typeArguments.single,
        );

        return {
          PromotionType.await_: Configuration(explicit, resultConfiguration),
        };

      default:
        return {};
    }
  }

  Future<Configuration> getElementConfiguration(Element element) async {
    if (element is PropertyAccessorElement &&
        element.isGetter &&
        element.isSynthetic) {
      final variable = element.nonSynthetic;
      final library =
          await session.getResolvedLibraryByElement(variable.library!)
              as ResolvedLibraryResult;
      final variableDeclaration = library.getElementDeclaration(variable)!;

      return getConfiguration(variableDeclaration.node);
    } else if (element is PropertyAccessorElement &&
        element.isGetter &&
        element.isSynthetic) {
      return Configuration.empty;
    } else if (element is ConstructorElement && element.isSynthetic) {
      return Configuration.forValue({
        PromotionType.invoke: Configuration.empty,
      });
    }

    final library =
        await session.getResolvedLibraryByElement(element.library!)
            as ResolvedLibraryResult;
    final declaration = library.getElementDeclaration(element);

    if (declaration == null) {
      throw 'Unable to get declaration for ${element.runtimeType} $element';
    }

    return getConfiguration(declaration.node);
  }

  Future<Throws> _mergeThrows(Iterable<Throws> throws) async {
    final canThrowUndeclaredErrors = throws.any(
      (t) => t.canThrowUndeclaredErrors,
    );

    final typeSystem = await this.typeSystem;
    final exceptionType = await this.exceptionType;

    final thrownTypes = <DartType>{};
    for (final thrownType in throws.expand((t) => t.thrownTypes)) {
      if (canThrowUndeclaredErrors &&
          !typeSystem.isAssignableTo(thrownType, exceptionType)) {
        continue;
      }

      if (thrownTypes.any(
        (alreadyThrown) => typeSystem.isAssignableTo(thrownType, alreadyThrown),
      )) {
        continue;
      }

      thrownTypes.removeWhere(
        (alreadyThrown) => typeSystem.isAssignableTo(alreadyThrown, thrownType),
      );

      thrownTypes.add(thrownType);
    }

    return Throws(
      thrownTypes: thrownTypes,
      canThrowUndeclaredErrors: canThrowUndeclaredErrors,
    );
  }

  Future<ValueThrows> _mergeValueThrows(Iterable<ValueThrows> throws) async {
    final toMerge = <PromotionType, List<Configuration>>{};
    for (final MapEntry(:key, :value) in throws.expand((e) => e.entries)) {
      (toMerge[key] ??= []).add(value);
    }

    final result = <PromotionType, Configuration>{};

    for (final MapEntry(:key, :value) in toMerge.entries) {
      result[key] = Configuration(
        await _mergeThrows(value.map((e) => e.throws)),
        await _mergeValueThrows(value.map((e) => e.valueConfigurations)),
      );
    }

    return result;
  }

  Configuration _resolveConfiguration(List<Configuration> configurations) {
    final throws = configurations
        .map((c) => c.throws)
        .firstWhere(
          (t) => !t.isInferred,
          orElse: () => configurations.first.throws,
        );

    final valueConfigurations = <PromotionType, List<Configuration>>{};
    for (final MapEntry(:key, :value) in configurations
        .map((e) => e.valueConfigurations)
        .expand((e) => e.entries)) {
      (valueConfigurations[key] ??= []).add(value);
    }

    return Configuration(throws, {
      for (final MapEntry(:key, :value) in valueConfigurations.entries)
        key: _resolveConfiguration(value),
    });
  }
}

class ConfigurationGenerator
    extends GeneralizingAstVisitor<Future<Configuration>> {
  final ConfigurationResolver resolver;

  ConfigurationGenerator(this.resolver);

  @override
  Future<Configuration> visitNode(AstNode node) async {
    throw UnsupportedError('Cannot get configuration for ${node.runtimeType}');
  }

  @override
  Future<Configuration> visitExpression(Expression node) {
    throw UnimplementedError(
      'Cannot get configuration for ${node.runtimeType}',
    );
  }

  @override
  Future<Configuration> visitDeclaration(Declaration node) async {
    throw UnimplementedError(
      'Cannot get configuration for ${node.runtimeType}',
    );
  }

  @override
  Future<Configuration> visitFunctionDeclaration(
    FunctionDeclaration node,
  ) async {
    final explicit = resolver.readConfiguration(node.declaredElement!.metadata);
    var returns = resolver.getTypeConfiguration(
      node.declaredElement!.returnType,
    );
    if (node.functionExpression.body.isAsynchronous) {
      returns = returns[PromotionType.await_]?.valueConfigurations ?? {};
    }

    final explicitBodyConfiguration = Configuration(explicit, returns);

    final inferrer = FunctionConfigurationInferrer(resolver);
    await node.functionExpression.body.accept(inferrer);

    final inferredBodyConfiguration = Configuration(
      await resolver._mergeThrows(inferrer.throws),
      await resolver._mergeValueThrows(inferrer.returns),
    );

    final bodyConfiguration = resolver._resolveConfiguration([
      inferredBodyConfiguration,
      explicitBodyConfiguration,
    ]);

    var invokeConfiguration = bodyConfiguration;
    if (node.functionExpression.body.isAsynchronous) {
      invokeConfiguration = Configuration.forValue({
        PromotionType.await_: invokeConfiguration,
      });
    }

    return Configuration.forValue({PromotionType.invoke: invokeConfiguration});
  }

  @override
  Future<Configuration> visitConstructorDeclaration(
    ConstructorDeclaration node,
  ) async {
    final explicit = resolver.readConfiguration(node.declaredElement!.metadata);
    final explicitBodyConfiguration = Configuration.throws(explicit);

    final inferrer = FunctionConfigurationInferrer(resolver);
    await node.body.accept(inferrer);

    final inferredBodyConfiguration = Configuration.throws(
      await resolver._mergeThrows(inferrer.throws),
    );

    final bodyConfiguration = resolver._resolveConfiguration([
      inferredBodyConfiguration,
      explicitBodyConfiguration,
    ]);

    return Configuration.forValue({PromotionType.invoke: bodyConfiguration});
  }

  @override
  Future<Configuration> visitMethodDeclaration(MethodDeclaration node) async {
    final explicit = resolver.readConfiguration(node.declaredElement!.metadata);
    var returns = resolver.getTypeConfiguration(
      node.declaredElement!.returnType,
    );
    if (node.body.isAsynchronous) {
      returns = returns[PromotionType.await_]?.valueConfigurations ?? {};
    }

    final explicitBodyConfiguration = Configuration(explicit, returns);

    final inferrer = FunctionConfigurationInferrer(resolver);
    await node.body.accept(inferrer);

    final inferredBodyConfiguration = Configuration(
      await resolver._mergeThrows(inferrer.throws),
      await resolver._mergeValueThrows(inferrer.returns),
    );

    final bodyConfiguration = resolver._resolveConfiguration([
      inferredBodyConfiguration,
      explicitBodyConfiguration,
    ]);

    var invokeConfiguration = bodyConfiguration;
    if (node.body.isAsynchronous) {
      invokeConfiguration = Configuration.forValue({
        PromotionType.await_: invokeConfiguration,
      });
    }

    var configuration = invokeConfiguration;
    if (!node.isGetter) {
      configuration = Configuration.forValue({
        PromotionType.invoke: configuration,
      });
    }

    final clazz = node.declaredElement!.enclosingElement3;
    MethodElement? overridden;
    if (clazz is ClassElement) {
      final supertypes = {
        if (clazz.supertype case final supertype?) supertype,
        ...clazz.mixins,
        ...clazz.interfaces,
      };

      while (supertypes.isNotEmpty && overridden == null) {
        final supertype = supertypes.first;
        supertypes.remove(supertype);
        final superclass = supertype.element;

        overridden = superclass.methods.firstWhereOrNull(
          (m) => m.name == node.name.lexeme,
        );

        supertypes.addAll({
          if (superclass.supertype case final supertype?) supertype,
          ...superclass.mixins,
          ...superclass.interfaces,
        });
      }
    }

    final overriddenConfiguration = switch (overridden) {
      final element? => await resolver.getElementConfiguration(element),
      _ => Configuration.empty,
    };

    return resolver._resolveConfiguration([
      configuration,
      overriddenConfiguration,
    ]);
  }

  @override
  Future<Configuration> visitClassDeclaration(ClassDeclaration node) async {
    return Configuration.empty;
  }

  @override
  Future<Configuration> visitVariableDeclaration(
    VariableDeclaration node,
  ) async {
    return _variableElementConfiguration(
      node.declaredElement!,
      node.initializer,
    );
  }

  @override
  Future<Configuration> visitNormalFormalParameter(
    NormalFormalParameter node,
  ) async {
    return _variableElementConfiguration(node.declaredElement!, null);
  }

  @override
  Future<Configuration> visitDefaultFormalParameter(
    DefaultFormalParameter node,
  ) async {
    return _variableElementConfiguration(
      node.declaredElement!,
      node.defaultValue,
    );
  }

  Configuration _variableElementConfiguration(
    VariableElement element,
    Expression? initializer,
  ) {
    var explicit = Configuration.throws(
      resolver.readConfiguration(element.metadata),
    );

    final explicitConfiguration = switch (element.type) {
      FunctionType() => {PromotionType.invoke: explicit},
      InterfaceType type
          when type.isDartAsyncFuture || type.isDartAsyncFutureOr =>
        {PromotionType.await_: explicit},
      _ => <PromotionType, Configuration>{},
    };

    final typeConfiguration = resolver.getTypeConfiguration(element.type);

    final initializerConfiguration = switch (initializer) {
      final initializer? => resolver.getConfiguration(initializer),
      _ => Configuration.empty,
    };

    final config = resolver._resolveConfiguration([
      initializerConfiguration,
      Configuration.forValue(typeConfiguration),
      Configuration.forValue(explicitConfiguration),
    ]);

    return config;
  }

  @override
  Future<Configuration> visitAsExpression(AsExpression node) async {
    return Configuration(
      Throws.exactly({await resolver.typeErrorType}),
      resolver.getConfiguration(node.expression).valueConfigurations,
    );
  }

  @override
  Future<Configuration> visitAugmentedExpression(
    AugmentedExpression node,
  ) async {
    final library =
        await resolver.session.getResolvedLibraryByElement(
              node.element!.library!,
            )
            as ResolvedLibraryResult;
    final declaration = library.getElementDeclaration(node.element!)!;

    if (node.element case FieldElement()) {
      return resolver.getConfiguration(
        (declaration.node as VariableDeclaration).initializer!,
      );
    }

    return resolver.getConfiguration(declaration.node);
  }

  @override
  Future<Configuration> visitAugmentedInvocation(
    AugmentedInvocation node,
  ) async {
    return (await resolver.getElementConfiguration(
          node.element!,
        )).valueConfigurations[PromotionType.invoke] ??
        Configuration.throwsExactly(await resolver.noSuchMethodErrorType);
  }

  @override
  Future<Configuration> visitAwaitExpression(AwaitExpression node) async {
    final innerConfiguration = resolver.getConfiguration(node.expression);

    return innerConfiguration.valueConfigurations[PromotionType.await_] ??
        // For non-future expressions, just copy the value configuration.
        Configuration.forValue(innerConfiguration.valueConfigurations);
  }

  @override
  Future<Configuration> visitBinaryExpression(BinaryExpression node) async {
    if (node.operator.type == TokenType.QUESTION_QUESTION) {
      return Configuration.forValue(
        await resolver._mergeValueThrows([
          resolver.getConfiguration(node.leftOperand).valueConfigurations,
          resolver.getConfiguration(node.rightOperand).valueConfigurations,
        ]),
      );
    }

    return (await resolver.getElementConfiguration(
          node.staticElement!,
        )).valueConfigurations[PromotionType.invoke] ??
        Configuration.throwsExactly(await resolver.noSuchMethodErrorType);
  }

  @override
  Future<Configuration> visitCascadeExpression(CascadeExpression node) async {
    return Configuration.forValue(
      resolver.getConfiguration(node.target).valueConfigurations,
    );
  }

  @override
  Future<Configuration> visitConstructorReference(
    ConstructorReference node,
  ) async {
    return resolver.getConfiguration(node.constructorName);
  }

  @override
  Future<Configuration> visitConstructorName(ConstructorName node) async {
    return await resolver.getElementConfiguration(node.staticElement!);
  }

  @override
  Future<Configuration> visitFunctionReference(FunctionReference node) async {
    return Configuration.forValue(
      resolver.getConfiguration(node.function).valueConfigurations,
    );
  }

  @override
  Future<Configuration> visitIdentifier(Identifier node) async {
    if (node.staticElement case final element?) {
      return resolver.getElementConfiguration(element);
    }

    return Configuration.empty;
  }

  @override
  Future<Configuration> visitPropertyAccess(PropertyAccess node) async {
    return resolver
            .getConfiguration(node.propertyName)
            .valueConfigurations[PromotionType.invoke] ??
        Configuration.throwsExactly(await resolver.noSuchMethodErrorType);
  }

  @override
  Future<Configuration> visitTypeLiteral(TypeLiteral node) async {
    return Configuration.empty;
  }

  @override
  Future<Configuration> visitAssignmentExpression(
    AssignmentExpression node,
  ) async {
    final setterConfiguration = switch (node.staticElement) {
      final element? => await resolver.getElementConfiguration(element),
      _ => Configuration.forValue({PromotionType.invoke: Configuration.empty}),
    };

    return Configuration(
      setterConfiguration.valueConfigurations[PromotionType.invoke]!.throws,
      // Discard the return type of the setter; the RHS has more detailed
      // information.
      resolver.getConfiguration(node.rightHandSide).valueConfigurations,
    );
  }

  @override
  Future<Configuration> visitConditionalExpression(
    ConditionalExpression node,
  ) async {
    return Configuration.forValue(
      await resolver._mergeValueThrows([
        resolver.getConfiguration(node.thenExpression).valueConfigurations,
        resolver.getConfiguration(node.elseExpression).valueConfigurations,
      ]),
    );
  }

  @override
  Future<Configuration> visitExtensionOverride(ExtensionOverride node) async {
    return Configuration.empty;
  }

  @override
  Future<Configuration> visitFunctionExpression(FunctionExpression node) async {
    final inferrer = FunctionConfigurationInferrer(resolver);
    node.body.visitChildren(inferrer);

    var configuration = Configuration(
      await resolver._mergeThrows(inferrer.throws),
      await resolver._mergeValueThrows(inferrer.returns),
    );

    if (node.body.isAsynchronous) {
      configuration = Configuration.forValue({
        PromotionType.await_: configuration,
      });
    }

    return Configuration.forValue({PromotionType.invoke: configuration});
  }

  @override
  Future<Configuration> visitInstanceCreationExpression(
    InstanceCreationExpression node,
  ) async {
    return resolver
            .getConfiguration(node.constructorName)
            .valueConfigurations[PromotionType.invoke] ??
        Configuration.throwsExactly(await resolver.noSuchMethodErrorType);
  }

  @override
  Future<Configuration> visitFunctionExpressionInvocation(
    FunctionExpressionInvocation node,
  ) async {
    return resolver
            .getConfiguration(node.function)
            .valueConfigurations[PromotionType.invoke] ??
        Configuration.throwsExactly(await resolver.noSuchMethodErrorType);
  }

  @override
  Future<Configuration> visitMethodInvocation(MethodInvocation node) async {
    return resolver
            .getConfiguration(node.methodName)
            .valueConfigurations[PromotionType.invoke] ??
        Configuration.throwsExactly(await resolver.noSuchMethodErrorType);
  }

  @override
  Future<Configuration> visitIsExpression(IsExpression node) async {
    return Configuration.empty;
  }

  @override
  Future<Configuration> visitLiteral(Literal node) async {
    return Configuration.empty;
  }

  @override
  Future<Configuration> visitImplicitCallReference(
    ImplicitCallReference node,
  ) async {
    return await resolver.getElementConfiguration(node.staticElement);
  }

  @override
  Future<Configuration> visitIndexExpression(IndexExpression node) async {
    return (await resolver.getElementConfiguration(
          node.staticElement!,
        )).valueConfigurations[PromotionType.invoke] ??
        Configuration.throwsExactly(await resolver.noSuchMethodErrorType);
  }

  @override
  Future<Configuration> visitPostfixExpression(PostfixExpression node) async {
    if (node.staticElement case final element?) {
      return (await resolver.getElementConfiguration(
            element,
          )).valueConfigurations[PromotionType.invoke] ??
          Configuration.throwsExactly(await resolver.noSuchMethodErrorType);
    }

    if (node.operator.type == TokenType.BANG) {
      return Configuration.throwsExactly(await resolver.typeErrorType);
    }

    return super.visitPostfixExpression(node)!;
  }

  @override
  Future<Configuration> visitPrefixExpression(PrefixExpression node) async {
    if (node.staticElement case final element?) {
      return (await resolver.getElementConfiguration(
            element,
          )).valueConfigurations[PromotionType.invoke] ??
          Configuration.throwsExactly(await resolver.noSuchMethodErrorType);
    }

    if (node.operator.type == TokenType.BANG) {
      return Configuration.empty;
    }

    return super.visitPrefixExpression(node)!;
  }

  @override
  Future<Configuration> visitNamedExpression(NamedExpression node) async {
    return Configuration.forValue(
      resolver.getConfiguration(node.expression).valueConfigurations,
    );
  }

  @override
  Future<Configuration> visitParenthesizedExpression(
    ParenthesizedExpression node,
  ) async {
    return Configuration.forValue(
      resolver.getConfiguration(node.expression).valueConfigurations,
    );
  }

  @override
  Future<Configuration> visitPatternAssignment(PatternAssignment node) async {
    return Configuration.throwsExactly(await resolver.stateErrorType);
  }

  @override
  Future<Configuration> visitRethrowExpression(RethrowExpression node) async {
    var catchClause = node.parent;
    while (catchClause is! CatchClause) {
      catchClause = catchClause!.parent;
    }

    if (catchClause.exceptionType case final type?) {
      return Configuration.throwsExactly(type.type!);
    }

    return Configuration.throwsExactly(await resolver.objectType);
  }

  @override
  Future<Configuration> visitSuperExpression(SuperExpression node) async {
    return Configuration.empty;
  }

  @override
  Future<Configuration>? visitSwitchExpression(SwitchExpression node) {
    // TODO: implement visitSwitchExpression
    return super.visitSwitchExpression(node);
  }

  @override
  Future<Configuration> visitThisExpression(ThisExpression node) async {
    return Configuration.empty;
  }

  @override
  Future<Configuration> visitThrowExpression(ThrowExpression node) async {
    return Configuration.throwsExactly(node.expression.staticType!);
  }
}

class FunctionConfigurationInferrer
    extends GeneralizingAstVisitor<Future<void>> {
  final List<ValueThrows> returns = [];
  final List<Throws> throws = [];

  final ConfigurationResolver resolver;

  FunctionConfigurationInferrer(this.resolver);

  @override
  Future<void> visitNode(AstNode node) {
    return Future.wait(
      node.childEntities.whereType<AstNode>().map((e) => e.accept(this)!),
    );
  }

  @override
  Future<void> visitExpression(Expression node) async {
    throws.add(resolver.getConfiguration(node).throws);
    return await super.visitExpression(node);
  }

  @override
  Future<void> visitFunctionExpression(FunctionExpression node) async {}

  @override
  Future<void> visitReturnStatement(ReturnStatement node) async {
    if (node.expression case final expression?) {
      returns.add(resolver.getConfiguration(expression).valueConfigurations);
    }
    await super.visitReturnStatement(node);
  }

  @override
  Future<void> visitTryStatement(TryStatement node) async {
    final tryBodyVisitor = FunctionConfigurationInferrer(resolver);
    node.body.accept(tryBodyVisitor);

    returns.addAll(tryBodyVisitor.returns);

    var bodyThrows = await resolver._mergeThrows(tryBodyVisitor.throws);
    final typeSystem = await resolver.typeSystem;

    for (final catchClause in node.catchClauses) {
      catchClause.accept(this);

      if (catchClause.exceptionType case final caughtType?) {
        bodyThrows.thrownTypes.removeWhere(
          (type) => typeSystem.isAssignableTo(type, caughtType.type!),
        );
      } else {
        bodyThrows = Configuration.empty.throws;
      }
    }

    throws.add(bodyThrows);
  }
}
