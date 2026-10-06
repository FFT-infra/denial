import 'dart:async';

import 'package:denial_sdk/composition.dart';
import 'package:flutter/widgets.dart';

import 'services.dart';

/// A named operation supplied by the statically compiled plugin composition.
/// IDs are stable package-qualified strings, e.g. `my_plugin.showSearch`.
/// The host publishes descriptors only after binding these handlers.
@ExtensionPoint(cardinality: ContributionCardinality.zeroOrMore)
abstract interface class ShellAction {
  String get id;
  String get provider;
  String label(BuildContext context);
  String description(BuildContext context);
  FutureOr<void> invoke(ShellActionContext context);
}

class ShellActionContext {
  const ShellActionContext({required this.services, this.monitorId});
  final ShellServices services;
  final int? monitorId;
}
