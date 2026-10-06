import 'dart:math';

import 'package:dbus/dbus.dart';

const bluetoothAdapterInterface = 'org.bluez.Adapter1';
const bluetoothDeviceInterface = 'org.bluez.Device1';

typedef BluetoothObjects =
    Map<DBusObjectPath, Map<String, Map<String, DBusValue>>>;

BluetoothObjects bluetoothObjects(
  int count, {
  int seed = 0,
  bool tied = false,
}) {
  final random = Random(seed);
  return {
    DBusObjectPath('/adapter'): {
      bluetoothAdapterInterface: {
        'Alias': const DBusString('Test adapter'),
        'Powered': const DBusBoolean(true),
      },
    },
    for (var i = 0; i < count; i++)
      DBusObjectPath('/adapter/device$i'): {
        bluetoothDeviceInterface: {
          'Adapter': DBusObjectPath('/adapter'),
          'Address': DBusString('address$i'),
          'Name': DBusString(
            tied ? 'Same device' : 'Device ${random.nextInt(100)}',
          ),
          'Connected': DBusBoolean(!tied && random.nextInt(10) == 0),
          'Paired': DBusBoolean(!tied && random.nextBool()),
          'Trusted': DBusBoolean(!tied && random.nextBool()),
          'RSSI': DBusInt16(tied ? -60 : random.nextInt(60) - 80),
        },
      },
  };
}

DBusPropertiesChangedSignal bluetoothProperties(
  String interface, {
  Map<String, DBusValue> changed = const {},
  List<String> invalidated = const [],
}) => DBusPropertiesChangedSignal(
  DBusSignal(
    sender: ':1.42',
    path: DBusObjectPath('/adapter'),
    interface: 'org.freedesktop.DBus.Properties',
    name: 'PropertiesChanged',
    values: [
      DBusString(interface),
      DBusDict.stringVariant(changed),
      DBusArray.string(invalidated),
    ],
  ),
);

DBusSignal bluetoothInterfaces(List<String> interfaces, {required bool added}) {
  final signal = DBusSignal(
    sender: ':1.42',
    path: DBusObjectPath.root,
    interface: 'org.freedesktop.DBus.ObjectManager',
    name: added ? 'InterfacesAdded' : 'InterfacesRemoved',
    values: [
      DBusObjectPath('/adapter'),
      if (added)
        DBusDict(DBusSignature('s'), DBusSignature('a{sv}'), {
          for (final interface in interfaces)
            DBusString(interface): DBusDict.stringVariant({}),
        })
      else
        DBusArray.string(interfaces),
    ],
  );
  return added
      ? DBusObjectManagerInterfacesAddedSignal(signal)
      : DBusObjectManagerInterfacesRemovedSignal(signal);
}
