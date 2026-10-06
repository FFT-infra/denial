import 'package:denial_sdk/composition.dart';
import 'package:flutter/widgets.dart';

/// Complete shell composition, inside Denial's platform bootstrap. Alternative
/// desktops can implement this contract without adopting the reference layout.
@ExtensionPoint(cardinality: ContributionCardinality.exactlyOne)
abstract interface class ShellApplication {
  Widget createShell();
}
