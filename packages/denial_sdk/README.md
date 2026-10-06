# Denial SDK

Initial foundation for the [plugin architecture](../../docs/PLUGIN_SYSTEM.md).
This is a Dart-only package: no Flutter, `dart:ui`, Riverpod, native bridge, shell
implementation, or runtime plugin registry is required to import it.

## Public surface

| Library | API |
| --- | --- |
| `denial_sdk.dart` | Combined public exports |
| `composition.dart` | `Plugin`, `ExtensionPoint`, `Provides`, `ContributionCardinality` |
| `applications.dart` | Shared `DesktopApp` model |
| `windows.dart` | Shared `DenialWindowAction` vocabulary |
| `system.dart` | Shared battery, load-series, GPU, and MPRIS playback models |

The Flutter SDK and plugins use these same model types. Native integration and
Flutter providers live in `denial_flutter_sdk`; stock UI lives in plugins. There
is no parallel shell runtime API.

## Declaration contract

A contribution library uses `@Plugin()` on its library declaration. Multiple
contribution libraries may belong to a package; Pub's package remains the selection
and dependency unit. An unmarked API library can define contracts without being
activatable. Dependencies remain exclusively in `pubspec.yaml`.

```dart
@Plugin()
library;

import 'package:denial_sdk/composition.dart';
import 'package:my_desktop_api/my_desktop_api.dart';

@Provides(MyDesktopContract)
final class MyDesktopImplementation implements MyDesktopContract {
  // Ordinary implementation of the public contract.
}
```

The API package can define its own contract without changing Denial:

```dart
@ExtensionPoint(cardinality: ContributionCardinality.exactlyOne)
abstract interface class MyDesktopContract {
  // Domain-specific operations.
}
```

`exactlyOne`, `zeroOrOne`, and `zeroOrMore` describe selected contributions to a
contract used by the generated composition. They do not require every imported
contract to have an implementation. Collection ordering must be explicit.

Annotations are metadata, not executable hooks. The future builder must resolve
SDK annotation identities, inspect actual contract types, check assignability and
public constructibility, and generate direct wiring. Dart does not enforce that a
class implements a Type passed to an annotation. `@Provides` does not imply a
default constructor, constructor-injection algorithm, or runtime service locator.

Discovery must inspect contribution libraries under `lib/` within the selected
Pub application dependency closure; tests and examples are not contributions. Do not
activate build/dev tooling, use unqualified class-name matching, or execute plugin
imports to discover contributions.

## Implementation boundary

There is no plugin manager, generator, installer, or store yet. The
[top-bar plugin](../../plugins/denial_top_bar/README.md) is wired directly into the
shell. Examples show declarations and a handwritten equivalent of future
generated code. They do not discover anything at runtime or at build time.

The companion [Flutter SDK](../denial_flutter_sdk/README.md) provides the first
panel contract, runtime-backed service interfaces, shared theme, and input helpers.
Window/output geometry, surface hosting, and general lifecycle wiring still need
extraction. Do not introduce placeholder services or export private bridge types
to fill out the SDK.

The package is repository-local and unpublished. Version `0.0.0` is source
metadata, not a Denial release or API-stability promise. Use the SDK from the
selected Denial source revision. Signed tags remain authoritative for releases.

## Validation

Run from the repository root outside the sandbox, as required by `AGENTS.md`:

```sh
tools/denial-pc sdk-test
```

This resolves the committed SDK dependency lock using the pinned Dart toolchain,
checks formatting, analyzes the package, and runs ordinary Dart tests. It does not
build a Flutter development engine. Tests inspect annotation constants and external
types with the analyzer, including same-name contracts in different libraries and
annotations on classes that do not implement their declared contract.

The SDK lockfile makes tooling tests repeatable. Applications resolve the SDK's
normal dependencies in their own lockfile; SDK dev dependencies do not enter the
shell runtime.
