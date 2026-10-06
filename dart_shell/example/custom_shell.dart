@Plugin()
library;

import 'package:denial_sdk/composition.dart';
import 'package:denial_flutter_sdk/application.dart';
import 'package:denial_flutter_sdk/shell.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A deliberately minimal root composition using only the SDK. A production
/// shell also supplies lock UI, input layouts and window-surface presentation.
@Provides(ShellApplication)
class CustomShell implements ShellApplication {
  const CustomShell();

  @override
  Widget createShell() => const _WindowStatus();
}

Future<void> main() => runDenialShell(shell: const CustomShell().createShell());

class _WindowStatus extends ConsumerWidget {
  const _WindowStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(shellControllerProvider);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xff101010),
        child: Center(
          child: Text(
            state.locked ? 'Locked' : 'Custom Denial shell',
            style: const TextStyle(color: Color(0xffffffff)),
          ),
        ),
      ),
    );
  }
}
