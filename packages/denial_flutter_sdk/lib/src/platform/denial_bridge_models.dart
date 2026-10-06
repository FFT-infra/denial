import '../models/audio.dart';

enum DenialShellAction {
  applications,
  dashboard,
  overview,
  windowSwitcherNext,
  windowSwitcherPrevious,
  windowSwitcherEnd,
  clipboard,
  screenshotPrepare,
  screenshotTextureReady,
  screenshotDone,
  clientPointerPressed,
  wallpaper,
  openSettings,
  workspaceChanged,
  focusLeft,
  focusRight,
  focusUp,
  focusDown,
}

class DenialShellActionEvent {
  const DenialShellActionEvent({
    required this.action,
    required this.monitorId,
    required this.requestId,
    required this.textureId,
    required this.workspaceId,
  });

  final DenialShellAction action;
  final int? monitorId;
  final int requestId;
  final int? textureId;
  final int? workspaceId;
}

// The bridge and services share these immutable snapshots without remapping.
typedef DenialAudioState = AudioLevelState;
typedef DenialAudioStream = AppAudioStream;
typedef DenialAudioDevice = AudioOutputDevice;

class DenialBrightnessState {
  const DenialBrightnessState({
    required this.monitorId,
    required this.level,
    this.completesRead = false,
  });

  final int monitorId;
  final double level;

  /// Whether this update satisfied an explicit state read from Dart.
  ///
  /// Reconciliation reads seed controls but must not present the transient
  /// brightness HUD as though the user changed the hardware level.
  final bool completesRead;
}

class DenialSoftwareDimmingState {
  const DenialSoftwareDimmingState({
    required this.monitorId,
    required this.level,
    required this.supported,
    this.completesRead = false,
  });

  final int monitorId;
  final double level;
  final bool supported;
  final bool completesRead;
}

class DenialTextInputState {
  const DenialTextInputState({
    required this.active,
    required this.inputPanelVisible,
    required this.legacy,
    required this.contentHint,
    required this.contentPurpose,
    this.activationSerial = 0,
  });

  final bool active;
  final bool inputPanelVisible;
  final bool legacy;
  final int contentHint;
  final int contentPurpose;
  final int activationSerial;
}

class DenialSettingsDocument {
  const DenialSettingsDocument({required this.revision, required this.json});

  final int revision;
  final String json;
}
