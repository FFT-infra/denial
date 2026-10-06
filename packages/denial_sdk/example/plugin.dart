@Plugin()
library;

import 'package:denial_sdk/denial_sdk.dart';

import 'contracts.dart';

@Provides(ApplicationLabel)
final class NamedApplicationLabel implements ApplicationLabel {
  const NamedApplicationLabel();

  @override
  String label(DesktopApp application) => application.name;
}
