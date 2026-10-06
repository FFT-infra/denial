import 'dart:async';
import 'dart:typed_data';

typedef BridgeMessageHandler = Future<ByteData?> Function(ByteData? message);
typedef BridgeMessageSender = Future<ByteData?>? Function(
  String channel,
  ByteData? message,
);
typedef BridgeMessageRegistrar = void Function(
  String channel,
  BridgeMessageHandler? handler,
);

/// Owns one set of native channels independently of window/UI subscriptions.
final class BridgePlatformTransport {
  BridgePlatformTransport(this._send, this._setMessageHandler);

  final BridgeMessageSender _send;
  final BridgeMessageRegistrar _setMessageHandler;
  final Set<String> _channels = {};
  int _nextRequestId = 1;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  int nextRequestId() {
    if (_disposed) throw StateError('Denial bridge disposed');
    return _nextRequestId++;
  }

  void bind(Map<String, BridgeMessageHandler> handlers) {
    if (_disposed) throw StateError('Denial bridge disposed');
    for (final entry in handlers.entries) {
      if (!_channels.add(entry.key)) {
        throw StateError('Native channel already bound: ${entry.key}');
      }
      _setMessageHandler(entry.key, (message) {
        if (_disposed) return Future<ByteData?>.value();
        return entry.value(message);
      });
    }
  }

  Future<ByteData?>? send(String channel, ByteData? message) {
    if (_disposed) return Future<ByteData?>.value();
    return _send(channel, message);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final channel in _channels) {
      _setMessageHandler(channel, null);
    }
    _channels.clear();
  }
}
