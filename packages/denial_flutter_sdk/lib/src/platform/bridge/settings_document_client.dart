import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/utf8_size.dart';
import '../bounded_byte_stream.dart';
import '../denial_bridge_models.dart';
import '../denial_wire.dart' as wire;
import 'context.dart';
import 'control_client.dart'
    show BridgeControlClient, DenialOutputControlException;

final class BridgeSettingsDocumentClient {
  BridgeSettingsDocumentClient(this._context) {
    _settingsDocuments.onListen = _startSettingsDocumentSubscription;
    _settingsDocuments.onCancel = _stopSettingsDocumentSubscription;
  }
  final BridgeContext _context;
  final Map<int, Completer<DenialSettingsDocument>>
  _pendingSettingsDocumentRequests = {};
  final Set<int> _settingsDocumentSeedRequestIds = <int>{};
  final StreamController<DenialSettingsDocument> _settingsDocuments =
      StreamController<DenialSettingsDocument>.broadcast(sync: true);
  Socket? _settingsDocumentSubscriptionSocket;
  Timer? _settingsDocumentReconnectTimer;
  int _settingsDocumentSubscriptionGeneration = 0;
  bool _settingsDocumentSubscriptionActive = false;
  int _latestSettingsDocumentRevision = 0;

  void _startSettingsDocumentSubscription() {
    if (_context.platform.isDisposed || _settingsDocumentSubscriptionActive) {
      return;
    }
    _settingsDocumentReconnectTimer?.cancel();
    _settingsDocumentReconnectTimer = null;
    _settingsDocumentSubscriptionActive = true;
    final generation = ++_settingsDocumentSubscriptionGeneration;
    if (_context.useControlSocket) {
      unawaited(_consumeSettingsDocumentSubscription(generation));
    } else {
      unawaited(_seedPlatformSettingsDocument(generation));
    }
  }

  void _stopSettingsDocumentSubscription() {
    _settingsDocumentSubscriptionActive = false;
    _settingsDocumentSubscriptionGeneration += 1;
    _settingsDocumentReconnectTimer?.cancel();
    _settingsDocumentReconnectTimer = null;
    _settingsDocumentSubscriptionSocket?.destroy();
    _settingsDocumentSubscriptionSocket = null;
  }

  Future<void> _seedPlatformSettingsDocument(int generation) async {
    try {
      await _readSettingsDocumentFromPlatform(subscriptionSnapshot: true);
    } on Object catch (error, stackTrace) {
      if (_settingsSubscriptionCurrent(generation) &&
          !_settingsDocuments.isClosed) {
        _settingsDocuments.addError(error, stackTrace);
      }
    } finally {
      if (generation == _settingsDocumentSubscriptionGeneration) {
        _settingsDocumentSubscriptionActive = false;
      }
    }
  }

  Future<void> _consumeSettingsDocumentSubscription(int generation) async {
    Object? failure;
    StackTrace? failureStackTrace;
    Socket? socket;
    try {
      final path = _context.control.socketPath();
      if (path == null ||
          await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.unixDomainSock) {
        throw const DenialOutputControlException(
          'unavailable',
          'The Denial control socket is not running.',
        );
      }
      final requestId = _context.platform.nextRequestId();
      final request = jsonEncode(<String, Object>{
        'version': 1,
        'id': requestId,
        'method': 'settings.document.subscribe',
      });
      socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: BridgeControlClient.timeout,
      );
      if (!_settingsSubscriptionCurrent(generation)) {
        socket.destroy();
        return;
      }
      _settingsDocumentSubscriptionSocket = socket;
      socket.add(utf8.encode('$request\n'));
      await socket.flush();
      final lines = StreamIterator<String>(
        decodeBoundedUtf8Lines(
          socket,
          maximumBytes: BridgeControlClient.maximumBytes,
        ),
      );
      try {
        final hasInitial = await lines.moveNext().timeout(
          BridgeControlClient.timeout,
        );
        if (!hasInitial) {
          throw const DenialOutputControlException(
            'unavailable',
            'The Denial settings subscription closed before its snapshot.',
          );
        }
        _publishSettingsDocument(
          _settingsDocumentFromSubscription(lines.current, requestId),
          acceptCurrentRevision: true,
        );
        while (_settingsSubscriptionCurrent(generation) &&
            await lines.moveNext()) {
          _publishSettingsDocument(
            _settingsDocumentFromSubscription(lines.current, requestId),
          );
        }
      } finally {
        await lines.cancel();
      }
      if (_settingsSubscriptionCurrent(generation)) {
        throw const DenialOutputControlException(
          'unavailable',
          'The Denial settings subscription closed.',
        );
      }
    } on ByteStreamLimitExceeded catch (_, stackTrace) {
      failure = const DenialOutputControlException(
        'invalid_response',
        'The Denial settings update is too large.',
      );
      failureStackTrace = stackTrace;
    } on Object catch (error, stackTrace) {
      failure = error;
      failureStackTrace = stackTrace;
    } finally {
      if (identical(_settingsDocumentSubscriptionSocket, socket)) {
        _settingsDocumentSubscriptionSocket = null;
      }
      socket?.destroy();
      if (generation == _settingsDocumentSubscriptionGeneration) {
        _settingsDocumentSubscriptionActive = false;
      }
    }
    if (!_settingsSubscriptionCurrent(generation, requireActive: false)) {
      return;
    }
    if (failure != null && !_settingsDocuments.isClosed) {
      _settingsDocuments.addError(failure, failureStackTrace);
    }
    _settingsDocumentReconnectTimer = Timer(
      const Duration(seconds: 1),
      _startSettingsDocumentSubscription,
    );
  }

  bool _settingsSubscriptionCurrent(
    int generation, {
    bool requireActive = true,
  }) =>
      !_context.platform.isDisposed &&
      _settingsDocuments.hasListener &&
      generation == _settingsDocumentSubscriptionGeneration &&
      (!requireActive || _settingsDocumentSubscriptionActive);

  DenialSettingsDocument _settingsDocumentFromSubscription(
    String line,
    int requestId,
  ) {
    final decoded = jsonDecode(line);
    if (decoded is! Map<String, Object?> ||
        decoded['version'] != 1 ||
        decoded['id'] != requestId ||
        decoded['ok'] != true ||
        decoded['result'] is! Map<String, Object?>) {
      throw const DenialOutputControlException(
        'invalid_response',
        'Denial returned an invalid settings subscription update.',
      );
    }
    return _settingsDocumentFromControl(
      decoded['result']! as Map<String, Object?>,
    );
  }

  void _rememberSettingsDocument(DenialSettingsDocument document) {
    if (document.revision > _latestSettingsDocumentRevision) {
      _latestSettingsDocumentRevision = document.revision;
    }
  }

  void _publishSettingsDocument(
    DenialSettingsDocument document, {
    bool acceptCurrentRevision = false,
  }) {
    if (_context.platform.isDisposed ||
        document.revision < _latestSettingsDocumentRevision ||
        (!acceptCurrentRevision &&
            document.revision == _latestSettingsDocumentRevision)) {
      return;
    }
    _latestSettingsDocumentRevision = document.revision;
    if (!_settingsDocuments.isClosed) {
      _settingsDocuments.add(document);
    }
  }

  Future<DenialSettingsDocument> readSettingsDocument() async {
    if (!_context.useControlSocket) return _readSettingsDocumentFromPlatform();
    try {
      final document = _settingsDocumentFromControl(
        await _context.control.request('settings.document.get'),
      );
      _rememberSettingsDocument(document);
      return document;
    } on DenialOutputControlException catch (error) {
      throw StateError(error.message);
    }
  }

  Future<DenialSettingsDocument> writeSettingsDocument({
    required int expectedRevision,
    required String document,
  }) async {
    if (expectedRevision <= 0 ||
        document.isEmpty ||
        !fitsUtf8ByteLimit(document, wire.denialWireMaxSettingsDocumentBytes)) {
      throw ArgumentError('invalid Denial settings document');
    }
    if (!_context.useControlSocket) {
      return _writeSettingsDocumentToPlatform(
        expectedRevision: expectedRevision,
        document: document,
      );
    }
    try {
      final updated = _settingsDocumentFromControl(
        await _context.control.request(
          'settings.document.apply',
          parameters: <String, Object>{
            'expected_revision': expectedRevision,
            'document': document,
          },
        ),
      );
      _publishSettingsDocument(updated);
      return updated;
    } on DenialOutputControlException catch (error) {
      throw StateError(error.message);
    }
  }

  DenialSettingsDocument _settingsDocumentFromControl(
    Map<String, Object?> result,
  ) {
    final revision = result['revision'];
    final document = result['document'];
    if (revision is! int ||
        revision <= 0 ||
        document is! String ||
        document.isEmpty ||
        !fitsUtf8ByteLimit(document, wire.denialWireMaxSettingsDocumentBytes)) {
      throw StateError('Denial returned an invalid settings document');
    }
    return DenialSettingsDocument(revision: revision, json: document);
  }

  Future<DenialSettingsDocument> _readSettingsDocumentFromPlatform({
    bool subscriptionSnapshot = false,
  }) {
    final requestId = _context.platform.nextRequestId();
    final completer = Completer<DenialSettingsDocument>();
    _pendingSettingsDocumentRequests[requestId] = completer;
    if (subscriptionSnapshot) {
      _settingsDocumentSeedRequestIds.add(requestId);
    }
    _context.sendWire(
      _context.codec.encodeSettingsRead(
        wire.SettingsRequestKind.ReadDocument,
        requestId: requestId,
      ),
    );
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingSettingsDocumentRequests.remove(requestId);
        _settingsDocumentSeedRequestIds.remove(requestId);
        throw TimeoutException('Denial settings read timed out');
      },
    );
  }

  Future<DenialSettingsDocument> _writeSettingsDocumentToPlatform({
    required int expectedRevision,
    required String document,
  }) {
    final requestId = _context.platform.nextRequestId();
    final bytes = _context.codec.encodeSettingsDocumentWrite(
      requestId: requestId,
      expectedRevision: expectedRevision,
      document: document,
    );
    if (bytes == null) {
      return Future<DenialSettingsDocument>.error(
        ArgumentError('invalid Denial settings document'),
      );
    }
    final completer = Completer<DenialSettingsDocument>();
    _pendingSettingsDocumentRequests[requestId] = completer;
    _context.sendWire(bytes);
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingSettingsDocumentRequests.remove(requestId);
        throw TimeoutException('Denial settings write timed out');
      },
    );
  }

  Stream<DenialSettingsDocument> get settingsDocuments =>
      _settingsDocuments.stream;
  void handleResponse(int requestId, wire.SettingsResponse response) {
    if (response.kind == wire.SettingsResponseKind.Document) {
      final completer = _pendingSettingsDocumentRequests.remove(requestId);
      final subscriptionSnapshot = _settingsDocumentSeedRequestIds.remove(
        requestId,
      );
      final document = response.document;
      if (!response.success ||
          response.revision <= 0 ||
          document == null ||
          !fitsUtf8ByteLimit(
            document,
            wire.denialWireMaxSettingsDocumentBytes,
          )) {
        if (completer != null && !completer.isCompleted) {
          completer.completeError(
            StateError(response.error ?? 'Denial settings request failed'),
          );
        }
        return;
      }
      final settings = DenialSettingsDocument(
        revision: response.revision,
        json: document,
      );
      _publishSettingsDocument(
        settings,
        acceptCurrentRevision: subscriptionSnapshot,
      );
      if (requestId != 0 && completer != null && !completer.isCompleted) {
        completer.complete(settings);
      }
      return;
    }
  }

  void dispose() {
    _stopSettingsDocumentSubscription();
    for (final pending in _pendingSettingsDocumentRequests.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Denial bridge disposed'));
      }
    }
    _pendingSettingsDocumentRequests.clear();
    _settingsDocumentSeedRequestIds.clear();
    unawaited(_settingsDocuments.close());
  }
}
