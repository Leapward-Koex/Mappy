import 'package:disable_battery_optimization/disable_battery_optimization.dart';
import 'package:flutter/services.dart';

enum BatteryOptimizationState { unknown, disabled, enabled, unavailable }

extension BatteryOptimizationStateDisplay on BatteryOptimizationState {
  bool get isReady => this == BatteryOptimizationState.disabled;

  bool get canRequest =>
      this == BatteryOptimizationState.unknown ||
      this == BatteryOptimizationState.enabled;

  String get label {
    switch (this) {
      case BatteryOptimizationState.unknown:
        return 'Unknown';
      case BatteryOptimizationState.disabled:
        return 'Disabled for Mappy';
      case BatteryOptimizationState.enabled:
        return 'Optimization enabled';
      case BatteryOptimizationState.unavailable:
        return 'Unavailable';
    }
  }
}

abstract class BatteryOptimizationRepository {
  Future<BatteryOptimizationState> getBatteryOptimizationState();

  Future<BatteryOptimizationState> requestDisableBatteryOptimization();
}

class NativeBatteryOptimizationRepository
    implements BatteryOptimizationRepository {
  const NativeBatteryOptimizationRepository();

  @override
  Future<BatteryOptimizationState> getBatteryOptimizationState() async {
    try {
      final disabled =
          await DisableBatteryOptimization.isAllBatteryOptimizationDisabled;
      return _stateFromDisabled(disabled);
    } on MissingPluginException {
      return BatteryOptimizationState.unavailable;
    } on PlatformException {
      return BatteryOptimizationState.unavailable;
    }
  }

  @override
  Future<BatteryOptimizationState> requestDisableBatteryOptimization() async {
    try {
      await DisableBatteryOptimization.showDisableAllOptimizationsSettings(
        'Allow Mappy to start automatically',
        'Enable autostart if this phone asks for it so Mappy can reconnect the watch session after Android reclaims the app.',
        'Disable extra battery optimization',
        'Follow the device-specific steps so Mappy can keep live GPS and route updates flowing to the Pebble watch.',
      );
      final disabled =
          await DisableBatteryOptimization.isAllBatteryOptimizationDisabled;
      return _stateFromDisabled(disabled);
    } on MissingPluginException {
      return BatteryOptimizationState.unavailable;
    } on PlatformException {
      return BatteryOptimizationState.unavailable;
    }
  }

  static BatteryOptimizationState _stateFromDisabled(bool? disabled) {
    if (disabled == null) {
      return BatteryOptimizationState.unknown;
    }
    return disabled
        ? BatteryOptimizationState.disabled
        : BatteryOptimizationState.enabled;
  }
}
