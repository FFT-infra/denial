import 'dart:convert';

import 'model.dart';

/// Static construction plan. IDs in persisted choices are library-qualified;
/// emitted Dart always references actual types and constructors.
final class CompositionPlan {
  CompositionPlan._(this.discovery, this.providers, this.constructionOrder);
  final Discovery discovery;
  final Map<TypeId, List<Contribution>> providers;
  final List<Contribution> constructionOrder;

  static CompositionPlan resolve(
    Discovery discovery, {
    Map<String, String> selections = const {},
    Map<String, List<String>> ordering = const {},
    Iterable<TypeId> requiredContracts = const [],
  }) {
    final byContract = <TypeId, List<Contribution>>{};
    final knownContracts = {for (final c in discovery.contracts) c.type: c};
    for (final c in discovery.contracts) {
      var candidates = discovery.contributions
          .where((p) => p.contracts.contains(c.type))
          .toList();
      final choice = selections[c.type.key];
      if (choice != null) {
        if (c.cardinality == Cardinality.zeroOrMore) {
          throw CompositionException(
            '${c.type}: use collection ordering, not exclusive selection',
          );
        }
        candidates = candidates.where((p) => p.type.key == choice).toList();
        if (candidates.length != 1) {
          throw CompositionException(
            '${c.type}: selected provider $choice is unavailable',
          );
        }
      }
      if (c.cardinality != Cardinality.zeroOrMore && candidates.length > 1) {
        throw CompositionException(
          '${c.type}: conflicting providers ${candidates.map((p) => p.type).join(', ')}; select one or disable a root',
        );
      }
      if (c.cardinality == Cardinality.exactlyOne && candidates.isEmpty) {
        throw CompositionException(
          '${c.type}: exactly one provider is required',
        );
      }
      final order = ordering[c.type.key];
      if (order != null) {
        final ids = candidates.map((p) => p.type.key).toSet();
        if (order.length != ids.length ||
            order.toSet().length != ids.length ||
            !order.toSet().containsAll(ids)) {
          throw CompositionException(
            '${c.type}: ordering must list every provider exactly once',
          );
        }
        candidates.sort(
          (a, b) =>
              order.indexOf(a.type.key).compareTo(order.indexOf(b.type.key)),
        );
      }
      byContract[c.type] = candidates;
    }
    final keys = knownContracts.keys.map((c) => c.key).toSet();
    for (final key in {...selections.keys, ...ordering.keys}) {
      if (!keys.contains(key)) {
        throw CompositionException(
          'Selection references an unavailable contract $key',
        );
      }
    }
    for (final type in requiredContracts) {
      if ((byContract[type] ?? []).isEmpty) {
        throw CompositionException(
          '$type: required by the application, but no provider is enabled',
        );
      }
    }
    final built = <TypeId>{};
    final visiting = <TypeId>[];
    final order = <Contribution>[];
    void visit(Contribution contribution) {
      if (built.contains(contribution.type)) return;
      if (visiting.contains(contribution.type)) {
        throw CompositionException(
          'Constructor dependency cycle: ${[...visiting, contribution.type].join(' -> ')}',
        );
      }
      visiting.add(contribution.type);
      for (final argument in contribution.arguments) {
        final providers = byContract[argument.contract] ?? [];
        if (!argument.many &&
            (providers.length > 1 ||
                (providers.isEmpty && !argument.nullable))) {
          throw CompositionException(
            '${contribution.type}.${argument.name} requires ${argument.contract}; found ${providers.length} providers${providers.isEmpty ? '' : ': ${providers.map((provider) => provider.type).join(', ')}'}',
          );
        }
        for (final dependency in providers) {
          visit(dependency);
        }
      }
      visiting.removeLast();
      built.add(contribution.type);
      order.add(contribution);
    }

    final active = byContract.values.expand((p) => p).toSet().toList()
      ..sort((a, b) => a.type.compareTo(b.type));
    for (final contribution in active) {
      visit(contribution);
    }
    return CompositionPlan._(discovery, byContract, order);
  }

  /// Emits ordinary Dart declarations, without reflection or a runtime registry.
  /// All providers have composition lifetime. Constructor dependencies are built
  /// once; generated application code owns integration and normal disposal.
  GeneratedComposition generate() {
    final libraries = <String>{
      ...constructionOrder.map((c) => c.type.library),
      ...providers.keys.map((c) => c.library),
    }.toList()..sort();
    final aliases = {
      for (var i = 0; i < libraries.length; i++) libraries[i]: 'p$i',
    };
    String type(TypeId id) => '${aliases[id.library]}.${id.name}';
    final variables = {
      for (var i = 0; i < constructionOrder.length; i++)
        constructionOrder[i].type: 'provider$i',
    };
    String argument(Injection injection) {
      final values = providers[injection.contract] ?? [];
      final expression = injection.many
          ? '<${type(injection.contract)}>[${values.map((p) => variables[p.type]).join(', ')}]'
          : values.isEmpty
          ? 'null'
          : variables[values.single.type]!;
      return injection.named ? '${injection.name}: $expression' : expression;
    }

    final out = StringBuffer(
      '// Generated by denial_plugin_manager. Do not edit.\n',
    );
    for (final library in libraries) {
      out.writeln('import ${jsonEncode(library)} as ${aliases[library]};');
    }
    out.writeln();
    for (final contribution in constructionOrder) {
      out.writeln(
        'final ${type(contribution.type)} ${variables[contribution.type]} = ${type(contribution.type)}(${contribution.arguments.map(argument).join(', ')});',
      );
    }
    final exports = <TypeId, String>{};
    final contracts = providers.keys.toList()..sort();
    for (var i = 0; i < contracts.length; i++) {
      final contract = contracts[i];
      final values = providers[contract]!;
      exports[contract] = 'contract$i';
      out.writeln(
        'final List<${type(contract)}> contract$i = List<${type(contract)}>.unmodifiable([${values.map((p) => variables[p.type]).join(', ')}]);',
      );
    }
    return GeneratedComposition(out.toString(), exports);
  }
}

final class GeneratedComposition {
  const GeneratedComposition(this.source, this.contracts);
  final String source;
  final Map<TypeId, String> contracts;
}
