import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A Unix account that Polkit accepts for the current request.
@immutable
class AgentIdentity {
  const AgentIdentity({required this.uid, required this.name});

  final int uid;
  final String name;
}

enum AgentPhase {
  /// Waiting for the backend's request.
  connecting,

  /// Several identities are acceptable; one must be selected once.
  choosing,

  /// An identity is selected; the PAM conversation has not prompted yet.
  preparing,

  /// A conversation prompt awaits a response.
  prompting,

  /// A response was sent; the next prompt, a message or completion follows.
  verifying,

  /// The dialog was not started by, or lost, the authentication agent.
  unavailable,
}

enum AgentNoticeKind { info, error }

@immutable
class AgentNotice {
  const AgentNotice(this.kind, this.text);

  final AgentNoticeKind kind;
  final String text;
}

/// Schema-1 client of `denial-polkit-agent`.
///
/// Deliberately thin: authentication policy, attempts and the conversation are
/// owned by Rust. This relays replies and exposes state for presentation only.
class AgentSession extends ChangeNotifier {
  Socket? _socket;
  int? _prompt;
  bool _awaitingVerdict = false;
  bool _closing = false;

  AgentPhase phase = AgentPhase.connecting;
  String message = '';
  String action = '';

  /// What the requester will run, and as whom, when Polkit's caller says.
  String? command;
  String? runAs;
  List<AgentIdentity> identities = const [];
  int? selectedUid;
  String promptLabel = '';
  bool echo = false;
  AgentNotice? notice;

  /// Incremented when the backend rejects a submitted response.
  int rejections = 0;

  /// Incremented for every conversation prompt, including retries.
  int prompts = 0;

  AgentIdentity? get selectedIdentity {
    for (final identity in identities) {
      if (identity.uid == selectedUid) return identity;
    }
    return null;
  }

  Future<void> connect() async {
    try {
      final path = Platform.environment['DENIAL_POLKIT_SOCKET'];
      final token = Platform.environment['DENIAL_POLKIT_TOKEN'];
      if (path == null || token == null) {
        throw StateError('Start this dialog through denial-polkit-agent.');
      }
      final connection = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      if (_closing) {
        connection.destroy();
        return;
      }
      _socket = connection;
      _send({'type': 'hello', 'token': token});
      connection
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            _receive,
            // The backend ends the dialog on completion or cancellation.
            onDone: () => exit(0),
            onError: (Object _) => exit(1),
          );
    } catch (_) {
      _unavailable('Could not connect to the authentication agent.');
    }
  }

  void _unavailable(String text) {
    phase = AgentPhase.unavailable;
    notice = AgentNotice(AgentNoticeKind.error, text);
    notifyListeners();
  }

  void _send(Map<String, Object?> value) {
    try {
      _socket?.write('${jsonEncode(value)}\n');
    } on SocketException {
      _unavailable('The authentication agent is no longer available.');
    }
  }

  void _receive(String line) {
    final Map<String, dynamic> event;
    try {
      event = jsonDecode(line) as Map<String, dynamic>;
    } on FormatException {
      return;
    }
    switch (event['type']) {
      case 'request':
        message = event['message'] as String? ?? '';
        action = event['action'] as String? ?? '';
        command = event['command'] as String?;
        runAs = event['runAs'] as String?;
        identities = [
          for (final identity in event['identities'] as List? ?? const [])
            if (identity case {'uid': final int uid, 'name': final String name})
              AgentIdentity(uid: uid, name: name),
        ];
        if (identities.isEmpty) {
          _unavailable('No account can authorize this action.');
          return;
        }
        selectedUid = identities.first.uid;
        phase = AgentPhase.choosing;
        if (identities.length == 1) start();
      case 'prompt':
        _prompt = event['prompt'] as int;
        prompts += 1;
        promptLabel = _label(event['text'] as String? ?? '');
        echo = event['echo'] as bool? ?? false;
        _awaitingVerdict = false;
        phase = AgentPhase.prompting;
      case 'info':
        notice = AgentNotice(AgentNoticeKind.info, event['text'] as String);
      case 'failed':
        // Attempts are exhausted; the agent closes the dialog shortly.
        if (_awaitingVerdict) {
          _awaitingVerdict = false;
          rejections += 1;
        }
        _unavailable(event['text'] as String? ?? 'Authentication failed.');
        return;
      case 'error':
        notice = AgentNotice(AgentNoticeKind.error, event['text'] as String);
        // PAM may report several messages for one rejected attempt.
        if (_awaitingVerdict) {
          _awaitingVerdict = false;
          rejections += 1;
        }
    }
    notifyListeners();
  }

  /// PAM prompts such as "Password: " read better as a field placeholder.
  static String _label(String text) {
    final trimmed = text.trim();
    final label = trimmed.endsWith(':')
        ? trimmed.substring(0, trimmed.length - 1).trimRight()
        : trimmed;
    return label.isEmpty ? 'Password' : label;
  }

  void choose(int uid) {
    if (phase != AgentPhase.choosing || selectedUid == uid) return;
    selectedUid = uid;
    notifyListeners();
  }

  /// Polkit accepts one identity selection before authentication starts.
  void start() {
    if (phase != AgentPhase.choosing || selectedUid == null) return;
    phase = AgentPhase.preparing;
    _send({'type': 'select', 'uid': selectedUid});
    notifyListeners();
  }

  void respond(String text) {
    final prompt = _prompt;
    if (phase != AgentPhase.prompting || prompt == null) return;
    _send({'type': 'response', 'prompt': prompt, 'text': text});
    _prompt = null;
    _awaitingVerdict = true;
    phase = AgentPhase.verifying;
    notice = null;
    notifyListeners();
  }

  /// A typed reply supersedes the previous attempt's message.
  void dismissNotice() {
    if (notice == null || phase == AgentPhase.unavailable) return;
    notice = null;
    notifyListeners();
  }

  /// The backend closes this process after cancellation. Without a backend,
  /// nothing else would, so the dialog exits itself.
  void cancel() {
    _closing = true;
    if (_socket == null || phase == AgentPhase.unavailable) exit(0);
    _send({'type': 'cancel'});
  }

  @override
  void dispose() {
    _closing = true;
    _socket?.destroy();
    super.dispose();
  }
}
