import 'package:denial_sdk/denial_sdk.dart';

// A plugin ecosystem can define contracts without editing the SDK.
@ExtensionPoint(cardinality: ContributionCardinality.exactlyOne)
abstract interface class ApplicationLabel {
  String label(DesktopApp application);
}
