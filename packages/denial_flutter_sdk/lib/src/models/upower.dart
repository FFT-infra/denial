import 'dart:collection';

import 'package:meta/meta.dart';

enum UPowerBatteryState {
  unknown,
  charging,
  discharging,
  empty,
  fullyCharged,
  pendingCharge,
  pendingDischarge,
}

enum UPowerBatteryTechnology {
  unknown,
  lithiumIon,
  lithiumPolymer,
  lithiumIronPhosphate,
  leadAcid,
  nickelCadmium,
  nickelMetalHydride,
}

enum UPowerWarningLevel { unknown, none, discharging, low, critical, action }

@immutable
class UPowerBattery {
  const UPowerBattery({
    required this.objectPath,
    required this.nativePath,
    required this.vendor,
    required this.model,
    required this.serial,
    required this.state,
    required this.technology,
    required this.warningLevel,
    required this.percentage,
    required this.healthPercentage,
    required this.energy,
    required this.energyFull,
    required this.energyFullDesign,
    required this.energyRate,
    required this.voltage,
    required this.temperature,
    required this.timeToEmpty,
    required this.timeToFull,
    required this.chargeCycles,
    required this.chargeThresholdSupported,
    required this.chargeThresholdEnabled,
    required this.chargeThresholdSettings,
    required this.chargeStartThreshold,
    required this.chargeEndThreshold,
  });

  static const int chargeStartSetting = 1;
  static const int chargeEndSetting = 2;
  static const int firmwareOptimizedSetting = 4;

  final String objectPath;
  final String nativePath;
  final String vendor;
  final String model;
  final String serial;
  final UPowerBatteryState state;
  final UPowerBatteryTechnology technology;
  final UPowerWarningLevel warningLevel;
  final double? percentage;
  final double? healthPercentage;
  final double? energy;
  final double? energyFull;
  final double? energyFullDesign;
  final double? energyRate;
  final double? voltage;
  final double? temperature;
  final Duration? timeToEmpty;
  final Duration? timeToFull;
  final int? chargeCycles;
  final bool chargeThresholdSupported;
  final bool chargeThresholdEnabled;
  final int chargeThresholdSettings;
  final int? chargeStartThreshold;
  final int? chargeEndThreshold;

  bool get chargeStartThresholdSupported =>
      chargeThresholdSettings & chargeStartSetting != 0;

  bool get chargeEndThresholdSupported =>
      chargeThresholdSettings & chargeEndSetting != 0;

  bool get firmwareOptimizedChargingSupported =>
      chargeThresholdSettings & firmwareOptimizedSetting != 0;

  String get displayName {
    final vendorName = vendor.trim();
    final modelName = model.trim();
    if (vendorName.isEmpty) {
      return modelName.isEmpty ? nativePath.trim() : modelName;
    }
    return modelName.isEmpty || modelName == vendorName
        ? vendorName
        : '$vendorName $modelName';
  }

  UPowerBattery withChargeThresholdEnabled(bool enabled) {
    if (enabled == chargeThresholdEnabled) return this;
    return UPowerBattery(
      objectPath: objectPath,
      nativePath: nativePath,
      vendor: vendor,
      model: model,
      serial: serial,
      state: state,
      technology: technology,
      warningLevel: warningLevel,
      percentage: percentage,
      healthPercentage: healthPercentage,
      energy: energy,
      energyFull: energyFull,
      energyFullDesign: energyFullDesign,
      energyRate: energyRate,
      voltage: voltage,
      temperature: temperature,
      timeToEmpty: timeToEmpty,
      timeToFull: timeToFull,
      chargeCycles: chargeCycles,
      chargeThresholdSupported: chargeThresholdSupported,
      chargeThresholdEnabled: enabled,
      chargeThresholdSettings: chargeThresholdSettings,
      chargeStartThreshold: chargeStartThreshold,
      chargeEndThreshold: chargeEndThreshold,
    );
  }
}

@immutable
class UPowerSnapshot {
  UPowerSnapshot({
    required this.daemonVersion,
    required this.onBattery,
    required Iterable<UPowerBattery> batteries,
  }) : batteries = List<UPowerBattery>.unmodifiable(batteries);

  UPowerSnapshot._updated(UPowerSnapshot source, List<UPowerBattery> batteries)
    : daemonVersion = source.daemonVersion,
      onBattery = source.onBattery,
      batteries = UnmodifiableListView(batteries);

  final String daemonVersion;
  final bool onBattery;
  final List<UPowerBattery> batteries;

  UPowerSnapshot withChargeThresholdEnabled(String objectPath, bool enabled) {
    List<UPowerBattery>? updated;
    for (var i = 0; i < batteries.length; i++) {
      final battery = batteries[i];
      if (battery.objectPath == objectPath &&
          battery.chargeThresholdEnabled != enabled) {
        updated ??= List.of(batteries);
        updated[i] = battery.withChargeThresholdEnabled(enabled);
      }
    }
    return updated == null ? this : UPowerSnapshot._updated(this, updated);
  }
}
