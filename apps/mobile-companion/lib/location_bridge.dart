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
  Future<LocationPermissionState> getPermissionState();

  Future<LocationPermissionState> requestLocationPermission();

  Future<LocationSnapshot?> getCurrentLocation({Duration? timeout});
}

class NativeLocationRepository implements LocationRepository {
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
}
