import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/clipboard_history.dart';
import '../platform/clipboard_history_protocol.dart';

const String denialClipboardChannel = 'denial/clipboard';
const String denialClipboardStateChannel = 'denial/clipboard_state';

final clipboardHistoryServiceProvider = Provider<ClipboardHistoryService>((
  ref,
) {
  final service = ClipboardHistoryService();
  ref.onDispose(service.dispose);
  return service;
});

class ClipboardHistoryService {
  ClipboardHistoryService({BinaryMessenger? messenger})
    : _messenger =
          messenger ?? ServicesBinding.instance.defaultBinaryMessenger {
    _messenger.setMessageHandler(
      denialClipboardStateChannel,
      _handleStateMessage,
    );
  }

  final BinaryMessenger _messenger;
  final StreamController<ClipboardHistorySnapshot> _snapshots =
      StreamController<ClipboardHistorySnapshot>.broadcast(sync: true);
  ClipboardHistorySnapshot? _lastSnapshot;
  bool _disposed = false;

  Stream<ClipboardHistorySnapshot> get snapshots => _snapshots.stream;
  ClipboardHistorySnapshot? get lastSnapshot => _lastSnapshot;

  Future<ClipboardHistorySnapshot> snapshot({String query = ''}) async {
    return ClipboardHistoryProtocol.decodeSnapshot(
      await _send(ClipboardHistoryProtocol.snapshotRequest(query)),
    );
  }

  Future<ClipboardHistoryData> readData(int itemId, String mimeType) async {
    final data = ClipboardHistoryProtocol.decodeData(
      await _send(ClipboardHistoryProtocol.readRequest(itemId, mimeType)),
    );
    if (data.itemId != itemId || data.mimeType != mimeType) {
      throw const ClipboardHistoryException(
        1,
        'Native clipboard data response did not match its request',
      );
    }
    return data;
  }

  Future<int> activate(int itemId) async =>
      _sendAck(ClipboardHistoryProtocol.activateRequest(itemId));

  Future<int> setPinned(int itemId, {required bool pinned}) async => _sendAck(
    ClipboardHistoryProtocol.setPinnedRequest(itemId, pinned: pinned),
  );

  Future<int> delete(int itemId) async =>
      _sendAck(ClipboardHistoryProtocol.deleteRequest(itemId));

  Future<int> clear() => _sendAck(ClipboardHistoryProtocol.clearRequest());

  Future<int> setPaused({required bool paused}) =>
      _sendAck(ClipboardHistoryProtocol.setPausedRequest(paused: paused));

  /// Starts a compositor-owned copy drag from the current Flutter pointer
  /// press. The native source keeps every retained MIME representation, so
  /// Wayland and Xwayland targets can negotiate text, files, or image bytes.
  Future<int> startDrag(int itemId) async =>
      _sendAck(ClipboardHistoryProtocol.startDragRequest(itemId));

  Future<void> setText(String text) {
    return Clipboard.setData(ClipboardData(text: text));
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _messenger.setMessageHandler(denialClipboardStateChannel, null);
    unawaited(_snapshots.close());
  }

  Future<int> _sendAck(ByteData request) async =>
      ClipboardHistoryProtocol.decodeAck(await _send(request));

  Future<ByteData> _send(ByteData request) async {
    if (_disposed) {
      throw const ClipboardHistoryException(
        1,
        'Clipboard history service is disposed',
      );
    }
    final pending = _messenger.send(denialClipboardChannel, request);
    if (pending == null) {
      throw const ClipboardHistoryException(
        1,
        'Clipboard platform channel is unavailable',
      );
    }
    final response = await pending.timeout(const Duration(seconds: 2));
    if (response == null) {
      throw const ClipboardHistoryException(
        1,
        'Native clipboard returned no response',
      );
    }
    return response;
  }

  Future<ByteData?> _handleStateMessage(ByteData? message) async {
    if (_disposed || message == null) {
      return null;
    }
    try {
      final snapshot = ClipboardHistoryProtocol.decodeSnapshot(message);
      _lastSnapshot = snapshot;
      _snapshots.add(snapshot);
    } on Object catch (error, stackTrace) {
      _snapshots.addError(error, stackTrace);
    }
    return null;
  }
}
