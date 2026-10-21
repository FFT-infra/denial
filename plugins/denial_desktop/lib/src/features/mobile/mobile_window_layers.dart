import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_state.dart';
import 'package:denial_desktop/src/state/reference_shell_presentation.dart';

import 'package:denial_flutter_sdk/applications.dart'
    show homeGridControllerProvider;
import 'package:denial_flutter_sdk/rendering.dart' show FrostedBackdrop;
import 'package:denial_flutter_sdk/shell.dart';

import '../../launcher/home_icon_locator.dart';
import '../../widgets/launch_transition_layer.dart';
import '../../widgets/overview/overview_layer.dart';
import '../../widgets/shade/shade_progress.dart';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mobile_primary_window_stage.dart';

/// Each animated layer observes only the state it presents.
class MobilePrimaryWindowLayer extends ConsumerStatefulWidget {
  const MobilePrimaryWindowLayer({
    super.key,
    required this.overviewPresentationActive,
  });

  final ValueListenable<bool> overviewPresentationActive;

  @override
  ConsumerState<MobilePrimaryWindowLayer> createState() =>
      _MobilePrimaryWindowLayerState();
}

class _MobilePrimaryWindowLayerState
    extends ConsumerState<MobilePrimaryWindowLayer> {
  @override
  Widget build(BuildContext context) {
    final visual = ref.watch(
      referenceShellProvider.select(
        (state) => (
          window: state.primaryWindow,
          target: state.appSwitchTargetWindow,
          switching: state.gesture.horizontal,
          heroOwnsForeground:
              state.foregroundWindow != null &&
              (state.overviewVisible ||
                  state.gesture == GestureDragPhase.up ||
                  state.homeTransitionActive),
        ),
      ),
    );
    final drag = ref.read(referenceShellProvider.notifier).gestureDrag;
    final window = visual.window;
    final switchTarget = visual.switching ? visual.target : null;
    final topInset = ref.watch(mobilePresentationTopInsetProvider);
    // From home, a pill swipe slides the incoming app in over the launcher.
    if (window == null && switchTarget == null) {
      return const SizedBox.shrink();
    }
    // The shade's frosted glass hides the app completely once established.
    // Leaving the app in the scene would composite it, and everything above
    // it, for every frame the shade moves or the app draws behind it.
    final shadeOccludes = shadeFrostOccludes(context);
    return ValueListenableBuilder<bool>(
      valueListenable: widget.overviewPresentationActive,
      builder: (context, overviewActive, _) {
        // Gesture state resets on release; the hero still owns presentation
        // until its return animation has reached the normal app bounds.
        final heroOwnsForeground = visual.heroOwnsForeground || overviewActive;
        if ((window?.isLocalFlutter ?? false) && heroOwnsForeground) {
          return const SizedBox.shrink();
        }
        return ValueListenableBuilder<bool>(
          valueListenable: ref.watch(shadeCoversProvider),
          builder: (context, shadeCovers, stage) => Positioned.fill(
            child: Offstage(
              offstage: shadeOccludes && shadeCovers,
              child: stage,
            ),
          ),
          child: Padding(
            padding: EdgeInsets.only(top: topInset),
            child: MobilePrimaryWindowStage(
              currentWindow: window,
              switchTargetWindow: switchTarget,
              drag: drag,
              switching: visual.switching,
              opacity: heroOwnsForeground ? 0.0 : 1.0,
            ),
          ),
        );
      },
    );
  }
}

class MobileLaunchLayer extends ConsumerWidget {
  const MobileLaunchLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final launch = ref.watch(
      referenceShellProvider.select(
        (state) =>
            (request: state.launchRequest, window: state.launchingWindow),
      ),
    );
    final sourceItemId = launch.request?.sourceItemId;
    final icon = sourceItemId == null
        ? null
        : ref.watch(
            homeGridControllerProvider.select(
              (grid) => grid.asData?.value.apps
                  .where((app) => app.id == sourceItemId)
                  .firstOrNull
                  ?.localApp
                  ?.icon,
            ),
          );
    return LaunchTransitionLayer(
      request: launch.request,
      window: launch.window,
      icon: icon,
      locator: ref.watch(homeIconLocatorProvider),
      onCompleted: ref
          .read(referenceShellProvider.notifier)
          .completeLaunchTransition,
    );
  }
}

class MobileOverviewLayer extends ConsumerStatefulWidget {
  const MobileOverviewLayer({
    super.key,
    this.backdrop,
    required this.onPresentationChanged,
    this.onProgressChanged,
  });

  /// The scene behind recents, frosted once for its translucent cards.
  final ValueListenable<FrostedBackdrop?>? backdrop;
  final ValueChanged<bool> onPresentationChanged;
  final ValueChanged<double>? onProgressChanged;

  @override
  ConsumerState<MobileOverviewLayer> createState() =>
      _MobileOverviewLayerState();
}

class _MobileOverviewLayerState extends ConsumerState<MobileOverviewLayer> {
  @override
  Widget build(BuildContext context) {
    final overview = ref.watch(
      referenceShellProvider.select(
        (state) => (
          window: state.foregroundWindow,
          objectId: state.foregroundObjectId,
          visible: state.overviewVisible,
          homeActive: state.homeTransitionActive,
        ),
      ),
    );
    final controller = ref.read(referenceShellProvider.notifier);
    return OverviewLayer(
      windows: ref.watch(userAppWindowsProvider),
      foregroundWindow: overview.window,
      foregroundObjectId: overview.objectId,
      visible: overview.visible,
      swipe: controller.gestureDrag,
      homeTransitionActive: overview.homeActive,
      backdrop: widget.backdrop,
      homeIcons: ref.watch(homeIconLocatorProvider),
      releaseVelocity: () => controller.gestureReleaseVelocity,
      onPresentationChanged: widget.onPresentationChanged,
      onProgressChanged: widget.onProgressChanged,
      onDismissOverview: controller.closeOverview,
      onDismissWindow: controller.closeWindow,
      onFocusWindow: controller.focusWindow,
      onHomeSettled: controller.completeHomeTransition,
    );
  }
}
