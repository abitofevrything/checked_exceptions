import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:checked_exceptions/src/configuration_builder.dart';

void main() async {
  // final examplePath = Platform.script.resolve('./example.dart').toFilePath();
  final examplePath =
      '/home/abitofevrything/src/checked_exceptions/packages/example/example.dart';

  final context = AnalysisContextCollection(includedPaths: [examplePath])
      .contextFor(examplePath);

  final builder = ConfigurationBuilder(context.currentSession);

  final result = await context.currentSession.getResolvedLibrary(examplePath);
  result as ResolvedLibraryResult;

  final ast = result.units.first.unit;

  final simpleThrows =
      ast.declarations.firstWhere((d) => d.declaredElement?.name == 'foo');

  final configuration = await builder.getConfiguration(simpleThrows);

  return;
}
