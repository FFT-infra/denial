// Reference implementation retained for differential tests and benchmarks.
import 'package:denial_flutter_sdk/system_services.dart';

WifiNetwork legacyCopyWifiNetwork(
  WifiNetwork source, {
  String? savedNetworkPath,
}) => WifiNetwork(
  ssid: source.ssid,
  ssidBytes: source.ssidBytes,
  security: source.security,
  strength: source.strength,
  frequency: source.frequency,
  devicePath: source.devicePath,
  networkPath: source.networkPath,
  savedNetworkPath: savedNetworkPath ?? source.savedNetworkPath,
  connected: source.connected,
  available: source.available,
  supported: source.supported,
);

List<WifiNetwork> legacyNormalizeWifiNetworks(
  Iterable<WifiNetwork> candidates,
  Iterable<SavedWifiConnectionInfo> savedConnections, {
  required String defaultDevicePath,
  int maximum = 64,
}) {
  final visible = <String, WifiNetwork>{};
  for (final candidate in candidates) {
    final current = visible[candidate.identity];
    if (current == null ||
        (!current.connected && candidate.connected) ||
        (current.connected == candidate.connected &&
            candidate.strength > current.strength)) {
      visible[candidate.identity] = candidate;
    }
  }

  final savedByIdentity = <String, SavedWifiConnectionInfo>{};
  for (final saved in savedConnections) {
    savedByIdentity.putIfAbsent(saved.identity, () => saved);
  }
  for (final entry in visible.entries.toList(growable: false)) {
    final saved = savedByIdentity.remove(entry.key);
    if (saved != null) {
      visible[entry.key] = legacyCopyWifiNetwork(
        entry.value,
        savedNetworkPath: saved.objectPath,
      );
    }
  }
  for (final saved in savedByIdentity.values) {
    visible[saved.identity] = WifiNetwork(
      ssid: saved.name,
      ssidBytes: saved.ssidBytes,
      security: saved.security,
      strength: 0,
      frequency: 0,
      devicePath: defaultDevicePath,
      networkPath: '/',
      savedNetworkPath: saved.objectPath,
      connected: false,
      available: false,
    );
  }

  final networks = visible.values.toList(growable: false)
    ..sort((left, right) {
      var result = _trueFirst(left.connected, right.connected);
      if (result != 0) {
        return result;
      }
      result = _trueFirst(left.saved, right.saved);
      if (result != 0) {
        return result;
      }
      result = _trueFirst(left.available, right.available);
      if (result != 0) {
        return result;
      }
      result = right.strength.compareTo(left.strength);
      return result != 0
          ? result
          : left.ssid.toLowerCase().compareTo(right.ssid.toLowerCase());
    });
  return List<WifiNetwork>.unmodifiable(networks.take(maximum));
}

int _trueFirst(bool left, bool right) {
  if (left == right) {
    return 0;
  }
  return left ? -1 : 1;
}
