import 'dart:async';

import '../../models/input_device_capabilities.dart';
import '../../models/keyboard_configuration.dart';
import '../../models/shortcut_configuration.dart';
import '../denial_wire.dart' as wire;
import 'context.dart';
import 'control_client.dart' show DenialOutputControlException;

final class BridgeConfigurationClient {
  BridgeConfigurationClient(this._context);

  final BridgeContext _context;
  final Map<int, Completer<DenialKeyboardConfiguration>>
  _pendingKeyboardSettingsRequests = {};
  final Map<int, Completer<DenialInputDeviceCapabilities>>
  _pendingInputDeviceRequests = {};
  final Map<int, Completer<DenialShortcutConfiguration>>
  _pendingShortcutRequests = {};
  final Map<int, Completer<DenialShortcutValidation>>
  _pendingShortcutValidationRequests = {};
  final StreamController<DenialKeyboardConfiguration> _keyboardConfigurations =
      StreamController<DenialKeyboardConfiguration>.broadcast(sync: true);
  final StreamController<DenialInputDeviceCapabilities>
  _inputDeviceCapabilities =
      StreamController<DenialInputDeviceCapabilities>.broadcast(sync: true);
  final StreamController<DenialShortcutConfiguration> _shortcutConfigurations =
      StreamController<DenialShortcutConfiguration>.broadcast(sync: true);

  Future<DenialKeyboardConfiguration> readKeyboardConfiguration() async {
    if (!_context.useControlSocket) {
      return _readKeyboardConfigurationFromPlatform();
    }
    final configuration = DenialKeyboardConfiguration.fromJson(
      await _sendSettingsControlRequest('settings.keyboard.get'),
    );
    _keyboardConfigurations.add(configuration);
    return configuration;
  }

  Future<DenialInputDeviceCapabilities> readInputDeviceCapabilities() async {
    if (!_context.useControlSocket) {
      return _readInputDeviceCapabilitiesFromPlatform();
    }
    final capabilities = DenialInputDeviceCapabilities.fromJson(
      await _sendSettingsControlRequest('settings.input.get'),
    );
    _inputDeviceCapabilities.add(capabilities);
    return capabilities;
  }

  Future<DenialInputDeviceCapabilities> configureTouchpad(
    DenialInputDeviceCapabilities capabilities,
  ) async {
    if (!_context.useControlSocket) {
      return _configureTouchpadThroughPlatform(capabilities);
    }
    final applied = DenialInputDeviceCapabilities.fromJson(
      await _sendSettingsControlRequest(
        'settings.touchpad.apply',
        parameters: <String, Object>{
          'expected_revision': capabilities.revision,
          'touchpad': capabilities.toApplyJson(),
        },
      ),
    );
    _inputDeviceCapabilities.add(applied);
    return applied;
  }

  Future<DenialInputDeviceCapabilities> configureMouse(
    DenialInputDeviceCapabilities capabilities,
  ) async {
    if (!_context.useControlSocket) {
      return _configureMouseThroughPlatform(capabilities);
    }
    final applied = DenialInputDeviceCapabilities.fromJson(
      await _sendSettingsControlRequest(
        'settings.mouse.apply',
        parameters: <String, Object>{
          'expected_revision': capabilities.revision,
          'mouse': capabilities.mouseToApplyJson(),
        },
      ),
    );
    _inputDeviceCapabilities.add(applied);
    return applied;
  }

  Future<DenialKeyboardConfiguration> configureKeyboard(
    DenialKeyboardConfiguration configuration,
  ) async {
    if (!_context.useControlSocket) {
      return _configureKeyboardThroughPlatform(configuration);
    }
    final applied = DenialKeyboardConfiguration.fromJson(
      await _sendSettingsControlRequest(
        'settings.keyboard.apply',
        parameters: <String, Object>{
          'expected_revision': configuration.revision,
          'keyboard': configuration.toApplyJson(),
        },
      ),
    );
    _keyboardConfigurations.add(applied);
    return applied;
  }

  Future<DenialShortcutConfiguration> readShortcutConfiguration() async {
    if (!_context.useControlSocket) return _readShortcutsFromPlatform();
    final configuration = DenialShortcutConfiguration.fromJson(
      await _sendSettingsControlRequest('settings.shortcuts.get'),
    );
    _shortcutConfigurations.add(configuration);
    return configuration;
  }

  Future<DenialShortcutValidation> validateShortcut({
    required DenialShortcutBinding shortcut,
    String? existingShortcut,
  }) async {
    if (!_context.useControlSocket) {
      return _validateShortcutThroughPlatform(
        shortcut: shortcut,
        existingShortcut: existingShortcut,
      );
    }
    return DenialShortcutValidation.fromJson(
      await _sendSettingsControlRequest(
        'settings.shortcuts.validate',
        parameters: <String, Object>{
          'shortcut': shortcut.toJson(),
          'existing_shortcut': ?existingShortcut,
        },
      ),
    );
  }

  Future<DenialShortcutConfiguration> addShortcut({
    required int expectedRevision,
    required DenialShortcutBinding shortcut,
  }) {
    return _mutateShortcuts(
      kind: wire.SettingsRequestKind.AddShortcut,
      expectedRevision: expectedRevision,
      shortcut: shortcut,
    );
  }

  Future<DenialShortcutConfiguration> updateShortcut({
    required int expectedRevision,
    required String existingShortcut,
    required DenialShortcutBinding shortcut,
  }) {
    return _mutateShortcuts(
      kind: wire.SettingsRequestKind.UpdateShortcut,
      expectedRevision: expectedRevision,
      shortcut: shortcut,
      existingShortcut: existingShortcut,
    );
  }

  Future<DenialShortcutConfiguration> removeShortcut({
    required int expectedRevision,
    required String shortcut,
  }) {
    return _mutateShortcuts(
      kind: wire.SettingsRequestKind.RemoveShortcut,
      expectedRevision: expectedRevision,
      existingShortcut: shortcut,
    );
  }

  Future<DenialShortcutConfiguration> restoreDefaultShortcuts({
    required int expectedRevision,
  }) {
    return _mutateShortcuts(
      kind: wire.SettingsRequestKind.RestoreShortcuts,
      expectedRevision: expectedRevision,
    );
  }

  Future<DenialShortcutConfiguration> _mutateShortcuts({
    required wire.SettingsRequestKind kind,
    required int expectedRevision,
    DenialShortcutBinding? shortcut,
    String? existingShortcut,
  }) async {
    if (!_context.useControlSocket) {
      return _mutateShortcutsThroughPlatform(
        kind: kind,
        expectedRevision: expectedRevision,
        shortcut: shortcut,
        existingShortcut: existingShortcut,
      );
    }
    final method = switch (kind) {
      wire.SettingsRequestKind.AddShortcut => 'settings.shortcuts.add',
      wire.SettingsRequestKind.UpdateShortcut => 'settings.shortcuts.update',
      wire.SettingsRequestKind.RemoveShortcut => 'settings.shortcuts.remove',
      wire.SettingsRequestKind.RestoreShortcuts => 'settings.shortcuts.restore',
      _ => throw ArgumentError.value(kind, 'kind', 'invalid shortcut mutation'),
    };
    final parameters = <String, Object>{
      'expected_revision': expectedRevision,
      if (shortcut != null) 'shortcut': shortcut.toJson(),
    };
    if (existingShortcut != null) {
      parameters[kind == wire.SettingsRequestKind.RemoveShortcut
              ? 'shortcut'
              : 'existing_shortcut'] =
          existingShortcut;
    }
    final configuration = DenialShortcutConfiguration.fromJson(
      await _sendSettingsControlRequest(method, parameters: parameters),
    );
    _shortcutConfigurations.add(configuration);
    return configuration;
  }

  Future<Map<String, Object?>> _sendSettingsControlRequest(
    String method, {
    Map<String, Object>? parameters,
  }) async {
    try {
      return await _context.control.request(method, parameters: parameters);
    } on DenialOutputControlException catch (error) {
      throw StateError(error.message);
    }
  }

  Future<DenialKeyboardConfiguration> _readKeyboardConfigurationFromPlatform() {
    final requestId = _context.platform.nextRequestId();
    final completer = Completer<DenialKeyboardConfiguration>();
    _pendingKeyboardSettingsRequests[requestId] = completer;
    _context.sendWire(
      _context.codec.encodeSettingsRead(
        wire.SettingsRequestKind.ReadKeyboard,
        requestId: requestId,
      ),
    );
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingKeyboardSettingsRequests.remove(requestId);
        throw TimeoutException('Denial keyboard settings read timed out');
      },
    );
  }

  Future<DenialInputDeviceCapabilities>
  _readInputDeviceCapabilitiesFromPlatform() {
    final requestId = _context.platform.nextRequestId();
    final completer = Completer<DenialInputDeviceCapabilities>();
    _pendingInputDeviceRequests[requestId] = completer;
    _context.sendWire(
      _context.codec.encodeSettingsRead(
        wire.SettingsRequestKind.ReadInputDevices,
        requestId: requestId,
      ),
    );
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingInputDeviceRequests.remove(requestId);
        throw TimeoutException('Denial input device detection timed out');
      },
    );
  }

  Future<DenialInputDeviceCapabilities> _configureTouchpadThroughPlatform(
    DenialInputDeviceCapabilities capabilities,
  ) {
    final requestId = _context.platform.nextRequestId();
    final bytes = _context.codec.encodeTouchpadConfiguration(
      requestId: requestId,
      capabilities: capabilities,
    );
    if (bytes == null) {
      return Future<DenialInputDeviceCapabilities>.error(
        ArgumentError('invalid Denial touchpad configuration'),
      );
    }
    final completer = Completer<DenialInputDeviceCapabilities>();
    _pendingInputDeviceRequests[requestId] = completer;
    _context.sendWire(bytes);
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingInputDeviceRequests.remove(requestId);
        throw TimeoutException('Denial touchpad settings update timed out');
      },
    );
  }

  Future<DenialInputDeviceCapabilities> _configureMouseThroughPlatform(
    DenialInputDeviceCapabilities capabilities,
  ) {
    final requestId = _context.platform.nextRequestId();
    final bytes = _context.codec.encodeMouseConfiguration(
      requestId: requestId,
      capabilities: capabilities,
    );
    if (bytes == null) {
      return Future<DenialInputDeviceCapabilities>.error(
        ArgumentError('invalid Denial mouse configuration'),
      );
    }
    final completer = Completer<DenialInputDeviceCapabilities>();
    _pendingInputDeviceRequests[requestId] = completer;
    _context.sendWire(bytes);
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingInputDeviceRequests.remove(requestId);
        throw TimeoutException('Denial mouse settings update timed out');
      },
    );
  }

  Future<DenialKeyboardConfiguration> _configureKeyboardThroughPlatform(
    DenialKeyboardConfiguration configuration,
  ) {
    final requestId = _context.platform.nextRequestId();
    final bytes = _context.codec.encodeKeyboardConfiguration(
      requestId: requestId,
      configuration: configuration,
    );
    if (bytes == null) {
      return Future<DenialKeyboardConfiguration>.error(
        ArgumentError('invalid Denial keyboard configuration'),
      );
    }
    final completer = Completer<DenialKeyboardConfiguration>();
    _pendingKeyboardSettingsRequests[requestId] = completer;
    _context.sendWire(bytes);
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingKeyboardSettingsRequests.remove(requestId);
        throw TimeoutException('Denial keyboard settings update timed out');
      },
    );
  }

  Future<DenialShortcutConfiguration> _readShortcutsFromPlatform() {
    final requestId = _context.platform.nextRequestId();
    final completer = Completer<DenialShortcutConfiguration>();
    _pendingShortcutRequests[requestId] = completer;
    _context.sendWire(_context.codec.encodeShortcutRead(requestId: requestId));
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingShortcutRequests.remove(requestId);
        throw TimeoutException('Denial shortcut settings read timed out');
      },
    );
  }

  Future<DenialShortcutValidation> _validateShortcutThroughPlatform({
    required DenialShortcutBinding shortcut,
    String? existingShortcut,
  }) {
    final requestId = _context.platform.nextRequestId();
    final bytes = _context.codec.encodeShortcutValidation(
      requestId: requestId,
      shortcut: shortcut,
      existingShortcut: existingShortcut,
    );
    if (bytes == null) {
      return Future<DenialShortcutValidation>.error(
        ArgumentError('shortcut validation request exceeds wire bounds'),
      );
    }
    final completer = Completer<DenialShortcutValidation>();
    _pendingShortcutValidationRequests[requestId] = completer;
    _context.sendWire(bytes);
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingShortcutValidationRequests.remove(requestId);
        throw TimeoutException('Denial shortcut validation timed out');
      },
    );
  }

  Future<DenialShortcutConfiguration> _mutateShortcutsThroughPlatform({
    required wire.SettingsRequestKind kind,
    required int expectedRevision,
    DenialShortcutBinding? shortcut,
    String? existingShortcut,
  }) {
    final requestId = _context.platform.nextRequestId();
    final bytes = _context.codec.encodeShortcutMutation(
      kind: kind,
      requestId: requestId,
      expectedRevision: expectedRevision,
      shortcut: shortcut,
      existingShortcut: existingShortcut,
    );
    if (bytes == null) {
      return Future<DenialShortcutConfiguration>.error(
        ArgumentError('shortcut mutation request exceeds wire bounds'),
      );
    }
    final completer = Completer<DenialShortcutConfiguration>();
    _pendingShortcutRequests[requestId] = completer;
    _context.sendWire(bytes);
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingShortcutRequests.remove(requestId);
        throw TimeoutException('Denial shortcut update timed out');
      },
    );
  }

  Stream<DenialKeyboardConfiguration> get keyboardConfigurations =>
      _keyboardConfigurations.stream;

  Stream<DenialInputDeviceCapabilities> get inputDeviceCapabilities =>
      _inputDeviceCapabilities.stream;

  Stream<DenialShortcutConfiguration> get shortcutConfigurations =>
      _shortcutConfigurations.stream;
  void handleResponse(int requestId, wire.SettingsResponse response) {
    if (response.kind == wire.SettingsResponseKind.Shortcuts) {
      final configuration = _context.codec.decodeShortcutConfiguration(
        response,
      );
      final completer = _pendingShortcutRequests.remove(requestId);
      if (configuration != null && !_shortcutConfigurations.isClosed) {
        _shortcutConfigurations.add(configuration);
      }
      if (requestId == 0 || completer == null || completer.isCompleted) {
        return;
      }
      if (!response.success || configuration == null) {
        completer.completeError(
          StateError(response.error ?? 'Denial shortcut request failed'),
        );
      } else {
        completer.complete(configuration);
      }
      return;
    }

    if (response.kind == wire.SettingsResponseKind.ShortcutValidation) {
      final validation = _context.codec.decodeShortcutValidation(response);
      final completer = _pendingShortcutValidationRequests.remove(requestId);
      if (completer == null || completer.isCompleted) {
        return;
      }
      if (!response.success || validation == null) {
        completer.completeError(
          StateError(response.error ?? 'Denial shortcut validation failed'),
        );
      } else {
        completer.complete(validation);
      }
      return;
    }

    if (response.kind == wire.SettingsResponseKind.InputDevices) {
      final capabilities = _context.codec.decodeInputDeviceCapabilities(
        response,
      );
      final completer = _pendingInputDeviceRequests.remove(requestId);
      if (capabilities != null && !_inputDeviceCapabilities.isClosed) {
        _inputDeviceCapabilities.add(capabilities);
      }
      if (requestId == 0 || completer == null || completer.isCompleted) {
        return;
      }
      if (capabilities == null) {
        completer.completeError(
          StateError(response.error ?? 'Denial input device detection failed'),
        );
      } else {
        completer.complete(capabilities);
      }
      return;
    }

    if (response.kind != wire.SettingsResponseKind.Keyboard) {
      return;
    }

    final configuration = _context.codec.decodeKeyboardConfiguration(response);
    final completer = _pendingKeyboardSettingsRequests.remove(requestId);
    if (configuration != null && !_keyboardConfigurations.isClosed) {
      _keyboardConfigurations.add(configuration);
    }
    if (requestId == 0) {
      return;
    }
    if (completer == null || completer.isCompleted) {
      return;
    }
    if (!response.success || configuration == null) {
      completer.completeError(
        StateError(response.error ?? 'Denial keyboard settings request failed'),
      );
    } else {
      completer.complete(configuration);
    }
  }

  void dispose() {
    for (final pending in _pendingKeyboardSettingsRequests.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Denial bridge disposed'));
      }
    }
    _pendingKeyboardSettingsRequests.clear();
    for (final pending in _pendingInputDeviceRequests.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Denial bridge disposed'));
      }
    }
    _pendingInputDeviceRequests.clear();
    for (final pending in _pendingShortcutRequests.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Denial bridge disposed'));
      }
    }
    _pendingShortcutRequests.clear();
    for (final pending in _pendingShortcutValidationRequests.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Denial bridge disposed'));
      }
    }
    _pendingShortcutValidationRequests.clear();
    unawaited(_keyboardConfigurations.close());
    unawaited(_inputDeviceCapabilities.close());
    unawaited(_shortcutConfigurations.close());
  }
}
