import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../core/utf8_size.dart';
import '../denial_bridge_models.dart';
import '../system_control_protocol.dart';
import 'context.dart';

final class BridgeBrightnessClient {
  BridgeBrightnessClient(this._context);

  final BridgeContext _context;
  static const String _brightnessChannel = 'denial/brightness';
  static const String _softwareDimmingChannel = 'denial/software_dimming';
  final Map<int, Set<Completer<double?>>> _pendingBrightnessReads = {};
  final Map<int, Set<Completer<double?>>> _pendingSoftwareDimmingReads = {};
  final StreamController<DenialBrightnessState> _brightnessStates =
      StreamController<DenialBrightnessState>.broadcast(sync: true);
  final StreamController<DenialSoftwareDimmingState> _softwareDimmingStates =
      StreamController<DenialSoftwareDimmingState>.broadcast(sync: true);
  bool requestBrightness({required int monitorId, required String connector}) {
    if (!_validBrightnessTarget(monitorId, connector)) return false;
    unawaited(readBrightnessLevel(monitorId: monitorId, connector: connector));
    return true;
  }

  Future<double?> readBrightnessLevel({
    required int monitorId,
    required String connector,
  }) async {
    if (!_validBrightnessTarget(monitorId, connector)) return null;
    if (!_context.useControlSocket) {
      return _readBrightnessLevelFromPlatform(
        monitorId: monitorId,
        connector: connector,
      );
    }
    try {
      final result = await _context.control.request(
        'brightness.get',
        parameters: <String, Object>{
          'monitor_id': monitorId,
          'connector': connector,
        },
      );
      final returnedMonitor = result['monitor_id'];
      final value = result['level'];
      if (returnedMonitor is! int || value is! num) return null;
      final level = value.toDouble().clamp(0.0, 1.0);
      if (!_brightnessStates.isClosed) {
        _brightnessStates.add(
          DenialBrightnessState(
            monitorId: returnedMonitor,
            level: level,
            completesRead: true,
          ),
        );
      }
      return level;
    } on Object {
      return _readBrightnessLevelFromPlatform(
        monitorId: monitorId,
        connector: connector,
      );
    }
  }

  Future<double?> _readBrightnessLevelFromPlatform({
    required int monitorId,
    required String connector,
  }) {
    final completer = Completer<double?>();
    final pending = _pendingBrightnessReads.putIfAbsent(
      monitorId,
      () => <Completer<double?>>{},
    );
    pending.add(completer);
    _sendBrightnessPlatformRequest(
      command: 0,
      monitorId: monitorId,
      connector: connector,
      percent: 0,
    );
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        final current = _pendingBrightnessReads[monitorId];
        current?.remove(completer);
        if (current?.isEmpty ?? false) {
          _pendingBrightnessReads.remove(monitorId);
        }
        return null;
      },
    );
  }

  bool setBrightness({
    required int monitorId,
    required String connector,
    required double level,
  }) {
    if (!_validBrightnessTarget(monitorId, connector)) return false;
    final percent = (level.clamp(0.0, 1.0) * 100).round();
    if (!_context.useControlSocket) {
      _sendBrightnessPlatformRequest(
        command: 1,
        monitorId: monitorId,
        connector: connector,
        percent: percent,
      );
      return true;
    }
    unawaited(
      _context.control
          .request(
            'brightness.set',
            parameters: <String, Object>{
              'monitor_id': monitorId,
              'connector': connector,
              'percent': percent,
            },
          )
          .catchError((Object _) {
            _sendBrightnessPlatformRequest(
              command: 1,
              monitorId: monitorId,
              connector: connector,
              percent: percent,
            );
            return <String, Object?>{};
          }),
    );
    return true;
  }

  bool _validBrightnessTarget(int monitorId, String connector) {
    return monitorId >= 0 &&
        connector.isNotEmpty &&
        fitsUtf8ByteLimit(connector, 128) &&
        !connector.contains('\u0000');
  }

  void _sendBrightnessPlatformRequest({
    required int command,
    required int monitorId,
    required String connector,
    required int percent,
  }) {
    final connectorBytes = utf8.encode(connector);
    final data = ByteData(12 + connectorBytes.length)
      ..setUint8(0, command)
      ..setInt64(1, monitorId, Endian.little)
      ..setUint8(9, percent.clamp(0, 100))
      ..setUint16(10, connectorBytes.length, Endian.little);
    data.buffer.asUint8List().setRange(12, data.lengthInBytes, connectorBytes);
    _context.platform
        .send(_brightnessChannel, data)
        ?.catchError((Object _) => null);
  }

  Future<double?> readSoftwareDimmingLevel({required int monitorId}) async {
    if (monitorId <= 0) return null;
    if (!_context.useControlSocket) {
      return _readSoftwareDimmingLevelFromPlatform(monitorId);
    }
    try {
      final result = await _context.control.request(
        'software_dimming.get',
        parameters: <String, Object>{'monitor_id': monitorId},
      );
      final returnedMonitor = result['monitor_id'];
      final value = result['level'];
      final supported = result['supported'];
      if (returnedMonitor is! int || value is! num || supported is! bool) {
        return null;
      }
      final level = value.toDouble().clamp(0.0, 1.0);
      if (!_softwareDimmingStates.isClosed) {
        _softwareDimmingStates.add(
          DenialSoftwareDimmingState(
            monitorId: returnedMonitor,
            level: level,
            supported: supported,
            completesRead: true,
          ),
        );
      }
      return supported ? level : null;
    } on Object {
      // A standalone Settings process has no compositor-owned platform
      // channel. Treat an older control socket as unsupported instead of
      // leaving a platform-channel read pending until its timeout.
      return null;
    }
  }

  Future<double?> _readSoftwareDimmingLevelFromPlatform(int monitorId) {
    final completer = Completer<double?>();
    final pending = _pendingSoftwareDimmingReads.putIfAbsent(
      monitorId,
      () => <Completer<double?>>{},
    );
    pending.add(completer);
    _sendSoftwareDimmingPlatformRequest(
      command: 0,
      monitorId: monitorId,
      percent: 100,
    );
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        final current = _pendingSoftwareDimmingReads[monitorId];
        current?.remove(completer);
        if (current?.isEmpty ?? false) {
          _pendingSoftwareDimmingReads.remove(monitorId);
        }
        return null;
      },
    );
  }

  bool setSoftwareDimming({required int monitorId, required double level}) {
    if (monitorId <= 0) return false;
    final percent = (level.clamp(0.0, 1.0) * 100).round();
    if (!_context.useControlSocket) {
      _sendSoftwareDimmingPlatformRequest(
        command: 1,
        monitorId: monitorId,
        percent: percent,
      );
      return true;
    }
    unawaited(
      _context.control
          .request(
            'software_dimming.set',
            parameters: <String, Object>{
              'monitor_id': monitorId,
              'percent': percent,
            },
          )
          .catchError((Object _) => <String, Object?>{}),
    );
    return true;
  }

  void _sendSoftwareDimmingPlatformRequest({
    required int command,
    required int monitorId,
    required int percent,
  }) {
    final data = ByteData(10)
      ..setUint8(0, command)
      ..setInt64(1, monitorId, Endian.little)
      ..setUint8(9, percent.clamp(0, 100));
    _context.platform
        .send(_softwareDimmingChannel, data)
        ?.catchError((Object _) => null);
  }

  Future<ByteData?> handleBrightnessState(ByteData? data) async {
    if (_brightnessStates.isClosed) return null;
    final update = SystemControlProtocol.decodeBrightness(data);
    if (update == null) return null;
    final (:monitorId, :level) = update;
    final pending = _pendingBrightnessReads.remove(monitorId);
    _brightnessStates.add(
      DenialBrightnessState(
        monitorId: monitorId,
        level: level,
        completesRead: pending?.isNotEmpty ?? false,
      ),
    );
    if (pending != null) {
      for (final completer in pending) {
        if (!completer.isCompleted) {
          completer.complete(level);
        }
      }
    }
    return null;
  }

  Future<ByteData?> handleSoftwareDimmingState(ByteData? data) async {
    if (_softwareDimmingStates.isClosed) return null;
    final update = SystemControlProtocol.decodeSoftwareDimming(data);
    if (update == null) return null;
    final (:monitorId, :level, :supported) = update;
    final pending = _pendingSoftwareDimmingReads.remove(monitorId);
    _softwareDimmingStates.add(
      DenialSoftwareDimmingState(
        monitorId: monitorId,
        level: level,
        supported: supported,
        completesRead: pending?.isNotEmpty ?? false,
      ),
    );
    if (pending != null) {
      for (final completer in pending) {
        if (!completer.isCompleted) {
          completer.complete(supported ? level : null);
        }
      }
    }
    return null;
  }

  Stream<DenialBrightnessState> get brightnessStates =>
      _brightnessStates.stream;

  Stream<DenialSoftwareDimmingState> get softwareDimmingStates =>
      _softwareDimmingStates.stream;
  void dispose() {
    for (final readers in _pendingBrightnessReads.values) {
      for (final pending in readers) {
        if (!pending.isCompleted) pending.complete(null);
      }
    }
    _pendingBrightnessReads.clear();
    for (final readers in _pendingSoftwareDimmingReads.values) {
      for (final pending in readers) {
        if (!pending.isCompleted) pending.complete(null);
      }
    }
    _pendingSoftwareDimmingReads.clear();
    unawaited(_brightnessStates.close());
    unawaited(_softwareDimmingStates.close());
  }
}
