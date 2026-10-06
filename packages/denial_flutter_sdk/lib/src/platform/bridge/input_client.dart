import 'dart:typed_data';

import '../../input/input_layout.dart';
import '../denial_wire.dart' as wire;
import 'context.dart';

final class BridgeInputClient {
  BridgeInputClient(this._context);

  final BridgeContext _context;
  static const String _cursorPresentedChannel = 'denial/cursor_presented';
  bool publishInputLayout(InputLayoutSnapshot snapshot) {
    final bytes = _context.codec.encodeInputLayout(snapshot);
    if (bytes == null) {
      return false;
    }
    _context.sendWire(bytes);
    return true;
  }

  bool acknowledgeCursorPresented(int epoch) {
    if (epoch <= 0) {
      return false;
    }
    final payload = ByteData(8)..setUint64(0, epoch, Endian.little);
    _context.platform
        .send(_cursorPresentedChannel, payload)
        ?.catchError((Object _) => null);
    return true;
  }

  void sendKeyboardText(String text) {
    if (text.isEmpty) {
      return;
    }

    _context.sendWire(_context.codec.encodeKeyboardText(text));
  }

  void sendKeyboardKey(String key, {bool ctrl = false}) {
    if (key.isEmpty) {
      return;
    }

    _context.sendWire(_context.codec.encodeKeyboardKey(key, ctrl: ctrl));
  }

  void dismissKeyboardPanel(int activationSerial) {
    _context.sendWire(
      _context.codec.encodeKeyboardPanelDismissal(activationSerial),
    );
  }

  void pressKeyboardKey(String key) {
    if (key.isEmpty) {
      return;
    }

    _context.sendWire(
      _context.codec.encodeKeyboardKey(
        key,
        phase: wire.DenialKeyboardKeyPhase.pressed,
      ),
    );
  }

  void releaseKeyboardKey(String key) {
    if (key.isEmpty) {
      return;
    }

    _context.sendWire(
      _context.codec.encodeKeyboardKey(
        key,
        phase: wire.DenialKeyboardKeyPhase.released,
      ),
    );
  }
}
