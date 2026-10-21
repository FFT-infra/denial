import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_presentation.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/input.dart';

class InputLayoutPublisher extends ConsumerStatefulWidget {
  const InputLayoutPublisher({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<InputLayoutPublisher> createState() =>
      _InputLayoutPublisherState();
}

class _InputLayoutPublisherState extends ConsumerState<InputLayoutPublisher> {
  bool _scheduled = false;
  bool _forcePublish = true;

  @override
  Widget build(BuildContext context) {
    ref.watch(
      referenceShellProvider.select(
        (state) => (
          overviewVisible: state.overviewVisible,
          inputWindow: state.inputWindow,
          launchRequestId: state.launchRequest?.requestId,
          launchingObjectId: state.launchingObjectId,
          // The shade's input region does not follow its drag.
          quickSettingsActive: state.quickSettingsEngaged,
          edgePanelVisible: state.edgePanelVisible,
          edgePanelProgress: state.edgePanelDragProgress,
          edgePanelViewportScroll: state.edgePanelViewportScroll,
          lockLayerVisible: state.lockLayerVisible,
        ),
      ),
    );
    ref.watch(shellInteractionRegistryProvider);
    ref.watch(mobilePresentationTopInsetProvider);
    _schedulePublish(MediaQuery.sizeOf(context));
    return widget.child;
  }

  void _schedulePublish(Size viewSize) {
    if (_scheduled) {
      return;
    }

    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) {
        return;
      }
      ref
          .read(referenceShellProvider.notifier)
          .publishInputLayout(
            viewSize,
            ref.read(shellInteractionRegistryProvider),
            topInset: ref.read(mobilePresentationTopInsetProvider),
            force: _forcePublish,
          );
      _forcePublish = false;
    });
  }
}
