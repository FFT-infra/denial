import 'dart:typed_data';

import '../denial_wire.dart' as wire;
import 'control_client.dart';
import 'platform_transport.dart';

/// Shared transport, request identities and codec state for all domain clients.
final class BridgeContext {
  BridgeContext(
    this.platform, {
    required this.useControlSocket,
    String? controlSocketPath,
  }) : control = BridgeControlClient(
         platform,
         controlSocketPath: controlSocketPath,
       );

  final BridgePlatformTransport platform;
  final BridgeControlClient control;
  final bool useControlSocket;
  final wire.DenialWireCodec codec = wire.DenialWireCodec();

  void sendWire(Uint8List bytes) {
    platform
        .send(wire.denialWireToNativeChannel, ByteData.sublistView(bytes))
        ?.catchError((Object _) => null);
  }
}
