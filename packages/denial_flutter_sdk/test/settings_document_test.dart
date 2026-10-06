import 'dart:convert';

import 'package:denial_flutter_sdk/src/settings/settings_document.dart';
import 'package:test/test.dart';

void main() {
  test('ordinary saves preserve opaque root and nested plugin preferences', () {
    final document = SettingsDocumentProjection();
    final plugin = {
      'enabled': true,
      'options': [null, 3, 'custom'],
    };
    document.remember(
      revision: 1,
      document: jsonEncode({
        'version': 28,
        'plugins': {'example': plugin},
        'appearance': {
          'panelOpacity': .4,
          'pluginOptions': plugin,
          'glass': {'opacity': .5, 'pluginAmount': null},
        },
      }),
    );
    final projection = {
      'version': 28,
      'appearance': {
        'panelOpacity': .7,
        'glass': {'opacity': .8},
      },
    };
    final saved = document.encode(projection);
    final decoded = jsonDecode(saved) as Map;
    expect(decoded['plugins'], {'example': plugin});
    expect(decoded['appearance'], {
      'panelOpacity': .7,
      'pluginOptions': plugin,
      'glass': {'opacity': .8, 'pluginAmount': null},
    });
    document.remember(revision: 2, document: saved);
    expect(jsonDecode(document.encode(projection)), decoded);
  });

  test('removing environment overrides does not resurrect saved entries', () {
    final document = SettingsDocumentProjection();
    document.remember(
      revision: 1,
      document: jsonEncode({
        'plugins': {'example': true},
        'applicationEnvironment': {
          'default': {'REMOVE_ME': 'old'},
          'applications': {
            'removed.desktop': {'OLD': 'value'},
          },
        },
      }),
    );
    final decoded = jsonDecode(
      document.encode({
        'applicationEnvironment': {
          'default': {'KEEP_ME': null},
          'applications': <String, Object?>{},
        },
      }),
    ) as Map;
    expect(decoded['applicationEnvironment'], {
      'default': {'KEEP_ME': null},
      'applications': <String, Object?>{},
    });
    expect(decoded['plugins'], {'example': true});
  });

  test(
    'refreshed documents retain newer plugin data and reject stale state',
    () {
      final document = SettingsDocumentProjection();
      document.remember(revision: 1, document: '{"plugins":{"example":1}}');
      document.remember(revision: 2, document: '{"plugins":{"example":2}}');
      document.remember(revision: 1, document: '{"plugins":{"example":1}}');
      expect(document.revision, 2);
      expect(jsonDecode(document.encode({'version': 28})), {
        'plugins': {'example': 2},
        'version': 28,
      });
      expect(
        () => document.remember(revision: 3, document: '[]'),
        throwsFormatException,
      );
      expect(document.revision, 2);
    },
  );
}
