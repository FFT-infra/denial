import 'dart:convert';

/// Canonical declaring library URI and type name; never a bare class name.
final class TypeId implements Comparable<TypeId> {
  const TypeId(this.library, this.name);
  final String library;
  final String name;
  String get key => '$library#$name';
  Map<String, Object?> toJson() => {'library': library, 'name': name};
  @override
  String toString() => key;
  @override
  bool operator ==(Object other) => other is TypeId && key == other.key;
  @override
  int get hashCode => key.hashCode;
  @override
  int compareTo(TypeId other) => key.compareTo(other.key);
}

enum Cardinality { exactlyOne, zeroOrOne, zeroOrMore }

final class Contract {
  const Contract(this.type, this.cardinality);
  final TypeId type;
  final Cardinality cardinality;
  Map<String, Object?> toJson() => {
    'type': type.toJson(),
    'cardinality': cardinality.name,
  };
}

final class Injection {
  const Injection(
    this.name,
    this.contract, {
    this.named = false,
    this.many = false,
    this.nullable = false,
  });
  final String name;
  final TypeId contract;
  final bool named;
  final bool many;
  final bool nullable;
  Map<String, Object?> toJson() => {
    'name': name,
    'contract': contract.toJson(),
    'named': named,
    'many': many,
    'nullable': nullable,
  };
}

final class Contribution {
  const Contribution({
    required this.package,
    required this.type,
    required this.contracts,
    required this.arguments,
  });
  final String package;
  final TypeId type;
  final List<TypeId> contracts;
  final List<Injection> arguments;
  Map<String, Object?> toJson() => {
    'package': package,
    'type': type.toJson(),
    'contracts': contracts.map((c) => c.toJson()).toList(),
    'arguments': arguments.map((a) => a.toJson()).toList(),
  };
}

final class CompositionException implements Exception {
  const CompositionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Fully resolved build-time declarations, with deterministic serialization.
final class Discovery {
  const Discovery({
    required this.plugins,
    required this.contracts,
    required this.contributions,
    required this.dependencyChains,
  });
  factory Discovery.fromJson(Map<String, Object?> value) {
    TypeId type(Object? value) {
      final json = value! as Map;
      return TypeId(json['library'] as String, json['name'] as String);
    }

    return Discovery(
      plugins: (value['plugins']! as List).cast<String>(),
      contracts: [
        for (final item in value['contracts']! as List)
          Contract(
            type((item as Map)['type']),
            Cardinality.values.byName(item['cardinality'] as String),
          ),
      ],
      contributions: [
        for (final item in value['contributions']! as List)
          Contribution(
            package: (item as Map)['package'] as String,
            type: type(item['type']),
            contracts: [
              for (final contract in item['contracts'] as List) type(contract),
            ],
            arguments: [
              for (final argument in item['arguments'] as List)
                Injection(
                  (argument as Map)['name'] as String,
                  type(argument['contract']),
                  named: argument['named'] as bool,
                  many: argument['many'] as bool,
                  nullable: argument['nullable'] as bool,
                ),
            ],
          ),
      ],
      dependencyChains: (value['dependencyChains']! as Map).map(
        (name, chain) =>
            MapEntry(name as String, (chain as List).cast<String>()),
      ),
    );
  }
  final List<String> plugins;
  final List<Contract> contracts;
  final List<Contribution> contributions;
  final Map<String, List<String>> dependencyChains;
  Map<String, Object?> toJson() => {
    'plugins': plugins,
    'contracts': contracts.map((c) => c.toJson()).toList(),
    'contributions': contributions.map((c) => c.toJson()).toList(),
    'dependencyChains': dependencyChains,
  };
  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}
