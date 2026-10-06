import 'package:dbus/dbus.dart';

const _adapter = 'net.connman.iwd.Adapter';
const _device = 'net.connman.iwd.Device';
const _snapshotInterfaces = {
  _adapter,
  _device,
  'net.connman.iwd.Station',
  'net.connman.iwd.Network',
  'net.connman.iwd.KnownNetwork',
  'net.connman.iwd.BasicServiceSet',
};

/// Filters unrelated property traffic without materializing nested maps.
/// Network and BSS changes remain relevant even when their fields are not
/// displayed directly: they can affect GetOrderedNetworks ranking/strength.
bool iwdSignalAffectsSnapshot(DBusSignal signal) {
  switch (signal) {
    case DBusPropertiesChangedSignal():
      final interface = signal.propertiesInterface;
      if (!_snapshotInterfaces.contains(interface)) return false;
      final changed = signal.values[1].asDict();
      final invalidated = signal.values[2].asStringArray();
      final properties = switch (interface) {
        _adapter => const {'Powered', 'SupportedModes'},
        _device => const {'Name', 'Mode', 'Powered'},
        _ => null,
      };
      return properties == null
          ? changed.isNotEmpty || invalidated.isNotEmpty
          : changed.keys.any((key) => properties.contains(key.asString())) ||
                invalidated.any(properties.contains);
    case DBusObjectManagerInterfacesAddedSignal():
      return signal.values[1].asDict().keys.any(
        (key) => _snapshotInterfaces.contains(key.asString()),
      );
    case DBusObjectManagerInterfacesRemovedSignal():
      return signal.values[1].asStringArray().any(_snapshotInterfaces.contains);
    default:
      // Preserve refreshes for unfamiliar non-property signals.
      return true;
  }
}
