import 'dart:async';
import 'dart:io';

import 'package:denial_sdk/system.dart';

import 'system_io.dart';

/// Reads and aggregates standard Linux battery power supplies from sysfs.
class BatteryService {
  const BatteryService({
    this.powerSupplyRoot = '/sys/class/power_supply',
    this.readAttribute = readSysString,
  });

  final String powerSupplyRoot;

  /// Reads a trimmed attribute, returning null when it is absent or unreadable.
  final Future<String?> Function(String path) readAttribute;

  Future<BatteryStatus> read() async {
    final samples = await _readSamples();
    if (samples.isEmpty) {
      return BatteryStatus.unknown;
    }

    // A real system battery normally publishes its full charge or energy.
    // If any such supplies exist, exclude incomplete firmware placeholders
    // rather than letting a made-up percentage distort the aggregate.
    // This list is owned by the read, so filtering needs no second collection.
    if (samples.any((sample) => sample.weight != null)) {
      samples.removeWhere((sample) => sample.weight == null);
    }
    // energy_full is measured in micro-watt-hours, while charge_full is
    // measured in micro-amp-hours. They are valid relative weights only
    // within their own dimension. If drivers expose a mixed set, retain all
    // measurable batteries and use an unweighted average rather than
    // combining incompatible units.
    final kind = samples.first.weight?.kind;
    final weighted =
        kind != null && samples.every((sample) => sample.weight?.kind == kind);
    var capacityTotal = 0.0;
    var weightTotal = 0.0;
    var charging = false;
    for (final sample in samples) {
      final weight = weighted ? sample.weight!.value : 1.0;
      capacityTotal += sample.capacity * weight;
      weightTotal += weight;
      charging |= sample.charging;
    }
    return BatteryStatus(
      capacity: (capacityTotal / weightTotal).round().clamp(0, 100),
      charging: charging,
    );
  }

  Future<List<_BatterySample>> _readSamples() async {
    try {
      final samples = <_BatterySample>[];
      await for (final entity in Directory(powerSupplyRoot).list()) {
        if (entity is! Directory && entity is! Link) {
          continue;
        }
        final path = entity.path;
        if ((await readAttribute('$path/type'))?.toLowerCase() != 'battery') {
          continue;
        }
        final present = await _readInt('$path/present');
        if (present == 0) {
          continue;
        }
        final (capacity, weight, status) = await (
          _readInt('$path/capacity'),
          _readWeight(path),
          readAttribute('$path/status'),
        ).wait;
        if (capacity == null || capacity < 0 || capacity > 100) {
          continue;
        }
        samples.add(
          _BatterySample(
            capacity: capacity,
            charging: status?.toLowerCase() == 'charging',
            weight: weight,
          ),
        );
      }
      return samples;
    } on FileSystemException {
      return const [];
    }
  }

  Future<int?> _readInt(String path) async {
    final value = await readAttribute(path);
    return value == null ? null : int.tryParse(value);
  }

  Future<_BatteryWeight?> _readWeight(String path) async {
    final energy = await _readInt('$path/energy_full');
    if (energy != null && energy > 0) {
      return (value: energy.toDouble(), kind: _BatteryWeightKind.energy);
    }
    // Charge is only a fallback; energy and charge use incompatible units.
    final charge = await _readInt('$path/charge_full');
    if (charge != null && charge > 0) {
      return (value: charge.toDouble(), kind: _BatteryWeightKind.charge);
    }
    return null;
  }
}

enum _BatteryWeightKind { energy, charge }

typedef _BatteryWeight = ({double value, _BatteryWeightKind kind});

class const _BatterySample({
  required final int capacity,
  required final bool charging,
  required final _BatteryWeight? weight,
});
