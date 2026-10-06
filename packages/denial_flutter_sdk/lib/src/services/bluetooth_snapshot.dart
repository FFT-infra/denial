part of 'bluetooth_backend.dart';

@visibleForTesting
BluetoothSnapshot buildBluetoothSnapshot(
  Map<DBusObjectPath, Map<String, Map<String, DBusValue>>> managed, {
  int maxAdapters = 4,
  int maxDevices = 128,
}) {
  final adapters = <_AdapterSnapshot>[];
  for (final entry in managed.entries) {
    final properties = entry.value['org.bluez.Adapter1'];
    if (properties == null) {
      continue;
    }
    final candidate = _AdapterSnapshot(
      path: entry.key.value,
      name: _bounded(
        _string(properties, 'Alias', fallback: _string(properties, 'Name')),
        96,
      ),
      powered: _boolean(properties, 'Powered'),
      discovering: _boolean(properties, 'Discovering'),
      pairable: _boolean(properties, 'Pairable'),
    );
    if (adapters.length < maxAdapters) {
      adapters.add(candidate);
    } else {
      final replace = adapters.indexWhere((adapter) => !adapter.powered);
      if (candidate.powered && replace >= 0) {
        adapters[replace] = candidate;
      }
    }
  }
  if (adapters.isEmpty) {
    return const BluetoothSnapshot(
      serviceAvailable: true,
      available: false,
      adapterPath: null,
      adapterName: '',
      powered: false,
      discovering: false,
      pairable: false,
      devices: <BluetoothDeviceInfo>[],
    );
  }
  adapters.sort((left, right) {
    final powered = _compareTrueFirst(left.powered, right.powered);
    return powered != 0 ? powered : left.path.compareTo(right.path);
  });
  final adapter = adapters.first;
  final devices = <BluetoothDeviceInfo>[];
  HeapPriorityQueue<int>? worstFirst;
  for (final entry in managed.entries) {
    final properties = entry.value['org.bluez.Device1'];
    if (properties == null ||
        _objectPath(properties, 'Adapter') != adapter.path) {
      continue;
    }
    final address = _bounded(_string(properties, 'Address'), 32);
    final name = _bounded(
      _string(
        properties,
        'Alias',
        fallback: _string(properties, 'Name', fallback: address),
      ),
      96,
    );
    final candidate = BluetoothDeviceInfo(
      objectPath: entry.key.value,
      adapterPath: adapter.path,
      address: address,
      name: name.isEmpty ? 'Unknown device' : name,
      icon: _bounded(_string(properties, 'Icon'), 64),
      connected: _boolean(properties, 'Connected'),
      paired: _boolean(properties, 'Paired') || _boolean(properties, 'Bonded'),
      trusted: _boolean(properties, 'Trusted'),
      blocked: _boolean(properties, 'Blocked'),
      servicesResolved: _boolean(properties, 'ServicesResolved'),
      signalStrength: _int16(properties, 'RSSI'),
    );
    if (devices.length < maxDevices) {
      devices.add(candidate);
    } else if (devices.isNotEmpty) {
      // Allocate a heap only when the device cap is exceeded. Keep the old
      // replacement slots and prefer the first slot on exact priority ties,
      // so final sort input and tie behavior remain unchanged.
      worstFirst ??= HeapPriorityQueue<int>((left, right) {
        final order = _compareBluetoothDevices(devices[right], devices[left]);
        return order != 0 ? order : left.compareTo(right);
      })..addAll(Iterable<int>.generate(devices.length));
      final worstIndex = worstFirst.first;
      if (_compareBluetoothDevices(candidate, devices[worstIndex]) < 0) {
        worstFirst.removeFirst();
        devices[worstIndex] = candidate;
        worstFirst.add(worstIndex);
      }
    }
  }
  devices.sort(_compareBluetoothDevices);
  return BluetoothSnapshot(
    serviceAvailable: true,
    available: true,
    adapterPath: adapter.path,
    adapterName: adapter.name,
    powered: adapter.powered,
    discovering: adapter.discovering,
    pairable: adapter.pairable,
    devices: List<BluetoothDeviceInfo>.unmodifiable(devices),
  );
}

/// Only properties represented in the shell snapshot need a full BlueZ read.
/// Invalidations count too: their removal can change a field's fallback value.
bool bluetoothSignalAffectsSnapshot(DBusSignal signal) {
  const adapterInterface = 'org.bluez.Adapter1';
  const deviceInterface = 'org.bluez.Device1';
  const adapterProperties = {
    'Alias',
    'Name',
    'Powered',
    'Discovering',
    'Pairable',
  };
  const deviceProperties = {
    'Adapter',
    'Address',
    'Alias',
    'Name',
    'Icon',
    'Connected',
    'Paired',
    'Bonded',
    'Trusted',
    'Blocked',
    'ServicesResolved',
    'RSSI',
  };
  switch (signal) {
    case DBusPropertiesChangedSignal():
      final properties = switch (signal.propertiesInterface) {
        adapterInterface => adapterProperties,
        deviceInterface => deviceProperties,
        _ => const <String>{},
      };
      if (properties.isEmpty) return false;
      // ObjectManager already checks these signal signatures. Inspect the
      // original keys without materializing a changed-property map or list.
      return signal.values[1].asDict().keys.any(
            (key) => properties.contains(key.asString()),
          ) ||
          signal.values[2].asStringArray().any(properties.contains);
    case DBusObjectManagerInterfacesAddedSignal():
      final interfaces = signal.values[1].asDict();
      return interfaces.containsKey(const DBusString(adapterInterface)) ||
          interfaces.containsKey(const DBusString(deviceInterface));
    case DBusObjectManagerInterfacesRemovedSignal():
      return signal.values[1].asStringArray().any(
        (interface) =>
            interface == adapterInterface || interface == deviceInterface,
      );
    default:
      return false;
  }
}

class _AdapterSnapshot {
  const _AdapterSnapshot({
    required this.path,
    required this.name,
    required this.powered,
    required this.discovering,
    required this.pairable,
  });

  final String path;
  final String name;
  final bool powered;
  final bool discovering;
  final bool pairable;
}

String _string(
  Map<String, DBusValue> properties,
  String name, {
  String fallback = '',
}) {
  final value = properties[name];
  if (value is! DBusString) return fallback;
  final trimmed = value.value.trim();
  return trimmed.isNotEmpty ? trimmed : fallback;
}

bool _boolean(Map<String, DBusValue> properties, String name) {
  final value = properties[name];
  return value is DBusBoolean && value.value;
}

String? _objectPath(Map<String, DBusValue> properties, String name) {
  final value = properties[name];
  return value is DBusObjectPath ? value.value : null;
}

int? _int16(Map<String, DBusValue> properties, String name) {
  final value = properties[name];
  return value is DBusInt16 ? value.value : null;
}

int _compareTrueFirst(bool left, bool right) {
  if (left == right) {
    return 0;
  }
  return left ? -1 : 1;
}

int _compareBluetoothDevices(
  BluetoothDeviceInfo left,
  BluetoothDeviceInfo right,
) {
  var result = _compareTrueFirst(left.connected, right.connected);
  if (result != 0) {
    return result;
  }
  result = _compareTrueFirst(left.paired, right.paired);
  if (result != 0) {
    return result;
  }
  result = _compareTrueFirst(left.trusted, right.trusted);
  if (result != 0) {
    return result;
  }
  final leftSignal = left.signalStrength ?? -32768;
  final rightSignal = right.signalStrength ?? -32768;
  result = rightSignal.compareTo(leftSignal);
  return result != 0
      ? result
      : left.name.toLowerCase().compareTo(right.name.toLowerCase());
}

String _bounded(String value, int maxLength) =>
    value.length <= maxLength ? value : value.substring(0, maxLength);
