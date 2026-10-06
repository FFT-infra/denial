import 'package:denial_sdk/composition.dart';

// Intentionally shares its name with example/contracts.dart's interface.
@ExtensionPoint(cardinality: ContributionCardinality.zeroOrMore)
abstract interface class ApplicationLabel {
  String label();
}
