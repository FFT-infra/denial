import 'package:dbus/dbus.dart';

import '../models/power_profile.dart';

/// Selects a power-profiles-daemon endpoint on a caller-owned bus connection.
/// Discovery returns the profile it already read instead of querying it twice.
final class PowerProfilesClient {
  PowerProfilesClient(DBusClient client)
    : _endpoints = [
        PowerProfilesEndpoint._(
          client,
          'org.freedesktop.UPower.PowerProfiles',
          '/org/freedesktop/UPower/PowerProfiles',
        ),
        PowerProfilesEndpoint._(
          client,
          'net.hadess.PowerProfiles',
          '/net/hadess/PowerProfiles',
        ),
      ];

  final List<PowerProfilesEndpoint> _endpoints;
  PowerProfilesEndpoint? _active;

  Future<String?> readActiveProfile() async {
    final previous = _active;
    if (previous != null) {
      final profile = await previous._readActiveProfile();
      if (profile != null) return profile;
      _active = null;
    }
    for (final endpoint in _endpoints) {
      // A failed cached endpoint was already tried during this refresh. It
      // remains eligible on a later refresh if no other endpoint is available.
      if (identical(endpoint, previous)) continue;
      final profile = await endpoint._readActiveProfile();
      if (profile != null) {
        _active = endpoint;
        return profile;
      }
    }
    return null;
  }

  /// Retains the chosen endpoint for writes, as long as a read has not shown it
  /// unavailable. Callers decide whether a write failure permits a fallback.
  Future<PowerProfilesEndpoint?> resolve() async {
    if (_active case final endpoint?) return endpoint;
    await readActiveProfile();
    return _active;
  }
}

final class PowerProfilesEndpoint {
  PowerProfilesEndpoint._(DBusClient client, this._interface, String path)
    : _object = DBusRemoteObject(
        client,
        name: _interface,
        path: DBusObjectPath(path),
      );

  static const _timeout = Duration(seconds: 3);
  final DBusRemoteObject _object;
  final String _interface;

  Future<String?> _readActiveProfile() async {
    try {
      final value = await _object
          .getProperty(_interface, 'ActiveProfile')
          .timeout(_timeout);
      return value is DBusString ? PowerProfile.normalize(value.value) : null;
    } on Object {
      return null;
    }
  }

  Future<void> setActiveProfile(String profile) => _object
      .setProperty(_interface, 'ActiveProfile', DBusString(profile))
      .timeout(_timeout);
}
