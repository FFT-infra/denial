import 'package:test/test.dart';

// Pure model coverage without loading Flutter or a development engine.
// ignore: avoid_relative_lib_imports
import '../../denial_flutter_sdk/lib/src/models/shortcut_configuration.dart';

void main() {
  test(
    'saved plugin bindings survive absent providers and recover metadata',
    () {
      const id = 'example.anyAction';
      final saved = <String, Object?>{
        'revision': 7,
        'shortcuts': [
          {
            'shortcut': 'Super',
            'target': {'type': 'pluginAction', 'id': id},
          },
        ],
        'supported_actions': ['lockScreen'],
      };
      final missing = DenialShortcutConfiguration.fromJson(saved);
      final target =
          missing.shortcuts.single.target as DenialShortcutPluginActionTarget;
      expect(target.id, id);
      expect(target.descriptor, isNull);
      expect(missing.actionChoices, [DenialShortcutAction.lockScreen]);
      final restored = DenialShortcutConfiguration.fromJson({
        ...saved,
        'action_generation': 2,
        'plugin_actions': [
          {
            'id': id,
            'label': 'Example',
            'description': '',
            'provider': 'Example plugin',
          },
        ],
      });
      final active =
          restored.shortcuts.single.target as DenialShortcutPluginActionTarget;
      expect(active.descriptor?.label, 'Example');
      expect(restored.actionChoices, hasLength(2));
      expect(active.toJson(), target.toJson());
      expect(active.toJson(), {'type': 'pluginAction', 'id': id});
      final disabled = DenialShortcutConfiguration(
        revision: 7,
        actionGeneration: 3,
        shortcuts: restored.shortcuts,
        supportedActions: restored.supportedActions,
        supportedInputs: [],
      );
      expect(
        (disabled.shortcuts.single.target as DenialShortcutPluginActionTarget)
            .descriptor,
        isNull,
      );
      expect(
        disabled.shortcuts.single.toJson(),
        restored.shortcuts.single.toJson(),
      );
    },
  );
}
