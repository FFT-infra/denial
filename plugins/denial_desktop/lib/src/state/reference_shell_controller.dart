import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/lifecycle.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/state.dart';

import 'reference_shell_state.dart';
import 'input_deck.dart';
import 'reference_shell_metrics.dart';
import 'reference_shell_profile.dart';
import 'reference_input_layout_coordinator.dart';

final referenceShellProvider =
    NotifierProvider<ReferenceShellController, ReferenceShellState>(
      ReferenceShellController.new,
    );

/// Owns the reference desktop/mobile presentation over the shared native state.
/// It never registers another native window callback or creates another bridge.
class ReferenceShellController extends Notifier<ReferenceShellState>
    with NotifierLifecycle<ReferenceShellState> {
  late ShellController _platform;

  /// The bottom gesture's visual drag, axis-locked. It changes on every frame
  /// of a swipe, so the layers it moves listen to it directly and the shell
  /// state carries only its [ReferenceShellState.gesture] phase.
  ValueListenable<Offset> get gestureDrag => _gestureDrag;
  final _gestureDrag = ValueNotifier(Offset.zero);

  @override
  ReferenceShellState get state => super.state;

  /// The shade's position under the finger, from 0 closed to 1 open, while
  /// [ReferenceShellState.quickSettingsDragActive]. The shell state carries
  /// only [ReferenceShellState.quickSettingsDragged].
  ValueListenable<double> get quickSettingsDrag => _quickSettingsDrag;
  final _quickSettingsDrag = ValueNotifier(0.0);

  @override
  set state(ReferenceShellState value) {
    final previousForeground = stateOrNull?.foregroundObjectId;
    super.state = value;
    _minimizeLeftApp(previousForeground, value);
    // However a transition ends the gesture, an idle phase has no drag. The
    // drag follows the state, as its moving layers expect.
    if (value.gesture == GestureDragPhase.idle) {
      _gestureDrag.value = Offset.zero;
    }
    if (!value.quickSettingsDragged) {
      _quickSettingsDrag.value = 0.0;
    }
  }

  /// On the phone, an app the user left, by going home or for another app,
  /// is minimized: Denial suspends it, stops its frames and keeps showing its
  /// last one. Recents alone leaves the app in front, as does the lock
  /// screen; focusing it again restores it.
  void _minimizeLeftApp(int? previous, ReferenceShellState next) {
    if (!_automaticSoftwareKeyboard ||
        previous == null ||
        previous == next.foregroundObjectId) {
      return;
    }
    final window = next.openAppWindowsByObjectId[previous];
    if (window == null || window.minimized) return;
    _bridge.minimizeWindow(window);
  }

  @override
  ReferenceShellState build() {
    _bridge = ref.watch(denialBridgeProvider);
    final platform = ref.read(shellControllerProvider);
    _platform = ref.read(shellControllerProvider.notifier);
    _resetBuildFields();
    _automaticSoftwareKeyboard =
        ref.watch(referenceShellProfileProvider) ==
        ReferenceShellProfile.mobile;
    _buildGeneration = beginBuildGeneration();
    final generation = _buildGeneration;
    ref.listen<bool>(
      inputDeckProvider.select((deck) => deck.activeOutput != null),
      (_, active) {
        if (active && !state.locked) closeEdgePanel();
      },
    );
    ref.listen<ShellState>(shellControllerProvider, (_, next) {
      if (isBuildGenerationActive(generation)) _synchronizePlatform(next);
    });
    _textInputStateSubscription = _bridge.textInputStates.listen((input) {
      if (isBuildGenerationActive(generation)) _handleTextInputState(input);
    });
    ref.onDispose(() {
      _automaticSoftwareKeyboardCloseTimer?.cancel();
      _automaticSoftwareKeyboardCloseTimer = null;
      _launchRequestTimer?.cancel();
      _launchRequestTimer = null;
      _appSwitchOrderTimer?.cancel();
      _appSwitchOrderTimer = null;
      unawaited(_textInputStateSubscription?.cancel());
      _textInputStateSubscription = null;
    });
    return ReferenceShellState.initial(platform);
  }

  // Large enough that the vertical swipe tracks the finger across the whole
  // screen (the home/recents hero needs the real travel, not a capped value).
  static const double _gestureVisualDistance = 1600.0;
  static const double _gestureHorizontalVisualDistance = 4096.0;
  static const double _gestureAxisLockDistance = 14.0;
  static const double _gestureAxisLockRatio = 1.18;
  static const double _quickSettingsOpenDistance = 126.0;
  static const double _quickSettingsFlickVelocity = 520.0;
  static const double _edgePanelFlickVelocity = 520.0;
  static const Duration _launchRequestTimeout = Duration(seconds: 15);

  /// How long a quick-switch order outlives its last switch, as on Android.
  static const Duration _appSwitchOrderHold = Duration(seconds: 5);
  static const Duration _automaticSoftwareKeyboardCloseGrace = Duration(
    milliseconds: 24,
  );

  late DenialBridge _bridge;
  late int _buildGeneration;
  late ReferenceInputLayoutCoordinator _inputLayoutCoordinator;
  Offset _rawGestureDrag = Offset.zero;
  Offset _gestureLockOrigin = Offset.zero;
  _GestureAxis _gestureAxis = _GestureAxis.undecided;
  bool _quickSettingsDragStartedOpen = false;
  bool _quickSettingsDragMoved = false;
  double _quickSettingsReleaseVelocity = 0;

  /// Vertical velocity, in logical pixels per second, with which the last
  /// open or close of the shade was released; zero when nothing was flung.
  /// The shade continues its settle spring from it.
  double get quickSettingsReleaseVelocity => _quickSettingsReleaseVelocity;
  double _gestureReleaseVelocity = 0;

  /// Vertical velocity, in logical pixels per second, with which the bottom
  /// gesture last opened recents or was cancelled; zero for other changes.
  /// Recents continues its settle spring from it.
  double get gestureReleaseVelocity => _gestureReleaseVelocity;
  bool _edgePanelDragStartedOpen = false;
  bool _edgePanelDragMoved = false;
  int? _edgePanelDismissalSerial;
  DenialTextInputState? _lastTextInput;
  int _nextLaunchRequestId = 1;
  Timer? _launchRequestTimer;
  Timer? _appSwitchOrderTimer;
  bool _automaticSoftwareKeyboard = false;
  final Set<String> _legacyTextInputAppIds = <String>{};
  final Set<String> _backgroundLaunchAppIds = <String>{};
  Timer? _automaticSoftwareKeyboardCloseTimer;
  StreamSubscription<DenialTextInputState>? _textInputStateSubscription;

  void _resetBuildFields() {
    _lastTextInput = null;
    _edgePanelDismissalSerial = null;
    _automaticSoftwareKeyboardCloseTimer?.cancel();
    _automaticSoftwareKeyboardCloseTimer = null;
    unawaited(_textInputStateSubscription?.cancel());
    _textInputStateSubscription = null;
    _inputLayoutCoordinator = ReferenceInputLayoutCoordinator(_bridge);
    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    _quickSettingsDragStartedOpen = false;
    _quickSettingsDragMoved = false;
    _edgePanelDragStartedOpen = false;
    _edgePanelDragMoved = false;
    _nextLaunchRequestId = 1;
    _launchRequestTimer = null;
    _appSwitchOrderTimer?.cancel();
    _appSwitchOrderTimer = null;
    _legacyTextInputAppIds.clear();
    _backgroundLaunchAppIds.clear();
  }

  void _handleTextInputState(DenialTextInputState input) {
    _lastTextInput = input;
    if (!_automaticSoftwareKeyboard) {
      return;
    }
    if (input.inputPanelVisible) {
      final foregroundAppId = AppLaunchRequest.normalizeAppId(
        state.foregroundWindow?.appId ?? '',
      );
      if (input.legacy && !_legacyTextInputAppIds.contains(foregroundAppId)) {
        closeEdgePanel();
        return;
      }
      _automaticSoftwareKeyboardCloseTimer?.cancel();
      _automaticSoftwareKeyboardCloseTimer = null;
      openEdgePanel();
    } else {
      // Flutter retires the old TextInputClient just before registering the
      // next one during a field-to-field focus transfer. Preserve the panel
      // across that short protocol gap; a replacement editor cancels this
      // close before any visible keyboard motion begins.
      _automaticSoftwareKeyboardCloseTimer?.cancel();
      final generation = _buildGeneration;
      _automaticSoftwareKeyboardCloseTimer = Timer(
        _automaticSoftwareKeyboardCloseGrace,
        () {
          _automaticSoftwareKeyboardCloseTimer = null;
          if (isBuildGenerationActive(generation)) {
            closeEdgePanel();
          }
        },
      );
    }
  }

  void registerLegacyTextInputAppIds(Iterable<String> appIds) {
    _legacyTextInputAppIds.addAll(
      appIds
          .map(AppLaunchRequest.normalizeAppId)
          .where((identity) => identity.isNotEmpty),
    );
  }

  void lock() {
    _platform.lock();
  }

  /// Secures the session first, then asks the compositor to blank its outputs.
  /// Both commands use Denial's native channels; no external power daemon is
  /// involved.
  void lockAndBlankDisplays() {
    _platform.lockAndBlankDisplays();
  }

  void requestUnlock() {
    _platform.requestUnlock();
  }

  void completeUnlockTransition() {
    if (state.locked || !state.lockLayerVisible) {
      return;
    }

    _inputLayoutCoordinator.invalidate();
    state = state.copyWith(lockLayerVisible: false);
  }

  void _resetSecurePresentation() {
    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    _quickSettingsDragStartedOpen = false;
    _quickSettingsDragMoved = false;
    _edgePanelDragStartedOpen = false;
    _edgePanelDragMoved = false;
    _launchRequestTimer?.cancel();
    _launchRequestTimer = null;
    _appSwitchOrderTimer?.cancel();
    _appSwitchOrderTimer = null;

    state = state.copyWith(
      lockLayerVisible: true,
      appSwitchOrder: const <int>[],
      overviewVisible: false,
      gesture: GestureDragPhase.idle,
      quickSettingsVisible: false,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
      edgePanelViewportScroll: 0.0,
      homeTransitionActive: false,
      clearLaunchingObjectId: true,
      clearLaunchRequest: true,
    );
  }

  void _synchronizePlatform(ShellState platform) {
    final previous = state.platform;
    final windowsChanged =
        !identical(previous.windows, platform.windows) ||
        !identical(previous.layerSurfaces, platform.layerSurfaces);
    state = state.copyWith(platform: platform);
    if (previous.locked != platform.locked) _resetSecurePresentation();
    if (windowsChanged) _reconcileWindowSnapshot();
    if (previous.activationRevision != platform.activationRevision) {
      final window = platform.foregroundWindow;
      if (window != null) _handleNativeWindowActivated(window.windowId);
    }
  }

  void _reconcileWindowSnapshot() {
    if (!_appSwitchOrderMatchesOpenApps()) _releaseAppSwitchOrder();
    final request = state.launchRequest;
    final launchWindow = request == null
        ? null
        : _matchingLaunchWindow(state.windows, request);
    if (launchWindow != null) {
      final shouldActivate = state.launchingObjectId != launchWindow.objectId;
      _rawGestureDrag = Offset.zero;
      _gestureLockOrigin = Offset.zero;
      _gestureAxis = _GestureAxis.undecided;
      state = state.copyWith(
        overviewVisible: false,
        gesture: GestureDragPhase.idle,
        quickSettingsDragActive: false,
        edgePanelVisible: false,
        edgePanelDrag: Offset.zero,
        edgePanelDragActive: false,
        foregroundObjectId: launchWindow.objectId,
        launchingObjectId: launchWindow.objectId,
      );
      if (shouldActivate) _platform.focusWindow(launchWindow);
      return;
    }
    state = state.copyWith(
      clearForegroundObjectId:
          state.windowByObjectId(state.foregroundObjectId) == null,
      clearLaunchingObjectId:
          state.windowByObjectId(state.launchingObjectId) == null,
    );
  }

  DenialWindow? _matchingLaunchWindow(
    List<DenialWindow> windows,
    AppLaunchRequest request,
  ) {
    final boundObjectId = state.launchingObjectId;
    if (boundObjectId != null) {
      for (final window in windows) {
        if (window.objectId == boundObjectId && request.matchesWindow(window)) {
          return window;
        }
      }
    }

    for (final window in windows) {
      if (request.matchesWindow(window)) {
        return window;
      }
    }
    return null;
  }

  int? beginAppLaunch({
    required String appName,
    required String? iconPath,
    required Iterable<String> expectedAppIds,
    Rect? sourceRect,
    String? sourceItemId,
  }) {
    return _beginLauncherTransition(
      appName: appName,
      iconPath: iconPath,
      expectedAppIds: expectedAppIds,
      sourceRect: sourceRect,
      sourceItemId: sourceItemId,
    );
  }

  /// Focuses an already-open application through the same coherent launcher
  /// transition used for a newly-created application window.
  int? activateAppFromLauncher({
    required DenialWindow window,
    required String appName,
    required String? iconPath,
    Rect? sourceRect,
    String? sourceItemId,
  }) {
    if (!window.isUserApp) {
      return null;
    }
    return _beginLauncherTransition(
      appName: appName,
      iconPath: iconPath,
      expectedAppIds: <String>[window.appId],
      targetWindow: window,
      sourceRect: sourceRect,
      sourceItemId: sourceItemId,
    );
  }

  int? _beginLauncherTransition({
    required String appName,
    required String? iconPath,
    required Iterable<String> expectedAppIds,
    DenialWindow? targetWindow,
    Rect? sourceRect,
    String? sourceItemId,
  }) {
    if (state.lockLayerVisible || state.launchRequest != null) {
      return null;
    }

    final requestId = _nextLaunchRequestId++;
    final request = AppLaunchRequest(
      requestId: requestId,
      appName: appName,
      iconPath: iconPath,
      expectedAppIds: expectedAppIds,
      existingObjectIds: state.openAppWindows.map((window) => window.objectId),
      targetObjectId: targetWindow?.objectId,
      sourceRect: sourceRect,
      sourceItemId: sourceItemId,
    );

    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    _releaseAppSwitchOrder();
    _launchRequestTimer?.cancel();
    final generation = _buildGeneration;
    _launchRequestTimer = Timer(_launchRequestTimeout, () {
      if (isBuildGenerationActive(generation)) {
        failAppLaunch(requestId);
      }
    });

    state = state.copyWith(
      launchRequest: request,
      foregroundObjectId: targetWindow?.objectId,
      launchingObjectId: targetWindow?.objectId,
      clearLaunchingObjectId: targetWindow == null,
      overviewVisible: false,
      gesture: GestureDragPhase.idle,
      quickSettingsVisible: false,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
      homeTransitionActive: false,
    );
    if (targetWindow != null) {
      _backgroundLaunchAppIds.remove(
        AppLaunchRequest.normalizeAppId(targetWindow.appId),
      );
      _platform.focusWindow(targetWindow);
    }
    return requestId;
  }

  void failAppLaunch(int requestId) {
    if (state.launchRequest?.requestId != requestId) {
      return;
    }
    _launchRequestTimer?.cancel();
    _launchRequestTimer = null;
    state = state.copyWith(
      clearLaunchRequest: true,
      clearLaunchingObjectId: true,
    );
  }

  void openOverview({double releaseVelocity = 0}) {
    _releaseAppSwitchOrder();
    if (!state.overviewVisible) {
      _gestureReleaseVelocity = releaseVelocity;
      _rawGestureDrag = Offset.zero;
      _gestureLockOrigin = Offset.zero;
      _gestureAxis = _GestureAxis.undecided;
      state = state.copyWith(
        overviewVisible: true,
        homeTransitionActive: false,
        gesture: GestureDragPhase.idle,
        quickSettingsVisible: false,
        quickSettingsDragged: false,
        quickSettingsDragActive: false,
        edgePanelVisible: false,
        edgePanelDrag: Offset.zero,
        edgePanelDragActive: false,
      );
    }
  }

  /// Begins the transition home. The fullscreen primary stage is hidden via
  /// [ReferenceShellState.homeTransitionActive] while the overview layer
  /// shrinks the app into its home icon, continuing [releaseVelocity] (logical
  /// pixels per second, negative upward), then calls [completeHomeTransition].
  /// A launch still in progress shrinks back into its icon instead.
  void goHome({double releaseVelocity = 0}) {
    if (state.homeTransitionActive) {
      return;
    }
    _gestureReleaseVelocity = releaseVelocity;
    _releaseAppSwitchOrder();
    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    final launchRequest = state.launchRequest;
    if (launchRequest != null) {
      _launchRequestTimer?.cancel();
      _launchRequestTimer = null;
      _backgroundLaunchAppIds.addAll(launchRequest.expectedAppIds);
      state = state.copyWith(
        clearLaunchRequest: true,
        clearLaunchingObjectId: true,
        clearForegroundObjectId: true,
        homeTransitionActive: false,
        overviewVisible: false,
        gesture: GestureDragPhase.idle,
        quickSettingsVisible: false,
        quickSettingsDragged: false,
        quickSettingsDragActive: false,
        edgePanelVisible: false,
        edgePanelDrag: Offset.zero,
        edgePanelDragActive: false,
      );
      return;
    }
    // Clear the foreground now so home shows immediately beneath the flying
    // thumbnail; the overview layer keeps the app texture for the fly-away.
    state = state.copyWith(
      homeTransitionActive: true,
      overviewVisible: false,
      gesture: GestureDragPhase.idle,
      quickSettingsVisible: false,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
      clearForegroundObjectId: true,
    );
  }

  void completeHomeTransition() {
    if (!state.homeTransitionActive) {
      return;
    }
    state = state.copyWith(homeTransitionActive: false);
  }

  void closeOverview() {
    if (state.overviewVisible) {
      _rawGestureDrag = Offset.zero;
      _gestureLockOrigin = Offset.zero;
      _gestureAxis = _GestureAxis.undecided;
      state = state.copyWith(
        overviewVisible: false,
        gesture: GestureDragPhase.idle,
        quickSettingsDragActive: false,
        edgePanelVisible: false,
        edgePanelDrag: Offset.zero,
        edgePanelDragActive: false,
        clearForegroundObjectId: true,
      );
    }
  }

  /// Performs the system Back action on [ReferenceShellState.backTarget].
  /// Returns false when nothing can go back.
  bool navigateBack() {
    switch (state.backTarget) {
      case MobileBackTarget.none:
        return false;
      case MobileBackTarget.keyboard:
        // A user dismissal, as when the keyboard is dragged closed: the
        // application learns its editor's panel was dismissed.
        final input = _lastTextInput;
        if (input != null && input.active) {
          _bridge.dismissKeyboardPanel(input.activationSerial);
        }
        closeEdgePanel();
      case MobileBackTarget.shade:
        closeQuickSettings();
      case MobileBackTarget.overview:
        closeOverview();
      case MobileBackTarget.app:
        final window = state.primaryWindow;
        if (window == null) return false;
        _platform.navigateBack(window);
    }
    return true;
  }

  void closeWindow(DenialWindow window) {
    if (state.overviewVisible && state.openAppWindowCount <= 1) {
      closeOverview();
    }
    _platform.closeWindow(window);
  }

  void focusWindow(DenialWindow window) {
    if (!window.isUserApp) {
      return;
    }

    _backgroundLaunchAppIds.remove(
      AppLaunchRequest.normalizeAppId(window.appId),
    );
    _releaseAppSwitchOrder();
    _activateWindowInShell(window);
    _platform.focusWindow(window);
  }

  /// Mirrors the compositor dropping keyboard focus after this window is
  /// minimized. A later native activation remains authoritative.
  void releaseWindowFocus(DenialWindow window) {
    _platform.releaseWindowFocus(window);
    if (state.foregroundObjectId != window.objectId) {
      return;
    }
    state = state.copyWith(clearForegroundObjectId: true);
  }

  void _activateWindowInShell(DenialWindow window) {
    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    state = state.copyWith(
      foregroundObjectId: window.objectId,
      homeTransitionActive: false,
      overviewVisible: false,
      gesture: GestureDragPhase.idle,
      quickSettingsVisible: false,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
    );
  }

  void _handleNativeWindowActivated(int windowId) {
    // Closing the native focused window can activate its neighbor. Recents
    // keeps ownership of presentation until the user selects a card or leaves;
    // an automatic focus fallback must not interrupt the removal reflow.
    if (state.overviewVisible) {
      return;
    }
    for (final window in state.windows) {
      if (window.windowId == windowId && window.isUserApp) {
        final appId = AppLaunchRequest.normalizeAppId(window.appId);
        if (_backgroundLaunchAppIds.remove(appId)) {
          return;
        }
        // Activation of the switch target confirms it; any other app
        // taking focus ends the switch sequence.
        if (window.objectId != state.foregroundObjectId) {
          _releaseAppSwitchOrder();
        }
        _activateWindowInShell(window);
        return;
      }
    }
  }

  void switchAdjacentWindow(int direction) {
    completeAdjacentWindowSwitch(direction);
  }

  void completeAdjacentWindowSwitch(int direction) {
    final target = state.adjacentOpenAppWindow(direction);
    if (target == null) {
      resetGestureDrag();
      return;
    }

    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    state = state.copyWith(
      // Freeze the order at the first switch; raising each target must not
      // reorder the apps the user is stepping through.
      appSwitchOrder: state.appSwitchOrder.isEmpty
          ? <int>[for (final window in state.openAppWindows) window.objectId]
          : null,
      foregroundObjectId: target.objectId,
      overviewVisible: false,
      gesture: GestureDragPhase.idle,
      quickSettingsVisible: false,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
      clearLaunchingObjectId: true,
    );
    _holdAppSwitchOrder();
    _platform.focusWindow(target);
  }

  /// Keeps the frozen order while switches follow one another. Input to the
  /// app does not pass through the shell, so only a quiet period ends the
  /// sequence; the current app then counts as the most recent.
  void _holdAppSwitchOrder() {
    _appSwitchOrderTimer?.cancel();
    final generation = _buildGeneration;
    _appSwitchOrderTimer = Timer(_appSwitchOrderHold, () {
      _appSwitchOrderTimer = null;
      if (!isBuildGenerationActive(generation)) return;
      // A swipe in progress keeps the order its target came from.
      if (state.gesture != GestureDragPhase.idle) {
        _holdAppSwitchOrder();
      } else {
        _releaseAppSwitchOrder();
      }
    });
  }

  void _releaseAppSwitchOrder() {
    _appSwitchOrderTimer?.cancel();
    _appSwitchOrderTimer = null;
    if (state.appSwitchOrder.isNotEmpty) {
      state = state.copyWith(appSwitchOrder: const <int>[]);
    }
  }

  bool _appSwitchOrderMatchesOpenApps() {
    final order = state.appSwitchOrder;
    final open = state.openAppWindowsByObjectId;
    return order.length == open.length && order.every(open.containsKey);
  }

  void completeLaunchTransition(int requestId, int objectId) {
    if (state.launchRequest?.requestId != requestId ||
        state.launchingObjectId != objectId) {
      return;
    }

    _launchRequestTimer?.cancel();
    _launchRequestTimer = null;
    state = state.copyWith(
      clearLaunchRequest: true,
      clearLaunchingObjectId: true,
    );
  }

  void updateGestureDrag(Offset delta) {
    if (delta == Offset.zero) {
      return;
    }

    _rawGestureDrag += delta;
    _lockGestureAxis();
    _moveGesture(_visualGestureDrag(_rawGestureDrag));
  }

  void resetGestureDrag({double releaseVelocity = 0}) {
    _gestureReleaseVelocity = releaseVelocity;
    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    _moveGesture(Offset.zero);
  }

  void setGestureDragForAnimation(Offset drag) {
    _rawGestureDrag = drag;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.horizontal;
    _moveGesture(_visualGestureDrag(_rawGestureDrag));
  }

  /// Commits a phase change to the state before moving the layers, so a
  /// layer that a new phase mounts starts from the new drag.
  void _moveGesture(Offset visualDrag) {
    final phase = GestureDragPhase.of(visualDrag);
    if (phase != state.gesture) {
      state = state.copyWith(gesture: phase);
    }
    _gestureDrag.value = visualDrag;
  }

  void openQuickSettings({double releaseVelocity = 0}) {
    if (state.quickSettingsVisible &&
        !state.quickSettingsDragged &&
        !state.quickSettingsDragActive) {
      return;
    }

    _quickSettingsReleaseVelocity = releaseVelocity;
    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    state = state.copyWith(
      quickSettingsVisible: true,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
      overviewVisible: false,
      gesture: GestureDragPhase.idle,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
    );
  }

  void closeQuickSettings({double releaseVelocity = 0}) {
    if (!state.quickSettingsVisible &&
        !state.quickSettingsDragged &&
        !state.quickSettingsDragActive) {
      return;
    }

    _quickSettingsReleaseVelocity = releaseVelocity;
    state = state.copyWith(
      quickSettingsVisible: false,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
    );
  }

  void startQuickSettingsDrag({double? progress}) {
    // A drag can interrupt the settling spring. Continue from the painted
    // position supplied by the shade rather than jumping to its target state.
    final initialProgress =
        (progress ??
                (state.quickSettingsVisible ? 1.0 : _quickSettingsDrag.value))
            .clamp(0.0, 1.0)
            .toDouble();
    _quickSettingsDragStartedOpen = initialProgress >= 1.0;
    _quickSettingsDragMoved = false;
    // The shade follows the drag from its first frame.
    _quickSettingsDrag.value = initialProgress;
    state = state.copyWith(
      quickSettingsDragged: initialProgress > 0.0,
      quickSettingsVisible: false,
      quickSettingsDragActive: true,
    );
  }

  void updateQuickSettingsDrag(Offset delta) {
    if (delta == Offset.zero) {
      return;
    }

    _quickSettingsDragMoved = true;
    const distance = ReferenceShellMetrics.quickSettingsDragDistance;
    final current = state.quickSettingsVisible
        ? distance
        : _quickSettingsDrag.value * distance;
    final dy = (current + delta.dy).clamp(0.0, distance).toDouble();
    if (dy == current && !state.quickSettingsVisible) {
      return;
    }

    _quickSettingsDrag.value = dy / distance;
    // The shell state changes only when the drag takes over or crosses
    // closed, never on every frame of it.
    final dragged = dy > 0.0;
    final shell = state;
    if (shell.quickSettingsVisible ||
        shell.quickSettingsDragged != dragged ||
        !shell.quickSettingsDragActive ||
        shell.overviewVisible ||
        shell.gesture != GestureDragPhase.idle ||
        shell.edgePanelVisible ||
        shell.edgePanelDrag != Offset.zero ||
        shell.edgePanelDragActive) {
      state = shell.copyWith(
        quickSettingsVisible: false,
        quickSettingsDragged: dragged,
        quickSettingsDragActive: true,
        overviewVisible: false,
        gesture: GestureDragPhase.idle,
        edgePanelVisible: false,
        edgePanelDrag: Offset.zero,
        edgePanelDragActive: false,
      );
    }
  }

  void endQuickSettingsDrag(double velocity) {
    final drag = state.quickSettingsVisible && !_quickSettingsDragMoved
        ? ReferenceShellMetrics.quickSettingsDragDistance
        : _quickSettingsDrag.value *
              ReferenceShellMetrics.quickSettingsDragDistance;
    final flickOpen = velocity >= _quickSettingsFlickVelocity;
    final flickClose = velocity <= -_quickSettingsFlickVelocity;
    final shouldOpen =
        !flickClose &&
        ((_quickSettingsDragStartedOpen && !_quickSettingsDragMoved) ||
            drag >= _quickSettingsOpenDistance ||
            flickOpen);
    _quickSettingsDragStartedOpen = false;
    _quickSettingsDragMoved = false;
    if (shouldOpen) {
      openQuickSettings(releaseVelocity: velocity);
    } else {
      closeQuickSettings(releaseVelocity: velocity);
    }
  }

  void openEdgePanel() {
    if (!state.locked && ref.read(inputDeckProvider).activeOutput != null) {
      return;
    }
    if (state.edgePanelVisible &&
        state.edgePanelDrag == Offset.zero &&
        !state.edgePanelDragActive) {
      return;
    }

    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    state = state.copyWith(
      edgePanelVisible: true,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
      overviewVisible: false,
      gesture: GestureDragPhase.idle,
      quickSettingsVisible: false,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
    );
  }

  void closeEdgePanel() {
    if (!state.edgePanelVisible &&
        state.edgePanelDrag == Offset.zero &&
        !state.edgePanelDragActive) {
      return;
    }

    state = state.copyWith(
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
    );
  }

  void updateEdgePanelViewportScroll(double delta, double maxScroll) {
    if (!state.edgePanelVisible || delta == 0.0 || maxScroll <= 0.0) {
      return;
    }

    final next = (state.edgePanelViewportScroll + delta)
        .clamp(0.0, maxScroll)
        .toDouble();
    if (next == state.edgePanelViewportScroll) {
      return;
    }

    state = state.copyWith(edgePanelViewportScroll: next);
  }

  void startEdgePanelDrag() {
    _edgePanelDismissalSerial = _lastTextInput?.active == true
        ? _lastTextInput!.activationSerial
        : null;
    _edgePanelDragStartedOpen =
        state.edgePanelVisible || state.edgePanelDragProgress >= 1.0;
    _edgePanelDragMoved = false;
    state = state.copyWith(
      edgePanelDrag: Offset.zero,
      edgePanelVisible: state.edgePanelVisible,
      edgePanelDragActive: true,
    );
  }

  void updateEdgePanelDrag(Offset delta) {
    if (delta == Offset.zero) {
      return;
    }

    _edgePanelDragMoved = true;
    final current = state.edgePanelVisible
        ? ReferenceShellMetrics.edgePanelDragDistance
        : state.edgePanelDrag.dy;
    final dy = (current - delta.dy)
        .clamp(0.0, ReferenceShellMetrics.edgePanelDragDistance)
        .toDouble();
    if (dy == state.edgePanelDrag.dy) {
      return;
    }

    state = state.copyWith(
      edgePanelVisible: false,
      edgePanelDrag: Offset(0.0, dy),
      edgePanelDragActive: true,
      overviewVisible: false,
      gesture: GestureDragPhase.idle,
      quickSettingsVisible: false,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
    );
  }

  void endEdgePanelDrag(double velocity) {
    final drag = state.edgePanelVisible && !_edgePanelDragMoved
        ? ReferenceShellMetrics.edgePanelDragDistance
        : state.edgePanelDrag.dy;
    final flickOpen = velocity <= -_edgePanelFlickVelocity;
    final flickClose = velocity >= _edgePanelFlickVelocity;
    final shouldOpen =
        !flickClose &&
        ((_edgePanelDragStartedOpen && !_edgePanelDragMoved) ||
            drag >= ReferenceShellMetrics.edgePanelOpenDistance ||
            flickOpen);
    // Only a completed user dismissal sends feedback. Automatic hides and
    // animation frames must not ask the application to dismiss another editor.
    if (!shouldOpen &&
        _edgePanelDragStartedOpen &&
        _edgePanelDismissalSerial != null) {
      _bridge.dismissKeyboardPanel(_edgePanelDismissalSerial!);
    }
    _edgePanelDismissalSerial = null;
    _edgePanelDragStartedOpen = false;
    _edgePanelDragMoved = false;
    if (shouldOpen) {
      openEdgePanel();
    } else {
      closeEdgePanel();
    }
  }

  Offset _visualGestureDrag(Offset rawDrag) {
    return switch (_gestureAxis) {
      _GestureAxis.horizontal => Offset(
        (rawDrag.dx - _gestureLockOrigin.dx)
            .clamp(
              -_gestureHorizontalVisualDistance,
              _gestureHorizontalVisualDistance,
            )
            .toDouble(),
        0.0,
      ),
      _GestureAxis.vertical => Offset(
        0.0,
        rawDrag.dy
            .clamp(-_gestureVisualDistance, _gestureVisualDistance)
            .toDouble(),
      ),
      _GestureAxis.undecided => Offset.zero,
    };
  }

  void _lockGestureAxis() {
    if (_gestureAxis != _GestureAxis.undecided) {
      return;
    }

    if (state.overviewVisible) {
      _gestureAxis = _GestureAxis.vertical;
      return;
    }

    final dx = _rawGestureDrag.dx.abs();
    final dy = _rawGestureDrag.dy.abs();
    if (dx < _gestureAxisLockDistance && dy < _gestureAxisLockDistance) {
      return;
    }

    if (dx > dy * _gestureAxisLockRatio) {
      _gestureAxis = _GestureAxis.horizontal;
      _gestureLockOrigin = _rawGestureDrag;
    } else if (dy > dx * _gestureAxisLockRatio) {
      _gestureAxis = _GestureAxis.vertical;
    }
  }

  void publishInputLayout(
    Size viewSize,
    ShellInteractionSnapshot interactions, {
    double topInset = 0.0,
    bool force = false,
  }) {
    if (force) _inputLayoutCoordinator.invalidate();
    _inputLayoutCoordinator.publish(
      state: state,
      viewSize: viewSize,
      interactions: interactions,
      topInset: topInset,
    );
  }
}

enum _GestureAxis { undecided, horizontal, vertical }
