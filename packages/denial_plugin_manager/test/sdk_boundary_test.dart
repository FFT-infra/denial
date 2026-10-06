import 'package:denial_plugin_manager/src/model.dart';
import 'package:denial_plugin_manager/src/sdk_boundary.dart';
import 'package:test/test.dart';

void main() {
  void validate(String source, {String package = 'example'}) =>
      validateSdkImports(
        package: package,
        path: '/workspace/example/lib/example.dart',
        source: source,
        sdkLibraryRoots: {'denial_flutter_sdk': '/workspace/sdk/lib'},
      );

  test('public high- and low-level SDK APIs are allowed', () {
    validate(
      "import 'package:denial_flutter_sdk/platform.dart';\n"
      "import 'package:denial_flutter_sdk/rendering.dart';\n"
      "export 'package:denial_sdk/composition.dart';",
    );
  });

  test('legacy runtime APIs and SDK private imports are rejected', () {
    for (final uri in [
      'package:denial_dart_shell/denial.dart',
      'package:denial_flutter_sdk/src/platform/denial_bridge.dart',
      'package:denial_sdk/src/composition/annotations.dart',
      '../../sdk/lib/src/platform/denial_bridge.dart',
    ]) {
      expect(
        () => validate("export '$uri';"),
        throwsA(isA<CompositionException>()),
      );
    }
  });

  test('conditional imports cannot bypass the SDK boundary', () {
    expect(
      () => validate(
        "import 'stub.dart' if (dart.library.ui) "
        "'package:denial_flutter_sdk/src/platform/denial_bridge.dart';",
      ),
      throwsA(isA<CompositionException>()),
    );
  });

  test('SDK implementation can reference its own private libraries', () {
    validate(
      "import 'package:denial_flutter_sdk/src/platform/denial_bridge.dart';",
      package: 'denial_flutter_sdk',
    );
  });
}
