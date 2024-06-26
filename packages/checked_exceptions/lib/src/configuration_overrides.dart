import 'dart:convert';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/scope.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:checked_exceptions/src/configuration.dart';
import 'package:collection/collection.dart';
import 'package:yaml/yaml.dart';

// ignore_for_file: implementation_imports
import 'package:analyzer/src/string_source.dart';
import 'package:analyzer/src/dart/scanner/scanner.dart';
import 'package:analyzer/src/generated/parser.dart';
import 'package:analyzer/src/dart/resolver/resolution_visitor.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/scope.dart';

/// A collection of configuration overrides in a given project.
class ConfigurationOverrides {
  final Map<ElementLocation, Configuration> overrides;

  ConfigurationOverrides(this.overrides);

  static Future<ConfigurationOverrides?> loadFile(
      AnalysisSession session, Uri uri) async {
    final path = session.uriConverter.uriToPath(uri);
    if (path == null) return null;

    final file = session.resourceProvider.getFile(path);
    if (!file.exists) return null;

    try {
      final document = loadYaml(file.readAsStringSync());

      if (document case {'checked_exceptions': List rawOverrides}) {
        final declaredOverrides = await Future.wait(rawOverrides
            .whereType<Map>()
            .map((raw) => ConfigurationOverride.parseForSession(session, raw)));

        final overrides = <ElementLocation, Configuration>{};
        for (final override in declaredOverrides.nonNulls) {
          overrides[override.location] = override.configuration;
        }

        return ConfigurationOverrides(overrides);
      }

      return null;
    } on YamlException {
      return null;
    }
  }

  /// Compute the [ConfigurationOverrides] for the given [session].
  static Future<ConfigurationOverrides> forSession(
      AnalysisSession session) async {
    final overrides = <ElementLocation, Configuration>{};

    Future<void> loadConfigurationFile(Uri uri) async {
      final fileOverrides = await loadFile(session, uri);
      if (fileOverrides != null) overrides.addAll(fileOverrides.overrides);
    }

    // First load the default configuration
    await loadConfigurationFile(
      Uri(
          scheme: 'package',
          path: 'checked_exceptions/checked_exceptions.yaml'),
    );

    // Then load all the dependencies' configurations
    final tasks = <Future<void>>[];

    // Use the packages file instead of pubspec so we include transitive dependencies too.
    final packagesFile = session.analysisContext.contextRoot.packagesFile;
    if (packagesFile != null && packagesFile.exists) {
      final decoded = jsonDecode(packagesFile.readAsStringSync());
      if (decoded case {'configVersion': 2, 'packages': List packages}) {
        for (final package in packages.whereType<Map<String, dynamic>>()) {
          final packageName = package['name'];
          if (packageName == null) continue;
          tasks.add(
            loadConfigurationFile(Uri(
                scheme: 'package',
                path: '$packageName/checked_exceptions.yaml')),
          );
        }
      }
    }

    // Finally, load the overrides from the current project. These will already have been loaded
    // once, but we reload them so they have higher precedence.
    await loadConfigurationFile(
      session.analysisContext.contextRoot.root
          .getChildAssumingFolder('lib')
          .getChildAssumingFile('checked_exceptions.yaml')
          .toUri(),
    );

    return ConfigurationOverrides(overrides);
  }
}

class ConfigurationOverride {
  final ElementLocation location;
  final Configuration configuration;

  ConfigurationOverride(this.location, this.configuration);

  static Future<ConfigurationOverride?> parseForSession(
    AnalysisSession session,
    Map raw,
  ) async {
    // Format is
    // - library: <path to library>
    //   element: Element.name
    //   imports:
    //     - <path to library>
    //     - <path to library>
    //   throws: [DartType, DartType]
    //   allows_undeclared: true
    //   value:
    //     promotion_type:
    //       throws: [DartType, DartType]
    //       value: ...

    final libraryUri = raw['library'];
    final elementName = raw['element'];
    final rawImports = raw['imports'];

    if (libraryUri is! String ||
        elementName is! String ||
        rawImports is! List?) {
      return null;
    }

    final imports = List.of(rawImports?.map((e) => e.toString()) ?? <String>[]);

    final library = await session.getLibraryByUri(libraryUri);
    if (library is! LibraryElementResult) return null;

    final elementParts = elementName.split('.');
    Element? element = library.element;
    for (final part in elementParts) {
      if (element == null) break;
      element = switch (element) {
        ClassElement() when part == 'new' => element.constructors
            .singleWhereOrNull((element) => element.isDefaultConstructor),
        LibraryElement(:final scope) => scope.lookup(part).getter,
        TypeAliasElement(aliasedType: FunctionType(:final parameters)) ||
        VariableElement(type: FunctionType(:final parameters)) ||
        FunctionTypedElement(:final parameters) =>
          parameters.indexed
              .singleWhereOrNull((element) =>
                  element.$2.name == part ||
                  (element.$2.isPositional && '\$${element.$1}' == part))
              ?.$2,
        // Catches InstanceElement
        _ =>
          element.children.singleWhereOrNull((element) => element.name == part),
      };
    }

    final elementLocation = element?.location;
    if (element == null || elementLocation == null) return null;

    final libraries = <LibraryElement>[];

    for (final uri in imports) {
      final importedLibrary = await session.getLibraryByUri(uri);
      if (importedLibrary is! LibraryElementResult) continue;
      libraries.add(importedLibrary.element);
    }
    libraries.add(library.element);

    final errorListener = RecordingErrorListener();
    final featureSet = FeatureSet.latestLanguageVersion();

    final resolutionVisitor = ResolutionVisitor(
      unitElement: library.element.units.first as CompilationUnitElementImpl,
      errorListener: errorListener,
      featureSet: featureSet,
      nameScope: _MergedScopes(libraries),
      strictInference: false,
      strictCasts: false,
    );

    Configuration? parseConfiguration(Map raw) {
      var isConfigurationMap = false;

      final thrownTypes = <DartType>[];
      if (raw['throws'] case List declaredThrows) {
        isConfigurationMap = true;
        for (final declaredThrownType in declaredThrows.whereType<String>()) {
          final source = StringSource(declaredThrownType, null);
          final scanner = Scanner.fasta(source, errorListener)
            ..configureFeatures(
                featureSetForOverriding: featureSet, featureSet: featureSet);
          final token = scanner.tokenize();
          final parser = Parser(
            source,
            errorListener,
            lineInfo: LineInfo(scanner.lineStarts),
            featureSet: featureSet,
          )..currentToken = token;

          final typeAnnotation = parser.parseTypeAnnotation(false)
            ..accept(resolutionVisitor);
          final thrownType = typeAnnotation.type;
          if (thrownType == null) continue;
          thrownTypes.add(thrownType);
        }
      }

      final valueConfigurations = <PromotionType, Configuration>{};
      for (final promotionType in PromotionType.values) {
        if (raw[promotionType.key] case Map declaredValueConfiguration) {
          isConfigurationMap = true;
          final parsedConfiguration =
              parseConfiguration(declaredValueConfiguration);
          if (parsedConfiguration == null) continue;
          valueConfigurations[promotionType] = parsedConfiguration;
        }
      }

      if (!isConfigurationMap) return null;

      return Configuration(
        (
          thrownTypes: thrownTypes,
          canThrowUndeclaredErrors: raw['allows_undeclared'] == true,
        ),
        valueConfigurations,
      );
    }

    final configuration = parseConfiguration(raw);
    if (configuration == null) return null;

    return ConfigurationOverride(
      elementLocation,
      configuration,
    );
  }
}

class _MergedScopes implements Scope {
  final List<LibraryElement> libraries;

  _MergedScopes(this.libraries);

  @override
  ScopeLookupResult lookup(String id) {
    for (final library in libraries) {
      final result = library.scope.lookup(id);
      if (result.getter != null || result.setter != null) return result;
    }

    return ScopeLookupResultImpl(null, null);
  }
}
