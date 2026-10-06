/// Evaluate cached plugin declarations without I/O or executing plugin code.
/// Both the manager UI and the build preflight use this advisory check.
Map<String, Object?> checkPluginSelection(
  Map<String, Object?> selection,
  Map<String, Object?> packages,
) {
  final providers = <String, List<String>>{};
  final requirements = <Map<String, Object?>>[
    {
      'contract':
          'package:denial_flutter_sdk/application.dart#ShellApplication',
      'label': 'Desktop',
      'owner': 'Denial',
      'min': 1,
      'max': 1,
    },
  ];
  final issues = <Map<String, Object?>>[];
  final unknown = <String>{};
  final visited = <String>{};
  final choices = selection['selections'] as Map? ?? {};
  void visit(String name) {
    if (!visited.add(name)) return;
    final facts = packages[name] as Map?;
    if (facts == null) {
      unknown.add(name);
      return;
    }
    for (final entry in (facts['providers'] as Map).entries) {
      providers
          .putIfAbsent(entry.key as String, () => [])
          .addAll((entry.value as List).cast<String>());
    }
    requirements.addAll(
      (facts['requirements'] as List).cast<Map<String, Object?>>(),
    );
    issues.addAll((facts['issues'] as List).cast<Map<String, Object?>>());
    unknown.addAll((facts['unknown'] as List).cast<String>());
    for (final dependency in (facts['dependencies'] as List).cast<String>()) {
      visit(dependency);
    }
  }

  for (final name in (selection['roots'] as Map).keys.cast<String>()) {
    visit(name);
  }
  for (final requirement in requirements) {
    final id = requirement['contract']! as String;
    // Explicit provider selection is validated with actual Dart types later.
    if (choices.containsKey(id)) continue;
    final names = providers[id] ?? [];
    final max = requirement['max'] as int?;
    final min = requirement['min']! as int;
    final label = requirement['label'];
    if (max != null && names.length > max) {
      issues.add({
        'code': 'too_many_providers',
        'contract': id,
        'title': '$label conflict',
        'message':
            '$label is provided by ${names.toSet().join(' and ')}. ${requirement['owner']} accepts ${max == 1 ? 'only one' : 'at most $max'}. Disable ${names.length - max == 1 ? 'one of these plugins' : 'extra plugins'} before applying.',
        'plugins': names.toSet().toList(),
        'requirement': requirement,
      });
    } else if (names.length < min && unknown.isEmpty) {
      issues.add({
        'code': 'missing_provider',
        'contract': id,
        'title': '$label is missing',
        'message':
            '${requirement['owner']} needs ${min == 1 ? 'a provider for' : 'at least $min providers for'} $label. Enable a compatible plugin before applying.',
        'plugins': <String>[],
        'requirement': requirement,
      });
    }
  }
  return {
    'selectionRevision': selection['revision'],
    'canApply': issues.isEmpty,
    'complete': unknown.isEmpty,
    'issues': issues,
    'uncheckedPackages': unknown.toList()..sort(),
  };
}
