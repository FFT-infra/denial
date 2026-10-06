import 'package:meta/meta_meta.dart';

/// Marks a library as a plugin contribution library.
///
/// A build tool discovers this metadata within the selected Pub application
/// dependency closure. Importing the library does not activate anything.
/// Multiple contribution libraries may belong to the same package; the package
/// remains the selection/dependency unit. Ordinary SDK/API libraries do not
/// need this annotation merely because they define extension points.
///
/// The plugin manager and discovery implementation are not part of this SDK.
@Target({TargetKind.library})
final class Plugin {
  const Plugin();
}

/// Allowed number of selected implementations for a used extension point.
///
/// Counts describe the generated composition, not the number of declarations
/// available in package sources. Merely importing a contract does not require
/// the generated application to use it.
enum ContributionCardinality {
  /// Exactly one selected implementation; absence and ambiguity are errors.
  exactlyOne,

  /// Zero or one selected implementation; ambiguity is an error.
  zeroOrOne,

  /// Any number of explicitly ordered contributions, including none.
  zeroOrMore,
}

/// Declares a public contract that plugins can implement.
///
/// Apply to an abstract interface class in the SDK or an external API package.
/// Implementations are ordinary Dart implementations of that interface.
/// Cardinality, construction, and dependency validation belong to the build
/// tool; this annotation performs no runtime checking or registration.
///
/// Contract identity is its resolved Dart type/library, not its class name.
@Target({TargetKind.classType})
final class ExtensionPoint {
  const ExtensionPoint({required this.cardinality});

  final ContributionCardinality cardinality;
}

/// Declares that a public concrete class supplies [contract].
///
/// The referenced contract must be an [ExtensionPoint] and the annotated class
/// must implement it. The builder must validate both facts using resolved types;
/// a Type-valued annotation alone cannot enforce assignability in Dart.
///
/// Generated application code constructs the implementation normally, with
/// explicit dependencies. This annotation neither invokes a constructor nor
/// changes existing code. It does not imply a default constructor, runtime
/// service locator, source rewriting, or registration order.
@Target({TargetKind.classType})
final class Provides {
  const Provides(this.contract);

  final Type contract;
}
