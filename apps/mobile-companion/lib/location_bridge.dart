import 'package:flutter/services.dart';

enum LocationPermissionState {
  unknown,
  requestAvailable,
  grantedPrecise,
  grantedApproximate,
  grantedAlwaysPrecise,
  grantedAlwaysApproximate,
  denied,
  permanentlyDenied,
  serviceDisabled,
  unavailable,
}

enum ForegroundLocationState {
  requestAvailable,
  precise,
  approximate,
  denied,
  permanentlyDenied,
  unavailable,
}

extension ForegroundLocationStateDisplay on ForegroundLocationState {
  bool get allowsLocation =>
      this == ForegroundLocationState.precise ||
      this == ForegroundLocationState.approximate;

  bool get canRequest =>
      this == ForegroundLocationState.requestAvailable ||
      this == ForegroundLocationState.denied;

  String get label {
    switch (this) {
      case ForegroundLocationState.requestAvailable:
        return 'Request available';
      case ForegroundLocationState.precise:
        return 'Precise';
      case ForegroundLocationState.approximate:
        return 'Approximate';
      case ForegroundLocationState.denied:
        return 'Not allowed';
      case ForegroundLocationState.permanentlyDenied:
        return 'System settings required';
      case ForegroundLocationState.unavailable:
        return 'Unavailable';
    }
  }
}

/// Non-lossy view of Android location readiness.
///
/// Location services, foreground accuracy, and background access are separate
/// concerns. Keeping them separate lets the UI offer the correct recovery
/// action without guessing from a combined legacy enum value.
class LocationAccessStatus {
  const LocationAccessStatus({
    required this.servicesEnabled,
    required this.foregroundState,
    required this.backgroundRequired,
    required this.backgroundGranted,
  });

  const LocationAccessStatus.unavailable()
    : servicesEnabled = false,
      foregroundState = ForegroundLocationState.unavailable,
      backgroundRequired = true,
      backgroundGranted = false;

  final bool servicesEnabled;
  final ForegroundLocationState foregroundState;
  final bool backgroundRequired;
  final bool backgroundGranted;

  bool get foregroundGranted => foregroundState.allowsLocation;

  bool get backgroundReady => !backgroundRequired || backgroundGranted;

  bool get isReady => servicesEnabled && foregroundGranted && backgroundReady;

  /// Compatibility projection for code that has not migrated to the richer
  /// status yet. New UI should read the individual fields instead.
  LocationPermissionState get legacyPermissionState {
    if (!foregroundGranted) {
      return switch (foregroundState) {
        ForegroundLocationState.requestAvailable =>
          LocationPermissionState.requestAvailable,
        ForegroundLocationState.denied => LocationPermissionState.denied,
        ForegroundLocationState.permanentlyDenied =>
          LocationPermissionState.permanentlyDenied,
        ForegroundLocationState.unavailable =>
          LocationPermissionState.unavailable,
        ForegroundLocationState.precise ||
        ForegroundLocationState.approximate => LocationPermissionState.unknown,
      };
    }
    if (!servicesEnabled) {
      return LocationPermissionState.serviceDisabled;
    }
    if (foregroundState == ForegroundLocationState.precise) {
      return backgroundReady
          ? LocationPermissionState.grantedAlwaysPrecise
          : LocationPermissionState.grantedPrecise;
    }
    return backgroundReady
        ? LocationPermissionState.grantedAlwaysApproximate
        : LocationPermissionState.grantedApproximate;
  }

  static LocationAccessStatus fromMethodChannel(Object? raw) {
    if (raw is! Map) {
      return const LocationAccessStatus.unavailable();
    }
    final data = Map<Object?, Object?>.from(raw);
    final foregroundState = data['foregroundState'];
    return LocationAccessStatus(
      servicesEnabled: data['servicesEnabled'] == true,
      foregroundState: _foregroundStateFromName(
        foregroundState is String ? foregroundState : null,
      ),
      backgroundRequired: data['backgroundRequired'] != false,
      backgroundGranted: data['backgroundGranted'] == true,
    );
  }

  static LocationAccessStatus fromLegacy(
    LocationPermissionState state, {
    bool? backgroundRequired,
    bool? backgroundGranted,
  }) {
    final inferredBackgroundRequired = backgroundRequired ?? true;
    switch (state) {
      case LocationPermissionState.requestAvailable:
        return LocationAccessStatus(
          servicesEnabled: true,
          foregroundState: ForegroundLocationState.requestAvailable,
          backgroundRequired: inferredBackgroundRequired,
          backgroundGranted: backgroundGranted ?? false,
        );
      case LocationPermissionState.grantedPrecise:
        return LocationAccessStatus(
          servicesEnabled: true,
          foregroundState: ForegroundLocationState.precise,
          backgroundRequired: inferredBackgroundRequired,
          backgroundGranted: backgroundGranted ?? false,
        );
      case LocationPermissionState.grantedApproximate:
        return LocationAccessStatus(
          servicesEnabled: true,
          foregroundState: ForegroundLocationState.approximate,
          backgroundRequired: inferredBackgroundRequired,
          backgroundGranted: backgroundGranted ?? false,
        );
      case LocationPermissionState.grantedAlwaysPrecise:
        return LocationAccessStatus(
          servicesEnabled: true,
          foregroundState: ForegroundLocationState.precise,
          backgroundRequired: inferredBackgroundRequired,
          backgroundGranted: true,
        );
      case LocationPermissionState.grantedAlwaysApproximate:
        return LocationAccessStatus(
          servicesEnabled: true,
          foregroundState: ForegroundLocationState.approximate,
          backgroundRequired: inferredBackgroundRequired,
          backgroundGranted: true,
        );
      case LocationPermissionState.denied:
        return LocationAccessStatus(
          servicesEnabled: true,
          foregroundState: ForegroundLocationState.denied,
          backgroundRequired: inferredBackgroundRequired,
          backgroundGranted: backgroundGranted ?? false,
        );
      case LocationPermissionState.permanentlyDenied:
        return LocationAccessStatus(
          servicesEnabled: true,
          foregroundState: ForegroundLocationState.permanentlyDenied,
          backgroundRequired: inferredBackgroundRequired,
          backgroundGranted: backgroundGranted ?? false,
        );
      case LocationPermissionState.serviceDisabled:
        return LocationAccessStatus(
          servicesEnabled: false,
          foregroundState: ForegroundLocationState.unavailable,
          backgroundRequired: inferredBackgroundRequired,
          backgroundGranted: backgroundGranted ?? false,
        );
      case LocationPermissionState.unknown:
      case LocationPermissionState.unavailable:
        return const LocationAccessStatus.unavailable();
    }
  }

  static ForegroundLocationState _foregroundStateFromName(String? name) {
    switch (name) {
      case 'requestAvailable':
        return ForegroundLocationState.requestAvailable;
      case 'precise':
        return ForegroundLocationState.precise;
      case 'approximate':
        return ForegroundLocationState.approximate;
      case 'denied':
        return ForegroundLocationState.denied;
      case 'permanentlyDenied':
        return ForegroundLocationState.permanentlyDenied;
      case 'unavailable':
      default:
        return ForegroundLocationState.unavailable;
    }
  }
}

extension LocationPermissionStateDisplay on LocationPermissionState {
  bool get allowsLocation =>
      this == LocationPermissionState.grantedPrecise ||
      this == LocationPermissionState.grantedApproximate ||
      this == LocationPermissionState.grantedAlwaysPrecise ||
      this == LocationPermissionState.grantedAlwaysApproximate;

  bool get allowsBackgroundLocation =>
      this == LocationPermissionState.grantedAlwaysPrecise ||
      this == LocationPermissionState.grantedAlwaysApproximate;

  String get label {
    switch (this) {
      case LocationPermissionState.unknown:
        return 'Unknown';
      case LocationPermissionState.requestAvailable:
        return 'Request available';
      case LocationPermissionState.grantedPrecise:
        return 'Granted precise';
      case LocationPermissionState.grantedApproximate:
        return 'Granted approximate';
      case LocationPermissionState.grantedAlwaysPrecise:
        return 'Always precise';
      case LocationPermissionState.grantedAlwaysApproximate:
        return 'Always approximate';
      case LocationPermissionState.denied:
        return 'Denied';
      case LocationPermissionState.permanentlyDenied:
        return 'System settings required';
      case LocationPermissionState.serviceDisabled:
        return 'Location service disabled';
      case LocationPermissionState.unavailable:
        return 'Unavailable';
    }
  }
}

class LocationSnapshot {
  const LocationSnapshot({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracyMeters,
    this.provider,
    this.isFresh = false,
  });

  final double latitude;
  final double longitude;
  final double? accuracyMeters;
  final DateTime timestamp;
  final String? provider;
  final bool isFresh;

  String get coordinateLabel =>
      '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';

  String get freshnessLabel => isFresh ? 'Fresh fix' : 'Stale fix';

  static LocationSnapshot? fromMethodChannel(Object? raw) {
    if (raw is! Map) {
      return null;
    }

    final data = Map<Object?, Object?>.from(raw);
    final latitude = _asDouble(data['latitude']);
    final longitude = _asDouble(data['longitude']);
    final timestampMillis = _asInt(data['timestampMillis']);

    if (latitude == null || longitude == null || timestampMillis == null) {
      return null;
    }

    return LocationSnapshot(
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestampMillis),
      accuracyMeters: _asDouble(data['accuracyMeters']),
      provider: data['provider'] as String?,
      isFresh: data['isFresh'] == true,
    );
  }

  static double? _asDouble(Object? value) {
    if (value is double) {
      return value;
    }
    if (value is int) {
      return value.toDouble();
    }
    return null;
  }

  static int? _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    return null;
  }
}

abstract class LocationRepository {
  const LocationRepository();

  Future<LocationPermissionState> getPermissionState();

  Future<LocationPermissionState> requestLocationPermission();

  Future<LocationAccessStatus> getLocationAccessStatus() async =>
      LocationAccessStatus.fromLegacy(await getPermissionState());

  Future<LocationAccessStatus> requestForegroundLocationPermission() async =>
      LocationAccessStatus.fromLegacy(await requestLocationPermission());

  Future<bool> openAppLocationSettings() async => false;

  Future<bool> openLocationServicesSettings() async => false;

  Future<LocationSnapshot?> getCurrentLocation({Duration? timeout});
}

class NativeLocationRepository extends LocationRepository {
  const NativeLocationRepository();

  static const MethodChannel _channel = MethodChannel(
    'com.leapwardkoex.mappy/location',
  );

  @override
  Future<LocationPermissionState> getPermissionState() async {
    try {
      final result = await _channel.invokeMethod<String>('getPermissionState');
      return _permissionStateFromName(result);
    } on MissingPluginException {
      return LocationPermissionState.unavailable;
    } on PlatformException {
      return LocationPermissionState.unavailable;
    }
  }

  @override
  Future<LocationPermissionState> requestLocationPermission() async {
    try {
      final result = await _channel.invokeMethod<String>(
        'requestLocationPermission',
      );
      return _permissionStateFromName(result);
    } on MissingPluginException {
      return LocationPermissionState.unavailable;
    } on PlatformException {
      return LocationPermissionState.unavailable;
    }
  }

  @override
  Future<LocationAccessStatus> getLocationAccessStatus() async {
    try {
      final result = await _channel.invokeMethod<Object?>(
        'getLocationAccessStatus',
      );
      return LocationAccessStatus.fromMethodChannel(result);
    } on MissingPluginException {
      return const LocationAccessStatus.unavailable();
    } on PlatformException {
      return const LocationAccessStatus.unavailable();
    }
  }

  @override
  Future<LocationAccessStatus> requestForegroundLocationPermission() async {
    try {
      final result = await _channel.invokeMethod<Object?>(
        'requestForegroundLocationPermission',
      );
      return LocationAccessStatus.fromMethodChannel(result);
    } on MissingPluginException {
      return const LocationAccessStatus.unavailable();
    } on PlatformException {
      return const LocationAccessStatus.unavailable();
    }
  }

  @override
  Future<bool> openAppLocationSettings() =>
      _invokeSettingsAction('openAppLocationSettings');

  @override
  Future<bool> openLocationServicesSettings() =>
      _invokeSettingsAction('openLocationServicesSettings');

  @override
  Future<LocationSnapshot?> getCurrentLocation({Duration? timeout}) async {
    try {
      final result = await _channel.invokeMethod<Object?>(
        'getCurrentLocation',
        timeout == null
            ? null
            : <String, Object?>{'timeoutMillis': timeout.inMilliseconds},
      );
      return LocationSnapshot.fromMethodChannel(result);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static LocationPermissionState _permissionStateFromName(String? name) {
    switch (name) {
      case 'requestAvailable':
        return LocationPermissionState.requestAvailable;
      case 'grantedPrecise':
        return LocationPermissionState.grantedPrecise;
      case 'grantedApproximate':
        return LocationPermissionState.grantedApproximate;
      case 'grantedAlwaysPrecise':
        return LocationPermissionState.grantedAlwaysPrecise;
      case 'grantedAlwaysApproximate':
        return LocationPermissionState.grantedAlwaysApproximate;
      case 'denied':
        return LocationPermissionState.denied;
      case 'permanentlyDenied':
        return LocationPermissionState.permanentlyDenied;
      case 'serviceDisabled':
        return LocationPermissionState.serviceDisabled;
      case 'unavailable':
        return LocationPermissionState.unavailable;
      default:
        return LocationPermissionState.unknown;
    }
  }

  static Future<bool> _invokeSettingsAction(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
