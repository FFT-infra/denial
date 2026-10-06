import 'dart:convert';

import '../platform/denial_bridge.dart';
import 'settings_document.dart';
import 'shell_settings.dart';

abstract interface class SettingsStore {
  Future<ShellSettings?> read();

  Future<void> write(ShellSettings settings);
}

abstract interface class SettingsDocumentTransport {
  Future<DenialSettingsDocument> read();

  Future<DenialSettingsDocument> write({
    required int expectedRevision,
    required String document,
  });
}

abstract interface class SettingsDocumentUpdateSource {
  /// Emits the complete authoritative document immediately on subscription,
  /// then emits a complete document for every later revision.
  Stream<DenialSettingsDocument> get settingsDocumentUpdates;
}

class DenialSettingsDocumentTransport
    implements SettingsDocumentTransport, SettingsDocumentUpdateSource {
  const DenialSettingsDocumentTransport(this._bridge);

  final DenialBridge _bridge;

  @override
  Stream<DenialSettingsDocument> get settingsDocumentUpdates =>
      _bridge.settingsDocuments;

  @override
  Future<DenialSettingsDocument> read() => _bridge.readSettingsDocument();

  @override
  Future<DenialSettingsDocument> write({
    required int expectedRevision,
    required String document,
  }) => _bridge.writeSettingsDocument(
    expectedRevision: expectedRevision,
    document: document,
  );
}

/// Shell-facing projection of deniald's shared settings document.
///
/// The compositor is the only process that opens `settings.json`. This class
/// retains a revision token, sends typed bridge requests, and retries once
/// after a concurrent native keyboard update advances the shared document.
/// Unknown plugin fields are retained from the complete native document.
class NativeSettingsStore
    implements SettingsStore, SettingsDocumentUpdateSource {
  NativeSettingsStore(this._transport);

  final SettingsDocumentTransport _transport;
  Future<void> _writeQueue = Future<void>.value();
  final SettingsDocumentProjection _document = SettingsDocumentProjection();

  @override
  Stream<DenialSettingsDocument> get settingsDocumentUpdates =>
      _transport is SettingsDocumentUpdateSource
      ? (_transport as SettingsDocumentUpdateSource).settingsDocumentUpdates
            .map(_rememberDocument)
      : const Stream<DenialSettingsDocument>.empty();

  @override
  Future<ShellSettings?> read() async => _decode(await _readDocument());

  @override
  Future<void> write(ShellSettings settings) {
    final write = _writeQueue.then((_) => _write(settings));
    _writeQueue = write.catchError((_) {});
    return write;
  }

  Future<void> _write(ShellSettings settings) async {
    if (_document.revision <= 0) {
      await _readDocument();
    }
    final projection = settings.toJson();
    try {
      final response = await _transport.write(
        expectedRevision: _document.revision,
        document: _document.encode(projection),
      );
      _rememberDocument(response);
    } on StateError {
      // A keyboard update and a shell preference can be committed in either
      // order. Refresh the token and replay the shell projection once; Rust
      // preserves the native-owned keyboard section during this write.
      await _readDocument();
      final response = await _transport.write(
        expectedRevision: _document.revision,
        document: _document.encode(projection),
      );
      _rememberDocument(response);
    }
  }

  Future<DenialSettingsDocument> _readDocument() async {
    return _rememberDocument(await _transport.read());
  }

  DenialSettingsDocument _rememberDocument(DenialSettingsDocument document) {
    _document.remember(revision: document.revision, document: document.json);
    return document;
  }

  ShellSettings _decode(DenialSettingsDocument document) {
    final decoded = jsonDecode(document.json);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Denial settings root is not an object');
    }
    return ShellSettings.fromJson(decoded);
  }
}
