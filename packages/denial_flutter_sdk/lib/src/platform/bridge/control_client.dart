import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../bounded_byte_stream.dart';
import 'platform_transport.dart';

final class BridgeControlClient {
  BridgeControlClient(this._platform, {this.controlSocketPath});
  final BridgePlatformTransport _platform;
  final String? controlSocketPath;
  static const int maximumBytes = 256 * 1024;
  static const Duration timeout = Duration(seconds: 20);

  Future<Map<String, Object?>> request(
    String method, {
    Map<String, Object>? parameters,
    int? requestId,
  }) async {
    final path = socketPath();
    if (path == null) {
      throw const DenialOutputControlException(
        'unavailable',
        'The Denial output control socket is unavailable.',
      );
    }
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.unixDomainSock) {
      throw const DenialOutputControlException(
        'unavailable',
        'The Denial control socket is not running.',
      );
    }
    final resolvedRequestId = requestId ?? _platform.nextRequestId();
    final request = jsonEncode(<String, Object>{
      'version': 1,
      'id': resolvedRequestId,
      'method': method,
      'params': ?parameters,
    });
    final requestBytes = utf8.encode('$request\n');
    if (requestBytes.length > maximumBytes) {
      throw const DenialOutputControlException(
        'invalid_request',
        'The output configuration is too large.',
      );
    }

    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: timeout,
      );
      socket.add(requestBytes);
      await socket.flush();
      final responseBytes = await collectBoundedBytes(
        socket.timeout(timeout),
        maximumBytes: maximumBytes,
      );
      final decoded = jsonDecode(utf8.decode(responseBytes));
      if (decoded is! Map<String, Object?> ||
          decoded['version'] != 1 ||
          decoded['id'] != resolvedRequestId) {
        throw const DenialOutputControlException(
          'invalid_response',
          'The compositor returned an invalid output response.',
        );
      }
      if (decoded['ok'] != true) {
        final error = decoded['error'];
        if (error is Map<String, Object?>) {
          throw DenialOutputControlException(
            error['code'] is String ? error['code']! as String : 'failed',
            error['message'] is String
                ? error['message']! as String
                : 'The compositor rejected the output configuration.',
          );
        }
        throw const DenialOutputControlException(
          'failed',
          'The compositor rejected the output configuration.',
        );
      }
      final result = decoded['result'];
      if (result is Map<String, Object?>) {
        return result;
      }
      throw const DenialOutputControlException(
        'invalid_response',
        'The compositor returned no output configuration.',
      );
    } on ByteStreamLimitExceeded {
      throw const DenialOutputControlException(
        'invalid_response',
        'The compositor output response is too large.',
      );
    } on DenialOutputControlException {
      rethrow;
    } on Object catch (error) {
      throw DenialOutputControlException(
        'unavailable',
        'Could not reach Denial output control: $error',
      );
    } finally {
      socket?.destroy();
    }
  }

  String? socketPath() {
    final override = controlSocketPath;
    if (override != null) {
      return override.startsWith('/') && !override.contains('\u0000')
          ? override
          : null;
    }
    final environment = Platform.environment;
    final explicit = environment['DENIAL_SOCKET'];
    if (explicit != null &&
        explicit.startsWith('/') &&
        !explicit.contains('\u0000')) {
      return explicit;
    }
    final runtime = environment['XDG_RUNTIME_DIR'];
    if (runtime == null ||
        !runtime.startsWith('/') ||
        runtime.contains('\u0000')) {
      return null;
    }
    return '${runtime.replaceFirst(RegExp(r'/+$'), '')}/denial/control.sock';
  }
}

class DenialOutputControlException implements Exception {
  const DenialOutputControlException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}
