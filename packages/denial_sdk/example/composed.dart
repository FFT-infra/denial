import 'package:denial_sdk/denial_sdk.dart';

import 'contracts.dart';
import 'plugin.dart';

/// Handwritten illustration of future generated code, not a plugin manager.
void main() {
  const ApplicationLabel labels = NamedApplicationLabel();
  const application = DesktopApp(
    id: 'org.example.Editor.desktop',
    name: 'Editor',
    exec: 'editor %F',
    desktopPath: '/usr/share/applications/org.example.Editor.desktop',
    categories: ['Development'],
  );
  print(labels.label(application));
}
