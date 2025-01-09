import 'package:analyzer/dart/ast/ast.dart';
import 'package:collection/collection.dart';

class AstNodeEquality implements Equality<AstNode> {
  @override
  bool equals(AstNode a, AstNode b) {
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
  @override
  int hash(AstNode e) => Object.hash(e.offset, e.length, e.runtimeType);

  @override
  bool isValidKey(Object? o) => o is AstNode;
}
