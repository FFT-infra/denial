import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'model.dart';
import 'build_cache.dart';
import 'rebuild.dart';
import 'source.dart';
import 'store.dart';

/// Requests native transitions only. The compositor validates compatibility,
/// confirms startup, persists selection, and owns packaged-shell recovery.
final class CompositionActivation {
  CompositionActivation(
    this.store, {
    this.denialctl = 'denialctl',
    this.run = runCommand,
  });
  final ManagerStore store;
  final String denialctl;
  final CommandRunner run;

  Future<Map<String, Object?>> status() async {
    try {
      return await _request(['status']);
    } catch (error) {
      return {'available': false, 'error': '$error'};
    }
  }

  Future<void> requireSupport() async {
    final native = await status();
    if (native['available'] == false) {
      throw const CompositionException(
        'Denial is not available. Apply plugins from your Denial session.',
      );
    }
    if (!native.containsKey('plugin_healthy')) {
      throw const CompositionException(
        'Log out and back into Denial once to finish the update. Your plugin choices are saved.',
      );
    }
  }

  Future<Map<String, Object?>> activate(String id) async {
    ManagerStore.validateId(id);
    final plan = store.read('candidates/$id/plan.json');
    final build = store.read('candidates/$id/build.json');
    if (build['status'] != 'built' || plan['status'] != 'built') {
      throw const CompositionException('Build the candidate before activation');
    }
    if (plan['rebuildOf'] case final String base) {
      // A rebuild may replace only the composition deniald is still waiting
      // for. Restoring the packaged shell or applying another composition
      // meanwhile is the user's newer decision.
      if (!waitsForRebuildOf(store, await status(), base)) {
        throw const CompositionException(
          'Denial no longer waits for these plugins to be rebuilt',
        );
      }
    } else if (plan['selectionRevision'] != store.selection['revision']) {
      throw const CompositionException(
        'Selection changed after this candidate was planned; plan again',
      );
    }
    final identity = plan['sourceIdentity'] as Map?;
    final required = (identity?['required_native_capabilities'] as List? ?? [])
        .cast<String>();
    if (required.isNotEmpty) {
      final native = await status();
      final supported = (native['capabilities'] as List? ?? []).cast<String>();
      if (required.any((capability) => !supported.contains(capability))) {
        throw const CompositionException(
          'Log out and back into Denial once to finish the update. Your plugin choices are saved.',
        );
      }
    }
    final bundle = Directory(
      p.join(store.root.path, 'candidates', id, 'bundle'),
    ).resolveSymbolicLinksSync();
    if (build['bundle'] != bundle) {
      throw const CompositionException(
        'Candidate bundle does not match its build record',
      );
    }
    // Applying an unchanged, verified composition should not interrupt the
    // desktop. Keep the physical active bundle and rollback history untouched.
    final current = store.read('active.json');
    if (build['reusedFrom'] != null && current['id'] is String) {
      final currentId = current['id']! as String;
      ManagerStore.validateId(currentId);
      final currentBuild = store.read('candidates/$currentId/build.json');
      final checksum = (build['manifest'] as Map)['engine_sha256']! as String;
      if (currentBuild['cacheKey'] == build['cacheKey'] &&
          current['bundle'] is String &&
          BuildCache.validBundle(
            Directory(current['bundle']! as String),
            checksum,
          )) {
        final status = await this.status();
        if (status['plugin_bundle'] == current['bundle'] &&
            status['plugin_healthy'] == true &&
            status['active_mode'] == 'custom_optimized') {
          _rememberInstalled(plan);
          return status;
        }
      }
    }
    final native = await _request(['activate', bundle]);
    if (native['plugin_bundle'] != bundle ||
        native['plugin_healthy'] != true ||
        native['active_mode'] != 'custom_optimized') {
      throw const CompositionException(
        'The compositor did not confirm this candidate as healthy',
      );
    }
    final previous = store.read('active.json');
    _rememberInstalled(plan);
    store.write('active.json', {
      'id': id,
      'bundle': bundle,
      'previous': previous['id'] == id ? previous['previous'] : previous['id'],
      'nativeGeneration': native['generation'],
    });
    return native;
  }

  Future<Map<String, Object?>> restore() async {
    final native = await _request(['restore']);
    if (native['active_mode'] != 'official_optimized') {
      throw const CompositionException(
        'The compositor did not restore the packaged shell',
      );
    }
    final previous = store.read('active.json');
    store.write('active.json', {
      'id': null,
      'previous': previous['id'] ?? previous['previous'],
      'nativeGeneration': native['generation'],
    });
    return native;
  }

  Future<Map<String, Object?>> revert() async {
    final native = await _request(['revert']);
    if (native['plugin_healthy'] != true ||
        native['plugin_bundle'] is! String) {
      throw const CompositionException(
        'The previous composition was not confirmed healthy',
      );
    }
    final bundle = native['plugin_bundle']! as String;
    final id = p.basename(p.dirname(bundle));
    ManagerStore.validateId(id);
    final expected = p.join(store.root.path, 'candidates', id, 'bundle');
    if (bundle != expected) {
      throw const CompositionException(
        'Restored composition belongs to a different manager state directory',
      );
    }
    final plan = store.read('candidates/$id/plan.json');
    final selection = store.selection;
    // Rollback restores intent as well as the retained binary. Explicit updates
    // remain available later; rollback never rewrites an old candidate.
    store.write('selection.json', {
      ...selection,
      'roots': plan['roots'],
      'selections': plan['selections'] ?? <String, Object?>{},
      'ordering': plan['ordering'] ?? <String, Object?>{},
      'revision': (selection['revision']! as int) + 1,
    });
    // Subsequent apply must retain this composition's pins, rather than those
    // of the candidate that was rolled back. Only update advances revisions.
    store.write('last-plan.json', {'id': id});
    _rememberInstalled(plan);
    final previous = store.read('active.json');
    store.write('active.json', {
      'id': id,
      'bundle': bundle,
      'previous': previous['id'],
      'nativeGeneration': native['generation'],
    });
    return native;
  }

  void _rememberInstalled(Map<String, Object?> plan) {
    // Re-enabling an updated plugin must retain its last confirmed revision,
    // including after another composition no longer contains that root.
    final installed = store.read('installed.json');
    store.write('installed.json', {
      'plugins': {
        ...?installed['plugins'] as Map<String, Object?>?,
        ...?plan['roots'] as Map<String, Object?>?,
      },
    });
  }

  Future<Map<String, Object?>> _request(List<String> operation) async =>
      // denialctl waits for mode transitions by default; its opt-out is
      // --no-wait. It deliberately has no separate --wait option.
      jsonDecode(await run(denialctl, ['--json', 'ui', ...operation]))
          as Map<String, Object?>;
}
