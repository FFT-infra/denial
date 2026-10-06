import 'dart:convert';
import 'dart:io';

import 'package:denial_plugin_manager_app/selection_draft.dart';
import 'package:denial_sdk/plugin_selection.dart';

void main() {
  void check(String name, bool value) {
    if (!value) throw StateError(name);
    stdout.writeln('PASS $name');
  }

  Map<String, Object?> plugin(String name) => {
    'name': name,
    'source': {'kind': 'local', 'location': '/plugins/$name', 'path': '.'},
  };
  final saved = <String, Object?>{
    'revision': 4,
    'roots': {'desktop': plugin('desktop'), 'top': plugin('top')},
  };
  final original = jsonEncode(saved);
  final draft = SelectionDraft()..observe(saved);
  check('initial selection is clean', !draft.dirty);
  draft.disable('top');
  draft.enable(plugin('bottom'));
  check(
    'switching bars edits only memory',
    draft.dirty && jsonEncode(saved) == original,
  );
  draft.observe(jsonDecode(original) as Map<String, Object?>);
  check(
    'polling preserves edits',
    draft.roots.containsKey('bottom') && !draft.roots.containsKey('top'),
  );
  draft.disable('bottom');
  draft.enable(plugin('top'));
  check('toggling back removes pending edits', !draft.dirty);
  draft.disable('top');
  draft.enable(plugin('bottom'));
  draft.observe({...saved, 'revision': 5});
  check(
    'external changes preserve draft and mark stale',
    draft.stale && draft.roots.containsKey('bottom'),
  );
  draft.discard();
  check(
    'discard adopts latest baseline',
    !draft.dirty &&
        !draft.stale &&
        draft.selection['revision'] == 5 &&
        draft.roots.containsKey('top'),
  );
  draft.disable('top');
  draft.enable(plugin('bottom'));
  draft.observe({...draft.selection, 'revision': 6});
  check(
    'Apply acknowledgement clears draft',
    !draft.dirty && draft.selection['revision'] == 6,
  );

  const desktop =
      'package:denial_flutter_sdk/application.dart#ShellApplication';
  const panel = 'package:denial_flutter_sdk/panels.dart#ShellPanel';
  Map<String, Object?> facts(
    String name,
    String contract, {
    List<String> dependencies = const [],
    List<Map<String, Object?>> requirements = const [],
  }) => {
    'providers': {
      contract: [name],
    },
    'requirements': requirements,
    'issues': <Map<String, Object?>>[],
    'unknown': <String>[],
    'dependencies': dependencies,
  };
  final cache = <String, Object?>{
    'desktop': facts(
      'Desktop',
      desktop,
      requirements: [
        {
          'contract': panel,
          'label': 'Panel',
          'owner': 'Desktop',
          'min': 0,
          'max': 1,
        },
      ],
    ),
    'top': facts('Top Bar', panel),
    'bottom': facts('Taskbar', panel),
  };
  check(
    'cached metadata accepts a single bar',
    checkPluginSelection(draft.selection, cache)['canApply'] == true,
  );
  draft.enable(plugin('top'));
  check(
    'cached metadata blocks both bars immediately',
    checkPluginSelection(draft.selection, cache)['canApply'] == false,
  );
  draft.disable('bottom');
  check(
    'cached metadata clears conflict immediately',
    checkPluginSelection(draft.selection, cache)['canApply'] == true,
  );
  draft.disable('desktop');
  check(
    'cached metadata detects missing desktop',
    checkPluginSelection(draft.selection, cache)['canApply'] == false,
  );
}
