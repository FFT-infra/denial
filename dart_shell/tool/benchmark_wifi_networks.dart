import 'package:denial_flutter_sdk/src/services/network_backend.dart'
    show normalizeWifiNetworks;

import 'dart:convert';
import 'dart:io';

import 'package:denial_flutter_sdk/system_services.dart';

import '../test/support/legacy_wifi_normalization.dart';

var _checksum = 0;

void main() {
  for (final count in [8, 32, 128]) {
    for (final tiedStrength in [false, true]) {
      final networks = List.generate(count, (i) {
        final name = 'Network ${(count - i).toString().padLeft(3, '0')}';
        return WifiNetwork(
          ssid: name,
          ssidBytes: utf8.encode(name),
          security: WifiSecurity.wpaPersonal,
          strength: tiedStrength ? 50 : (i * 17) % 101,
          frequency: 2400,
          devicePath: '/device',
          networkPath: '/ap/$i',
          savedNetworkPath: null,
          connected: i == 0,
          available: true,
        );
      });
      final saved = [
        for (var i = 0; i < count; i += 2)
          SavedWifiConnectionInfo(
            objectPath: '/saved/$i',
            name: networks[i].ssid,
            ssidBytes: networks[i].ssidBytes,
            security: networks[i].security,
          ),
      ];
      int normalize(bool legacy) {
        final result = legacy
            ? legacyNormalizeWifiNetworks(
                networks,
                saved,
                defaultDevicePath: '/device',
              )
            : normalizeWifiNetworks(
                networks,
                saved,
                defaultDevicePath: '/device',
              );
        return result.length + result.last.strength;
      }

      _compare(
        '$count networks, ${tiedStrength ? "tied" : "mixed"} strengths',
        () => normalize(true),
        () => normalize(false),
        iterations: 5000,
      );
      if (count == 8) {
        final source = networks.first;
        _compare(
          'copy with saved profile',
          () => legacyCopyWifiNetwork(
            source,
            savedNetworkPath: '/saved',
          ).identity.length,
          () => source.copyWith(savedNetworkPath: '/saved').identity.length,
          iterations: 200000,
        );
      }
    }
  }
  stdout.writeln('checksum: $_checksum');
}

void _compare(
  String name,
  int Function() before,
  int Function() after, {
  required int iterations,
}) {
  _measure(before, iterations);
  _measure(after, iterations);
  final oldSamples = <double>[];
  final newSamples = <double>[];
  for (var sample = 0; sample < 7; sample++) {
    if (sample.isEven) {
      oldSamples.add(_measure(before, iterations));
      newSamples.add(_measure(after, iterations));
    } else {
      newSamples.add(_measure(after, iterations));
      oldSamples.add(_measure(before, iterations));
    }
  }
  oldSamples.sort();
  newSamples.sort();
  final beforeNs = oldSamples[3];
  final afterNs = newSamples[3];
  stdout.writeln(
    '$name: ${beforeNs.toStringAsFixed(1)} → ${afterNs.toStringAsFixed(1)} ns (${(beforeNs / afterNs).toStringAsFixed(2)}x)',
  );
}

double _measure(int Function() run, int iterations) {
  final clock = Stopwatch()..start();
  var checksum = 0;
  for (var i = 0; i < iterations; i++) {
    checksum += run();
  }
  clock.stop();
  _checksum += checksum;
  return clock.elapsedTicks * 1e9 / clock.frequency / iterations;
}
