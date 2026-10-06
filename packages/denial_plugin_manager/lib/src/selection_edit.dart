import 'dart:convert';

import 'model.dart';
import 'preflight.dart';
import 'source.dart';
import 'store.dart';

/// Called under the manager lock. A draft becomes one selection revision;
/// stale clients and invalid selections cannot partially change the roots.
Future<void> commitSelectionDraft(
  ManagerStore store,
  SourceRepository repository,
  Map<String, Object?> draft,
) async {
  final current = store.selection;
  if (draft['revision'] != current['revision']) {
    throw const CompositionException(
      'The plugin selection changed elsewhere. Discard your draft and try again.',
    );
  }
  final requested = draft['roots'];
  if (requested is! Map<String, Object?>) {
    throw const CompositionException('Invalid plugin selection draft.');
  }
  final known = <String, Object?>{
    ...?store.read('installed.json')['plugins'] as Map<String, Object?>?,
    ...current['roots']! as Map<String, Object?>,
  };
  final roots = <String, Object?>{};
  for (final entry in requested.entries) {
    final value = entry.value! as Map<String, Object?>;
    final source = PluginSource.fromJson(
      value['source']! as Map<String, Object?>,
    );
    final retained = known[entry.key] as Map<String, Object?>?;
    if (retained != null &&
        jsonEncode(retained['source']) == jsonEncode(source.toJson())) {
      roots[entry.key] = retained;
    } else {
      final resolved = await repository.resolve(source);
      if (resolved.name != entry.key) {
        throw CompositionException(
          'Package name changed: expected ${entry.key}, found ${resolved.name}.',
        );
      }
      roots[entry.key] = resolved.toJson();
    }
  }
  final proposed = {...current, 'roots': roots};
  SelectionPreflight(store).requireValid(selection: proposed);
  // Compare independently of toggle order. Returning to the original draft
  // should preserve the revision and allow the existing build to be reused.
  final old = current['roots']! as Map;
  if (old.length == roots.length &&
      roots.entries.every(
        (entry) => jsonEncode(old[entry.key]) == jsonEncode(entry.value),
      )) {
    return;
  }
  store.write('installed.json', {
    'plugins': {...known, ...roots},
  });
  store.write('selection.json', {
    ...proposed,
    'revision': (current['revision']! as int) + 1,
  });
}
