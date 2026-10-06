import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late AnalysisContextCollection contexts;
  late String root;

  setUpAll(() {
    root = Directory.current.absolute.path;
    contexts = AnalysisContextCollection(includedPaths: [root]);
  });

  tearDownAll(() async => contexts.dispose());

  Future<LibraryElement> library(String relative) async {
    final path = p.join(root, relative);
    final result = await contexts
        .contextFor(path)
        .currentSession
        .getResolvedLibrary(path);
    expect(result, isA<ResolvedLibraryResult>());
    final resolved = result as ResolvedLibraryResult;
    expect(resolved.units.expand((unit) => unit.diagnostics), isEmpty);
    return resolved.element;
  }

  DartObject annotation(Element element, String name) => element
      .metadata
      .annotations
      .map((annotation) => annotation.computeConstantValue())
      .whereType<DartObject>()
      .singleWhere(
        (value) => (value.type as InterfaceType).element.name == name,
      );

  test('discovers a plugin library without executing its code', () async {
    final plugin = await library('example/plugin.dart');
    final marker = annotation(plugin, 'Plugin');
    final markerClass = (marker.type as InterfaceType).element;
    expect(markerClass.library.uri.scheme, 'package');
    expect(markerClass.library.uri.path, startsWith('denial_sdk/'));

    final contracts = await library('example/contracts.dart');
    expect(contracts.metadata.annotations, isEmpty);
    final contract = contracts.classes.single;
    final cardinality = annotation(
      contract,
      'ExtensionPoint',
    ).getField('cardinality')!;
    expect(cardinality.getField('index')!.toIntValue(), 0);
  });

  test('provider metadata resolves an external contract type', () async {
    final plugin = await library('example/plugin.dart');
    final implementation = plugin.classes.single;
    final contract = annotation(
      implementation,
      'Provides',
    ).getField('contract')!.toTypeValue()!;

    expect(contract, isA<InterfaceType>());
    expect((contract as InterfaceType).element.name, 'ApplicationLabel');
    expect(
      contract.element.library.uri.path,
      endsWith('/example/contracts.dart'),
    );
    expect(
      plugin.typeSystem.isAssignableTo(implementation.thisType, contract),
      isTrue,
    );
  });

  test('same-name contracts retain distinct resolved identities', () async {
    final plugin = await library('test/fixtures/plugin.dart');
    final first = plugin.classes.singleWhere((c) => c.name == 'OtherLabel');
    final second = plugin.classes.singleWhere(
      (c) => c.name == 'InvalidProvider',
    );
    final otherType =
        annotation(first, 'Provides').getField('contract')!.toTypeValue()!
            as InterfaceType;
    final originalType =
        annotation(second, 'Provides').getField('contract')!.toTypeValue()!
            as InterfaceType;

    expect(otherType.element.name, originalType.element.name);
    expect(
      otherType.element.library.uri,
      isNot(originalType.element.library.uri),
    );
    expect(otherType, isNot(originalType));
    expect(plugin.typeSystem.isAssignableTo(first.thisType, otherType), isTrue);
    expect(
      plugin.typeSystem.isAssignableTo(first.thisType, originalType),
      isFalse,
    );
    expect(
      plugin.typeSystem.isAssignableTo(second.thisType, originalType),
      isFalse,
      reason:
          'Annotations alone must not be mistaken for interface validation.',
    );
  });
}
