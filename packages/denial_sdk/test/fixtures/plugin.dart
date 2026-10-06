@Plugin()
library;

import 'package:denial_sdk/composition.dart';

import '../../example/contracts.dart' as original;
import 'other_contract.dart' as other;

@Provides(other.ApplicationLabel)
final class OtherLabel implements other.ApplicationLabel {
  const OtherLabel();

  @override
  String label() => 'other';
}

// This is valid Dart metadata but not a valid provider. The future builder
// must use assignability, not accept every class carrying @Provides.
@Provides(original.ApplicationLabel)
final class InvalidProvider {}
