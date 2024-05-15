import 'dart:async';
import 'dart:io' hide File, Directory;
import 'dart:io' as io show File, Directory;

import 'package:analyzer/dart/analysis/context_builder.dart';
import 'package:analyzer/dart/analysis/context_locator.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/file_system/file_system.dart' as file_system;
import 'package:checked_exceptions/src/configuration.dart';
import 'package:checked_exceptions/src/configuration_builder.dart';
import 'package:checked_exceptions/src/configuration_overrides.dart';
import 'package:yaml/yaml.dart';
import 'package:path/path.dart' as path;

class BootstrappingConfigurationBuilder extends ConfigurationBuilder {
  final Iterable<Element> allElements;
  late final List<InterfaceElement> allInterfaceElements =
      allElements.whereType<InterfaceElement>().toList();
  final Expando<Set<InterfaceElement>> _subclassCache = Expando();

  BootstrappingConfigurationBuilder(
    super.session, {
    required super.objectType,
    required super.typeErrorType,
    required super.overrides,
    required this.allElements,
  });

  static Future<BootstrappingConfigurationBuilder> forSession(
    AnalysisSession session,
    Iterable<Element> allElements, {
    required ConfigurationOverrides overrides,
  }) async {
    final builder =
        await ConfigurationBuilder.forSession(session, overrides: overrides);

    return BootstrappingConfigurationBuilder(
      session,
      objectType: builder.objectType,
      typeErrorType: builder.typeErrorType,
      overrides: builder.overrides,
      allElements: allElements,
    );
  }

  // When bootstrapping configurations, we want to ensure the configurations do not cause any
  // conflicts in the code we are generating them for - that is, we assume all errors thrown are
  // intentional.
  //
  // Inherited configurations commonly cause errors as abstract methods are inferred as throwing no
  // errors, so subtypes inherit that configuration even if they throw errors.
  //
  // To fix this, we invert the direction of inherited configurations - we "inherit" it from
  // _implementers_, and they direct what the current element can throw. If the current element
  // provides an implementation for the function, we also consider it in the result.
  @override
  Future<Configuration?> getInheritedConfiguration(
    InterfaceElement interface,
    Element element,
  ) async {
    if ((element is ClassMemberElement && element.isStatic) ||
        element is ConstructorElement) {
      return null;
    }

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

    Set<InterfaceElement> getDirectSubtypeElements(InterfaceElement element) =>
        _subclassCache[element] ??= allInterfaceElements
            .where((potentialSubtype) =>
                getDirectSupertypeElements(potentialSubtype).contains(element))
            .toSet();

    final elementsToVisit = getDirectSubtypeElements(interface);
    final visitedElements = <Element>{};

    final implementerConfigurationFutures = <Future<Configuration?>>[];
    while (elementsToVisit.isNotEmpty) {
      final subclassElement = elementsToVisit.first;
      elementsToVisit.remove(subclassElement);
      visitedElements.add(subclassElement);

      var foundMatching = false;

      if (!element.isPrivate || element.library == subclassElement.library) {
        for (final subclassElement in subclassElement.children) {
          if (element.name == subclassElement.name &&
              (subclassElement is ClassMemberElement &&
                  !subclassElement.isStatic) &&
              subclassElement is! ConstructorElement) {
            foundMatching = true;
            implementerConfigurationFutures
                .add(getElementConfiguration(subclassElement));
            break;
          }
        }
      }

      if (!foundMatching) {
        final nextToVisit = getDirectSubtypeElements(subclassElement);
        elementsToVisit.addAll(
            nextToVisit.where((element) => !visitedElements.contains(element)));
      }
    }

    if (element is ExecutableElement) {
      implementerConfigurationFutures
          .add(getExecutableElementThrowsConfiguration(
        element,
        await computeTypeConfiguration(element.returnType),
      ));
    } else if (element is VariableElement) {
      implementerConfigurationFutures
          .add(getVariableElementInitializerConfiguration(element));
    }

    final implementerConfigurations =
        (await Future.wait(implementerConfigurationFutures)).nonNulls.toList();

    return Configuration.unionConfigurations(implementerConfigurations);
  }
}

Future<void> main() async {
  print('Ensuring dependencies are up to date...');

  final dummyProjectLocation = Platform.script.resolve('./dummy_project/');
  final dummyProjectPubspecLocation =
      dummyProjectLocation.resolve('pubspec.yaml');

  final process = await Process.start(
    Platform.executable,
    ['pub', 'upgrade', '--major-versions'],
    workingDirectory: dummyProjectLocation.toFilePath(),
  );

  process.stdout.forEach(stdout.add);
  process.stderr.forEach(stderr.add);

  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    exit(exitCode);
  }

  final targetLibraries = <String>{};

  final contextLocator = ContextLocator();
  final contextBuilder = ContextBuilder();

  final roots = contextLocator
      .locateRoots(includedPaths: [dummyProjectPubspecLocation.toFilePath()]);
  final context = contextBuilder.createContext(contextRoot: roots.single);

  print('Discovering libraries...');
  final sdkLib = context.sdkRoot?.getChildAssumingFolder('lib');
  if (sdkLib != null && sdkLib.exists) {
    final folders = sdkLib.getChildren().whereType<file_system.Folder>();
    for (final folder in folders) {
      final pathSegments = folder.toUri().pathSegments;
      final name = pathSegments[pathSegments.length - 2];
      targetLibraries.add('dart:$name');
    }
  }
  print('Found ${targetLibraries.length} SDK libraries:');
  print(targetLibraries);

  final dummyProjectPubspecFile = context.currentSession.resourceProvider
      .getFile(dummyProjectPubspecLocation.toFilePath());
  final dummyPubspecContents =
      loadYaml(dummyProjectPubspecFile.readAsStringSync());
  final dummyProjectDependencies =
      dummyPubspecContents['dependencies'] as YamlMap;

  Future<void> discoverLibrariesInPackage(String packageName) async {
    final dependencyRoot = context.currentSession.uriConverter.uriToPath(
      Uri(scheme: 'package', path: '$packageName/'),
    );
    if (dependencyRoot == null) return;
    final folder =
        context.currentSession.resourceProvider.getFolder(dependencyRoot);
    if (!folder.exists) return;
    final directory = io.Directory(folder.path);

    final dartSourceFiles = directory
        .list(recursive: true)
        .where((event) => event is io.File)
        .cast<io.File>()
        .where((event) => event.path.endsWith('.dart'));

    await for (final file in dartSourceFiles) {
      final pathInPackage = path.relative(
        from: folder.path,
        file.path,
      );

      targetLibraries.add('package:$packageName/$pathInPackage');
    }
  }

  await Future.wait(dummyProjectDependencies.keys
      .cast<String>()
      .map(discoverLibrariesInPackage));

  print('Found ${targetLibraries.length} libraries total');
  print('Loading elements...');

  final publicElements = <Element>{};
  final allElements = <Element>{};

  int counter = 0;

  void loadElement(Element e, {required bool inPublicContext}) {
    if (e.isSynthetic) return;

    if (++counter % 1000 == 0) {
      print('Found $counter elements...');
    }

    final isPublic = inPublicContext && !e.isPrivate;
    if (isPublic) publicElements.add(e);

    if (allElements.add(e)) {
      for (final child in e.children) {
        loadElement(child, inPublicContext: isPublic);
      }
    }
  }

  Future<void> loadLibrary(String uri) async {
    final result = await context.currentSession.getLibraryByUri(uri);
    if (result is! LibraryElementResult) {
      // This is fine, we expect this.
      if (result is! NotLibraryButPartResult) {
        print('Unable to load library $uri: $result');
      }
      return;
    }

    final isImplementationLibrary =
        RegExp(r'^package:[^/]+/src/').hasMatch(uri);

    for (final child in result.element.exportNamespace.definedNames.values) {
      loadElement(child, inPublicContext: !isImplementationLibrary);
    }

    for (final child in result.element.children) {
      if (!result.element.exportNamespace.definedNames.containsValue(child)) {
        loadElement(child, inPublicContext: false);
      }
    }
  }

  await Future.wait(targetLibraries.map(loadLibrary));

  print(
      'Loaded ${publicElements.length} public elements, ${allElements.length} elements in total');
  print('Loading bootstrap overrides...');

  final overrides = await ConfigurationOverrides.loadFile(
    context.currentSession,
    Platform.script.resolve('./bootstrap_checked_exceptions.yaml'),
  );

  if (overrides == null) {
    print('Failed to load overrides');
    exit(1);
  }

  print('Loaded ${overrides.overrides.length} overrides');
  print('Generating configurations...');

  final builder = await BootstrappingConfigurationBuilder.forSession(
    context.currentSession,
    allElements,
    overrides: overrides,
  );

  final output =
      io.File.fromUri(Platform.script.resolve('../lib/checked_exceptions.yaml'))
          .openWrite();
  output.writeln('''
# Format is
# checked_exceptions:
#   - library: <path to library>
#     element: Element.name
#     imports:
#       - <path to library>
#       - <path to library>
#     throws: [DartType, DartType]
#     allows_undeclared: true
#     promotion_type:
#       throws: [DartType, DartType]
#       ...

# This file is generated. Run tool/dump_element_configurations.dart to regenerate it.
# Edit tool/bootstrap_checked_exceptions.yaml to manually configure SDK configuration overrides.
''');
  output.writeln('checked_exceptions:');

  await output.flush();

  await Future.wait(
      publicElements.map((e) => handleElement(builder, output, e)));

  await output.close();

  // This message is here so we can tell if the computation finished successfully or if it hung
  // and the program exited due to a "future deadlock".
  print('Done!');
}

Future<void> handleElement(
  ConfigurationBuilder builder,
  StringSink output,
  Element element,
) async {
  final library = element.library;
  if (library == null) return;

  if (element is! ExecutableElement && element is! VariableElement) {
    // Unhandled
    return;
  }

  String? getLocation(Element element) {
    switch (element) {
      case ClassElement() ||
            ExtensionElement() ||
            TypeAliasElement() ||
            FunctionElement() ||
            EnumElement() ||
            PropertyAccessorElement(
              enclosingElement: CompilationUnitElement()
            ) ||
            ExtensionTypeElement() ||
            MixinElement():
        return element.name;
      case FieldElement(:InstanceElement enclosingElement) ||
            MethodElement(:InstanceElement enclosingElement) ||
            PropertyAccessorElement(:InstanceElement enclosingElement) ||
            ConstructorElement(:InstanceElement enclosingElement):
        final enclosingLocation = getLocation(enclosingElement);
        if (enclosingLocation == null) return null;

        if (element is ConstructorElement && element.name.isEmpty) {
          return '$enclosingLocation.new';
        }

        return '$enclosingLocation.${element.name}';
      case ParameterElement(
            enclosingElement: Element enclosingElement &&
                (ExecutableElement() || ParameterElement())
          )
          when element.name.isNotEmpty:
        final enclosingLocation = getLocation(enclosingElement);
        if (enclosingLocation == null) return null;

        return '$enclosingLocation.${element.name}';
      default:
        return null;
    }
  }

  final elementLocation = getLocation(element);
  if (elementLocation == null) {
    print('Unable to get element location for ${element.runtimeType}');
    return;
  }

  if (elementLocation != 'ThrowingAstVisitor.visitAsExpression') return;

  final configuration = await builder.getElementConfiguration(element);
  if (configuration == null) {
    print('Unable to get configuration for ${element.runtimeType}');
    return;
  }

  String serializeConfiguration(Configuration configuration) {
    final result = StringBuffer();
    if (configuration.throws.thrownTypes.isNotEmpty ||
        configuration.valueConfigurations.isEmpty) {
      result.writeln('throws: [${configuration.throws.thrownTypes.join(',')}]');
    }
    if (configuration.throws.canThrowUndeclaredErrors) {
      result.writeln('allows_undeclared: true');
    }

    for (final MapEntry(:key, :value)
        in configuration.valueConfigurations.entries) {
      final serializedConfiguration = serializeConfiguration(value);
      result.writeln('${key.key}:');
      result.writeln('  ${serializedConfiguration.replaceAll('\n', '\n  ')}');
    }

    return result.toString().trim();
  }

  final serializedConfiguration = serializeConfiguration(configuration);

  output.writeln(
    '  - library: ${library.source.uri.toString()}\n'
    '    element: $elementLocation\n'
    '    ${serializedConfiguration.replaceAll('\n', '\n    ')}\n',
  );
}
