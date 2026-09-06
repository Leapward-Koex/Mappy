import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

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

  Future<bool> openBatterySettings();
}

class NativeBatteryOptimizationRepository
    implements BatteryOptimizationRepository {
  const NativeBatteryOptimizationRepository();

  static bool get _isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<BatteryOptimizationState> getBatteryOptimizationState() async {
    if (!_isSupported) return BatteryOptimizationState.unavailable;
    try {
      return _stateFromPermission(
        await Permission.ignoreBatteryOptimizations.status,
      );
    } on MissingPluginException {
      return BatteryOptimizationState.unavailable;
    } on PlatformException {
      return BatteryOptimizationState.unavailable;
    }
  }

  @override
  Future<BatteryOptimizationState> requestDisableBatteryOptimization() async {
    if (!_isSupported) return BatteryOptimizationState.unavailable;
    try {
      // The request completes after the dialog returns and checks the actual
      // Android exemption, including when the user declines it.
      return _stateFromPermission(
        await Permission.ignoreBatteryOptimizations.request(),
      );
    } on MissingPluginException {
      return BatteryOptimizationState.unavailable;
    } on PlatformException {
      return BatteryOptimizationState.unavailable;
    }
  }

  @override
  Future<bool> openBatterySettings() async {
    if (!_isSupported) return false;
    try {
      return await openAppSettings();
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  // Manufacturer autostart and sleeping-app settings cannot be verified by
  // Android's permission API. Only the system battery exemption counts here.
  static BatteryOptimizationState _stateFromPermission(
    PermissionStatus status,
  ) => switch (status) {
    PermissionStatus.granted => BatteryOptimizationState.disabled,
    PermissionStatus.denied ||
    PermissionStatus.permanentlyDenied => BatteryOptimizationState.enabled,
    PermissionStatus.restricted => BatteryOptimizationState.unavailable,
    PermissionStatus.limited ||
    PermissionStatus.provisional => BatteryOptimizationState.unknown,
  };
}
