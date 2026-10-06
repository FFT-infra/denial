part of 'bluetooth_backend.dart';

class _PendingPairing {
  const _PendingPairing(this.request, this.completer);

  final BluetoothPairingRequest request;
  final Completer<DBusMethodResponse> completer;
}

@visibleForTesting
class BluetoothAgentEndpoint extends DBusObject {
  BluetoothAgentEndpoint()
    : super(DBusObjectPath('/org/denial/BluetoothAgent'));

  String? Function()? owner;
  Future<DBusMethodResponse> Function(DBusMethodCall)? handler;

  @override
  List<DBusIntrospectInterface> introspect() => <DBusIntrospectInterface>[
    DBusIntrospectInterface(
      'org.bluez.Agent1',
      methods: <DBusIntrospectMethod>[
        _agentMethod('Release'),
        _agentMethod('RequestPinCode', input: 'o', output: 's'),
        _agentMethod('DisplayPinCode', input: 'os'),
        _agentMethod('RequestPasskey', input: 'o', output: 'u'),
        _agentMethod('DisplayPasskey', input: 'ouq'),
        _agentMethod('RequestConfirmation', input: 'ou'),
        _agentMethod('RequestAuthorization', input: 'o'),
        _agentMethod('AuthorizeService', input: 'os'),
        _agentMethod('Cancel'),
      ],
    ),
  ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != 'org.bluez.Agent1') {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final expectedOwner = owner?.call();
    if (expectedOwner == null || methodCall.sender != expectedOwner) {
      return DBusMethodErrorResponse.accessDenied();
    }
    final callback = handler;
    return callback == null
        ? DBusMethodErrorResponse.failed('Pairing agent is unavailable')
        : callback(methodCall);
  }
}

DBusIntrospectMethod _agentMethod(
  String name, {
  String input = '',
  String output = '',
}) {
  final arguments = <DBusIntrospectArgument>[
    for (var index = 0; index < input.length; index++)
      DBusIntrospectArgument(
        DBusSignature(input[index]),
        DBusArgumentDirection.in_,
      ),
    for (var index = 0; index < output.length; index++)
      DBusIntrospectArgument(
        DBusSignature(output[index]),
        DBusArgumentDirection.out,
      ),
  ];
  return DBusIntrospectMethod(name, args: arguments);
}

DBusMethodErrorResponse _bluezRejected(String message) =>
    DBusMethodErrorResponse('org.bluez.Error.Rejected', <DBusValue>[
      DBusString(message),
    ]);

DBusMethodErrorResponse _bluezCanceled(String message) =>
    DBusMethodErrorResponse('org.bluez.Error.Canceled', <DBusValue>[
      DBusString(message),
    ]);
