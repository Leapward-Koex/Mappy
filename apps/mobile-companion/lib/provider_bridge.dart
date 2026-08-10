import 'dart:convert';

import 'package:flutter/services.dart';

import 'watch_protocol.dart';

enum ProviderValidationState {
  notConfigured,
  notValidated,
  validating,
  valid,
  invalidKey,
  apiDisabled,
  quotaOrBillingIssue,
  providerPermissionDenied,
  networkUnavailable,
  unsupportedRestrictedKeyBehavior,
  unknown,
}

enum TravelMode { drive, walk, bike }

enum PlaceSearchRole { origin, destination }

enum MapTileSource { roadmap, satellite, hybrid, terrain }

enum WatchTileSize { small, medium, large }

extension MapTileSourceDisplay on MapTileSource {
  String get channelName {
    return switch (this) {
      MapTileSource.roadmap => 'roadmap',
      MapTileSource.satellite => 'satellite',
      MapTileSource.hybrid => 'hybrid',
      MapTileSource.terrain => 'terrain',
    };
  }

  String get label {
    return switch (this) {
      MapTileSource.roadmap => 'Road',
      MapTileSource.satellite => 'Satellite',
      MapTileSource.hybrid => 'Hybrid',
      MapTileSource.terrain => 'Terrain',
    };
  }
}

extension WatchTileSizeDisplay on WatchTileSize {
  int get width {
    return switch (this) {
      WatchTileSize.small => 54,
      WatchTileSize.medium => 72,
      WatchTileSize.large => 108,
    };
  }

  int get height {
    return switch (this) {
      WatchTileSize.small => 63,
      WatchTileSize.medium => 84,
      WatchTileSize.large => 126,
    };
  }

  String get channelName => '${width}x$height';

  String get label => channelName;
}

extension TravelModeDisplay on TravelMode {
  String get channelName {
    switch (this) {
      case TravelMode.drive:
        return 'drive';
      case TravelMode.walk:
        return 'walk';
      case TravelMode.bike:
        return 'bike';
    }
  }

  String get label {
    switch (this) {
      case TravelMode.drive:
        return 'Drive';
      case TravelMode.walk:
        return 'Walk';
      case TravelMode.bike:
        return 'Bike';
    }
  }
}

extension PlaceSearchRoleChannel on PlaceSearchRole {
  String get channelName {
    switch (this) {
      case PlaceSearchRole.origin:
        return 'origin';
      case PlaceSearchRole.destination:
        return 'destination';
    }
  }
}

extension ProviderValidationStateDisplay on ProviderValidationState {
  String get label {
    switch (this) {
      case ProviderValidationState.notConfigured:
        return 'Not configured';
      case ProviderValidationState.notValidated:
        return 'Not validated';
      case ProviderValidationState.validating:
        return 'Validating';
      case ProviderValidationState.valid:
        return 'Valid';
      case ProviderValidationState.invalidKey:
        return 'Invalid key';
      case ProviderValidationState.apiDisabled:
        return 'API disabled';
      case ProviderValidationState.quotaOrBillingIssue:
        return 'Quota or billing issue';
      case ProviderValidationState.providerPermissionDenied:
        return 'Provider permission denied';
      case ProviderValidationState.networkUnavailable:
        return 'Network unavailable';
      case ProviderValidationState.unsupportedRestrictedKeyBehavior:
        return 'Restricted-key behavior unsupported';
      case ProviderValidationState.unknown:
        return 'Unknown';
    }
  }
}

class ProviderStatus {
  const ProviderStatus({
    required this.configured,
    required this.validationState,
    this.redactedPreview,
    this.length,
    this.validationDetail,
    this.validationHttpStatus,
    this.updatedAt,
    this.validationUpdatedAt,
    this.packageName,
    this.certSha1,
  });

  const ProviderStatus.notConfigured()
    : configured = false,
      validationState = ProviderValidationState.notConfigured,
      redactedPreview = null,
      length = null,
      validationDetail = null,
      validationHttpStatus = null,
      updatedAt = null,
      validationUpdatedAt = null,
      packageName = null,
      certSha1 = null;

  final bool configured;
  final ProviderValidationState validationState;
  final String? redactedPreview;
  final int? length;
  final String? validationDetail;
  final int? validationHttpStatus;
  final DateTime? updatedAt;
  final DateTime? validationUpdatedAt;
  final String? packageName;
  final String? certSha1;

  String get keyLabel {
    if (!configured) {
      return 'Not configured';
    }
    return redactedPreview ?? 'Configured';
  }

  String get providerLabel => validationState.label;

  static ProviderStatus fromMethodChannel(Object? raw) {
    if (raw is! Map) {
      return const ProviderStatus.notConfigured();
    }

    final data = Map<Object?, Object?>.from(raw);
    return ProviderStatus(
      configured: data['configured'] == true,
      redactedPreview: data['redactedPreview'] as String?,
      length: _asInt(data['length']),
      validationState: _validationStateFromName(
        data['validationState'] as String?,
      ),
      validationDetail: data['validationDetail'] as String?,
      validationHttpStatus: _asInt(data['validationHttpStatus']),
      updatedAt: _dateFromMillis(data['updatedAtMillis']),
      validationUpdatedAt: _dateFromMillis(data['validationUpdatedAtMillis']),
      packageName: data['packageName'] as String?,
      certSha1: data['certSha1'] as String?,
    );
  }

  static DateTime? _dateFromMillis(Object? value) {
    final millis = _asInt(value);
    if (millis == null) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  static int? _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    return null;
  }

  static ProviderValidationState _validationStateFromName(String? name) {
    switch (name) {
      case 'notConfigured':
        return ProviderValidationState.notConfigured;
      case 'notValidated':
        return ProviderValidationState.notValidated;
      case 'validating':
        return ProviderValidationState.validating;
      case 'valid':
        return ProviderValidationState.valid;
      case 'invalidKey':
        return ProviderValidationState.invalidKey;
      case 'apiDisabled':
        return ProviderValidationState.apiDisabled;
      case 'quotaOrBillingIssue':
        return ProviderValidationState.quotaOrBillingIssue;
      case 'providerPermissionDenied':
        return ProviderValidationState.providerPermissionDenied;
      case 'networkUnavailable':
        return ProviderValidationState.networkUnavailable;
      case 'unsupportedRestrictedKeyBehavior':
        return ProviderValidationState.unsupportedRestrictedKeyBehavior;
      default:
        return ProviderValidationState.unknown;
    }
  }
}

class MapTileSettings {
  const MapTileSettings({
    this.source = MapTileSource.roadmap,
    this.tileSize = WatchTileSize.small,
  });

  final MapTileSource source;
  final WatchTileSize tileSize;

  static const defaults = MapTileSettings();

  MapTileSettings copyWith({MapTileSource? source, WatchTileSize? tileSize}) {
    return MapTileSettings(
      source: source ?? this.source,
      tileSize: tileSize ?? this.tileSize,
    );
  }

  Map<String, Object?> toChannelMap() {
    return <String, Object?>{
      'mapSource': source.channelName,
      'watchTileWidth': tileSize.width,
      'watchTileHeight': tileSize.height,
      'watchTileSize': tileSize.channelName,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is MapTileSettings &&
        other.source == source &&
        other.tileSize == tileSize;
  }

  @override
  int get hashCode => Object.hash(source, tileSize);

  static MapTileSettings fromMethodChannel(Object? raw) {
    if (raw is! Map) {
      return defaults;
    }
    final data = Map<Object?, Object?>.from(raw);
    return MapTileSettings(
      source: _sourceFromName(_stringValue(data, 'mapSource', 'map_source')),
      tileSize: _tileSizeFromData(data),
    );
  }

  static String? _stringValue(
    Map<Object?, Object?> data,
    String primary,
    String fallback,
  ) => (data[primary] ?? data[fallback]) as String?;

  static int? _intValue(
    Map<Object?, Object?> data,
    String primary,
    String fallback,
  ) {
    final value = data[primary] ?? data[fallback];
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  static MapTileSource _sourceFromName(String? name) {
    return switch (name) {
      'satellite' => MapTileSource.satellite,
      'hybrid' => MapTileSource.hybrid,
      'terrain' => MapTileSource.terrain,
      _ => MapTileSource.roadmap,
    };
  }

  static WatchTileSize _tileSizeFromData(Map<Object?, Object?> data) {
    final size = _stringValue(data, 'watchTileSize', 'watch_tile_size');
    if (size != null) {
      switch (size.trim().toLowerCase()) {
        case '72x84':
          return WatchTileSize.medium;
        case '108x126':
          return WatchTileSize.large;
        case '54x63':
          return WatchTileSize.small;
      }
    }
    final width = _intValue(data, 'watchTileWidth', 'watch_tile_width');
    final height = _intValue(data, 'watchTileHeight', 'watch_tile_height');
    if (width == 72 && height == 84) {
      return WatchTileSize.medium;
    }
    if (width == 108 && height == 126) {
      return WatchTileSize.large;
    }
    return WatchTileSize.small;
  }
}

class MapTileSettingsResult {
  const MapTileSettingsResult({
    required this.ok,
    required this.status,
    required this.settings,
    this.changed = false,
    this.detail,
    this.watchMessage,
  });

  final bool ok;
  final ProviderStatus status;
  final MapTileSettings settings;
  final bool changed;
  final String? detail;
  final WatchMessage? watchMessage;

  static const unavailable = MapTileSettingsResult(
    ok: false,
    status: ProviderStatus.notConfigured(),
    settings: MapTileSettings.defaults,
    detail: 'Native map tile settings are unavailable.',
  );

  static MapTileSettingsResult fromMethodChannel(Object? raw) {
    if (raw is! Map) {
      return unavailable;
    }
    final data = Map<Object?, Object?>.from(raw);
    return MapTileSettingsResult(
      ok: data['ok'] == true,
      status: ProviderStatus.fromMethodChannel(data['providerStatus']),
      settings: MapTileSettings.fromMethodChannel(data['settings']),
      changed: data['changed'] == true,
      detail: data['detail'] as String?,
      watchMessage: _watchMessageFromRaw(data['watchMessage']),
    );
  }

  static WatchMessage? _watchMessageFromRaw(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    return WatchMessage(
      raw.map((key, value) => MapEntry(key.toString(), value)),
    );
  }
}

class PreviewTile {
  const PreviewTile({
    required this.imageBytes,
    required this.tileX,
    required this.tileY,
    required this.zoom,
    required this.markerOffsetX,
    required this.markerOffsetY,
    required this.tileWidth,
    required this.tileHeight,
    this.attribution,
  });

  final Uint8List imageBytes;
  final int tileX;
  final int tileY;
  final int zoom;
  final double markerOffsetX;
  final double markerOffsetY;
  final int tileWidth;
  final int tileHeight;
  final String? attribution;

  double get markerFractionX => markerOffsetX / tileWidth;

  double get markerFractionY => markerOffsetY / tileHeight;

  static PreviewTile? fromMethodChannel(Object? raw) {
    if (raw is! Map) {
      return null;
    }

    final data = Map<Object?, Object?>.from(raw);
    if (data['ok'] != true) {
      return null;
    }

    final imageBase64 = data['imageBase64'] as String?;
    final tileX = ProviderStatus._asInt(data['tileX']);
    final tileY = ProviderStatus._asInt(data['tileY']);
    final zoom = ProviderStatus._asInt(data['zoom']);
    final tileWidth = ProviderStatus._asInt(data['tileWidth']);
    final tileHeight = ProviderStatus._asInt(data['tileHeight']);
    final markerOffsetX = _asDouble(data['markerOffsetX']);
    final markerOffsetY = _asDouble(data['markerOffsetY']);

    if (imageBase64 == null ||
        tileX == null ||
        tileY == null ||
        zoom == null ||
        tileWidth == null ||
        tileHeight == null ||
        markerOffsetX == null ||
        markerOffsetY == null) {
      return null;
    }

    return PreviewTile(
      imageBytes: base64Decode(imageBase64),
      tileX: tileX,
      tileY: tileY,
      zoom: zoom,
      markerOffsetX: markerOffsetX,
      markerOffsetY: markerOffsetY,
      tileWidth: tileWidth,
      tileHeight: tileHeight,
      attribution: data['attribution'] as String?,
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
}

class PreviewTileResult {
  const PreviewTileResult({required this.status, this.tile, this.detail});

  final ProviderStatus status;
  final PreviewTile? tile;
  final String? detail;

  static PreviewTileResult fromMethodChannel(Object? raw) {
    if (raw is! Map) {
      return const PreviewTileResult(status: ProviderStatus.notConfigured());
    }

    final data = Map<Object?, Object?>.from(raw);
    return PreviewTileResult(
      status: ProviderStatus.fromMethodChannel(data['providerStatus']),
      tile: PreviewTile.fromMethodChannel(data),
      detail: data['detail'] as String?,
    );
  }
}

class WatchTileResult {
  const WatchTileResult({
    required this.ok,
    required this.status,
    this.worldX,
    this.worldY,
    this.zoom,
    this.totalBytes,
    this.chunkData,
    this.detail,
    this.errorCategory,
    this.attribution,
  });

  final bool ok;
  final ProviderStatus status;
  final int? worldX;
  final int? worldY;
  final int? zoom;
  final int? totalBytes;
  final Uint8List? chunkData;
  final String? detail;
  final int? errorCategory;
  final String? attribution;

  static WatchTileResult fromMethodChannel(Object? raw) {
    if (raw is! Map) {
      return const WatchTileResult(
        ok: false,
        status: ProviderStatus.notConfigured(),
        detail: 'No watch tile response.',
      );
    }

    final data = Map<Object?, Object?>.from(raw);
    return WatchTileResult(
      ok: data['ok'] == true,
      status: ProviderStatus.fromMethodChannel(data['providerStatus']),
      worldX: ProviderStatus._asInt(data['world_x']),
      worldY: ProviderStatus._asInt(data['world_y']),
      zoom: ProviderStatus._asInt(data['tile_zoom']),
      totalBytes: ProviderStatus._asInt(data['total_bytes']),
      chunkData: _asBytes(data['chunk_data']),
      detail: data['detail'] as String?,
      errorCategory: ProviderStatus._asInt(data['errorCategory']),
      attribution: data['attribution'] as String?,
    );
  }

  static Uint8List? _asBytes(Object? value) {
    if (value is Uint8List) {
      return value;
    }
    if (value is List<int>) {
      return Uint8List.fromList(value);
    }
    if (value is String) {
      try {
        return base64Decode(value);
      } on FormatException {
        return null;
      }
    }
    return null;
  }
}

class GeocodeResult {
  const GeocodeResult({
    required this.ok,
    required this.status,
    this.latitude,
    this.longitude,
    this.formattedAddress,
    this.placeId,
    this.provider,
    this.detail,
    this.errorCategory,
  });

  final bool ok;
  final ProviderStatus status;
  final double? latitude;
  final double? longitude;
  final String? formattedAddress;
  final String? placeId;
  final String? provider;
  final String? detail;
  final int? errorCategory;

  String get coordinateLabel {
    final latitude = this.latitude;
    final longitude = this.longitude;
    if (latitude == null || longitude == null) {
      return 'No coordinates';
    }
    return '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';
  }

  static GeocodeResult fromMethodChannel(Object? raw) {
    if (raw is! Map) {
      return const GeocodeResult(
        ok: false,
        status: ProviderStatus.notConfigured(),
        detail: 'No geocoding response.',
      );
    }

    final data = Map<Object?, Object?>.from(raw);
    return GeocodeResult(
      ok: data['ok'] == true,
      status: ProviderStatus.fromMethodChannel(data['providerStatus']),
      latitude: PreviewTile._asDouble(data['latitude']),
      longitude: PreviewTile._asDouble(data['longitude']),
      formattedAddress: data['formattedAddress'] as String?,
      placeId: data['placeId'] as String?,
      provider: data['provider'] as String?,
      detail: data['detail'] as String?,
      errorCategory: ProviderStatus._asInt(data['errorCategory']),
    );
  }
}

class PlaceAutocompleteSuggestion {
  const PlaceAutocompleteSuggestion({
    required this.placeId,
    required this.primaryText,
    required this.secondaryText,
    required this.fullText,
  });

  final String placeId;
  final String primaryText;
  final String secondaryText;
  final String fullText;

  String get displayText => fullText.isEmpty
      ? [
          primaryText,
          secondaryText,
        ].where((value) => value.isNotEmpty).join(', ')
      : fullText;

  static PlaceAutocompleteSuggestion? fromMethodChannel(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final data = Map<Object?, Object?>.from(raw);
    final placeId = data['placeId'] as String?;
    final primaryText = data['primaryText'] as String? ?? '';
    final secondaryText = data['secondaryText'] as String? ?? '';
    final fullText = data['fullText'] as String? ?? '';
    if (placeId == null || placeId.isEmpty) {
      return null;
    }
    return PlaceAutocompleteSuggestion(
      placeId: placeId,
      primaryText: primaryText,
      secondaryText: secondaryText,
      fullText: fullText,
    );
  }
}

class PlaceAutocompleteResult {
  const PlaceAutocompleteResult({
    required this.ok,
    required this.status,
    this.suggestions = const [],
    this.detail,
    this.errorCategory,
    this.attribution,
  });

  final bool ok;
  final ProviderStatus status;
  final List<PlaceAutocompleteSuggestion> suggestions;
  final String? detail;
  final int? errorCategory;
  final String? attribution;

  static PlaceAutocompleteResult fromMethodChannel(Object? raw) {
    if (raw is! Map) {
      return const PlaceAutocompleteResult(
        ok: false,
        status: ProviderStatus.notConfigured(),
        detail: 'No autocomplete response.',
      );
    }

    final data = Map<Object?, Object?>.from(raw);
    final rawSuggestions = data['suggestions'];
    return PlaceAutocompleteResult(
      ok: data['ok'] == true,
      status: ProviderStatus.fromMethodChannel(data['providerStatus']),
      suggestions: rawSuggestions is List
          ? rawSuggestions
                .map(PlaceAutocompleteSuggestion.fromMethodChannel)
                .whereType<PlaceAutocompleteSuggestion>()
                .toList(growable: false)
          : const [],
      detail: data['detail'] as String?,
      errorCategory: ProviderStatus._asInt(data['errorCategory']),
      attribution: data['attribution'] as String?,
    );
  }
}

class PlaceResolutionResult {
  const PlaceResolutionResult({
    required this.ok,
    required this.status,
    this.latitude,
    this.longitude,
    this.label,
    this.formattedAddress,
    this.placeId,
    this.provider,
    this.detail,
    this.errorCategory,
    this.attribution,
  });

  final bool ok;
  final ProviderStatus status;
  final double? latitude;
  final double? longitude;
  final String? label;
  final String? formattedAddress;
  final String? placeId;
  final String? provider;
  final String? detail;
  final int? errorCategory;
  final String? attribution;

  String get coordinateLabel {
    final latitude = this.latitude;
    final longitude = this.longitude;
    if (latitude == null || longitude == null) {
      return 'No coordinates';
    }
    return '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';
  }

  static PlaceResolutionResult fromMethodChannel(Object? raw) {
    if (raw is! Map) {
      return const PlaceResolutionResult(
        ok: false,
        status: ProviderStatus.notConfigured(),
        detail: 'No place detail response.',
      );
    }

    final data = Map<Object?, Object?>.from(raw);
    return PlaceResolutionResult(
      ok: data['ok'] == true,
      status: ProviderStatus.fromMethodChannel(data['providerStatus']),
      latitude: PreviewTile._asDouble(data['latitude']),
      longitude: PreviewTile._asDouble(data['longitude']),
      label: data['label'] as String?,
      formattedAddress: data['formattedAddress'] as String?,
      placeId: data['placeId'] as String?,
      provider: data['provider'] as String?,
      detail: data['detail'] as String?,
      errorCategory: ProviderStatus._asInt(data['errorCategory']),
      attribution: data['attribution'] as String?,
    );
  }
}

class RoutePoint {
  const RoutePoint({
    required this.latitude,
    required this.longitude,
    required this.worldX,
    required this.worldY,
  });

  final double latitude;
  final double longitude;
  final int worldX;
  final int worldY;

  static RoutePoint? fromMethodChannel(Object? raw) {
    if (raw is! Map) {
      return null;
    }

    final data = Map<Object?, Object?>.from(raw);
    final latitude = PreviewTile._asDouble(data['latitude']);
    final longitude = PreviewTile._asDouble(data['longitude']);
    final worldX = ProviderStatus._asInt(data['worldX']);
    final worldY = ProviderStatus._asInt(data['worldY']);
    if (latitude == null ||
        longitude == null ||
        worldX == null ||
        worldY == null) {
      return null;
    }

    return RoutePoint(
      latitude: latitude,
      longitude: longitude,
      worldX: worldX,
      worldY: worldY,
    );
  }
}

class RouteStep {
  const RouteStep({
    required this.index,
    required this.startLatitude,
    required this.startLongitude,
    required this.startWorldX,
    required this.startWorldY,
    required this.instruction,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.remainingMeters,
    required this.remainingSeconds,
  });

  final int index;
  final double startLatitude;
  final double startLongitude;
  final int startWorldX;
  final int startWorldY;
  final String instruction;
  final int distanceMeters;
  final int durationSeconds;
  final int remainingMeters;
  final int remainingSeconds;

  static RouteStep? fromMethodChannel(Object? raw) {
    if (raw is! Map) {
      return null;
    }

    final data = Map<Object?, Object?>.from(raw);
    final index = ProviderStatus._asInt(data['index']);
    final startLatitude = PreviewTile._asDouble(data['startLatitude']);
    final startLongitude = PreviewTile._asDouble(data['startLongitude']);
    final startWorldX = ProviderStatus._asInt(data['startWorldX']);
    final startWorldY = ProviderStatus._asInt(data['startWorldY']);
    final instruction = data['instruction'] as String?;
    final distanceMeters = ProviderStatus._asInt(data['distanceMeters']);
    final durationSeconds = ProviderStatus._asInt(data['durationSeconds']);
    final remainingMeters = ProviderStatus._asInt(data['remainingMeters']);
    final remainingSeconds = ProviderStatus._asInt(data['remainingSeconds']);
    if (index == null ||
        startLatitude == null ||
        startLongitude == null ||
        startWorldX == null ||
        startWorldY == null ||
        instruction == null ||
        distanceMeters == null ||
        durationSeconds == null ||
        remainingMeters == null ||
        remainingSeconds == null) {
      return null;
    }

    return RouteStep(
      index: index,
      startLatitude: startLatitude,
      startLongitude: startLongitude,
      startWorldX: startWorldX,
      startWorldY: startWorldY,
      instruction: instruction,
      distanceMeters: distanceMeters,
      durationSeconds: durationSeconds,
      remainingMeters: remainingMeters,
      remainingSeconds: remainingSeconds,
    );
  }
}

class RouteResult {
  const RouteResult({
    required this.ok,
    required this.status,
    this.travelMode,
    this.distanceMeters,
    this.durationSeconds,
    this.destinationLatitude,
    this.destinationLongitude,
    this.formattedAddress,
    this.placeId,
    this.encodedPolyline,
    this.routePoints = const [],
    List<RoutePoint>? fullRoutePoints,
    this.steps = const [],
    this.detail,
    this.errorCategory,
    this.routeWarning,
    this.attribution,
  }) : fullRoutePoints = fullRoutePoints ?? routePoints;

  final bool ok;
  final ProviderStatus status;
  final TravelMode? travelMode;
  final int? distanceMeters;
  final int? durationSeconds;
  final double? destinationLatitude;
  final double? destinationLongitude;
  final String? formattedAddress;
  final String? placeId;
  final String? encodedPolyline;
  final List<RoutePoint> routePoints;
  final List<RoutePoint> fullRoutePoints;
  final List<RouteStep> steps;
  final String? detail;
  final int? errorCategory;
  final String? routeWarning;
  final String? attribution;

  String get summaryLabel {
    final distanceMeters = this.distanceMeters;
    final durationSeconds = this.durationSeconds;
    if (!ok || distanceMeters == null || durationSeconds == null) {
      return detail ?? 'Route unavailable';
    }
    final distanceKm = distanceMeters / 1000;
    final minutes = (durationSeconds / 60).round().clamp(1, 9999);
    return '${distanceKm.toStringAsFixed(distanceKm >= 10 ? 0 : 1)} km, $minutes min';
  }

  static RouteResult fromMethodChannel(Object? raw) {
    if (raw is! Map) {
      return const RouteResult(
        ok: false,
        status: ProviderStatus.notConfigured(),
        detail: 'No route response.',
      );
    }

    final data = Map<Object?, Object?>.from(raw);
    final rawPoints = data['routePoints'];
    final rawFullPoints = data['fullRoutePoints'];
    final rawSteps = data['steps'];
    final routePoints = rawPoints is List
        ? rawPoints
              .map(RoutePoint.fromMethodChannel)
              .whereType<RoutePoint>()
              .toList(growable: false)
        : const <RoutePoint>[];
    final fullRoutePoints = rawFullPoints is List
        ? rawFullPoints
              .map(RoutePoint.fromMethodChannel)
              .whereType<RoutePoint>()
              .toList(growable: false)
        : routePoints;
    return RouteResult(
      ok: data['ok'] == true,
      status: ProviderStatus.fromMethodChannel(data['providerStatus']),
      travelMode: _travelModeFromName(data['travelMode'] as String?),
      distanceMeters: ProviderStatus._asInt(data['distanceMeters']),
      durationSeconds: ProviderStatus._asInt(data['durationSeconds']),
      destinationLatitude: PreviewTile._asDouble(data['destinationLatitude']),
      destinationLongitude: PreviewTile._asDouble(data['destinationLongitude']),
      formattedAddress: data['formattedAddress'] as String?,
      placeId: data['placeId'] as String?,
      encodedPolyline: data['encodedPolyline'] as String?,
      routePoints: routePoints,
      fullRoutePoints: fullRoutePoints,
      steps: rawSteps is List
          ? rawSteps
                .map(RouteStep.fromMethodChannel)
                .whereType<RouteStep>()
                .toList(growable: false)
          : const [],
      detail: data['detail'] as String?,
      errorCategory: ProviderStatus._asInt(data['errorCategory']),
      routeWarning: data['routeWarning'] as String?,
      attribution: data['attribution'] as String?,
    );
  }

  static TravelMode? _travelModeFromName(String? name) {
    switch (name) {
      case 'drive':
        return TravelMode.drive;
      case 'walk':
        return TravelMode.walk;
      case 'bike':
        return TravelMode.bike;
      default:
        return null;
    }
  }
}

abstract class ProviderRepository {
  Future<ProviderStatus> getProviderStatus();

  Future<ProviderStatus> storeApiKey(String apiKey);

  Future<ProviderStatus> clearApiKey();

  Future<ProviderStatus> validateProviderSetup();

  Future<MapTileSettingsResult> getMapTileSettings();

  Future<MapTileSettingsResult> setMapTileSettings(MapTileSettings settings);

  Future<MapTileSettingsResult> clearMapTileCache();

  Future<ProviderStatus> clearProviderValidationCache();

  Future<GeocodeResult> geocodeDestination({
    required String addressText,
    String language = 'en-US',
    String region = 'US',
  });

  Future<PlaceAutocompleteResult> autocompleteDestination({
    required String input,
    double? originLatitude,
    double? originLongitude,
    String? sessionToken,
    String language = 'en-US',
    String region = 'US',
  });

  Future<PlaceAutocompleteResult> searchPlaces({
    required String input,
    PlaceSearchRole role = PlaceSearchRole.destination,
    double? originLatitude,
    double? originLongitude,
    String? sessionToken,
    String language = 'en-US',
    String region = 'US',
  }) => autocompleteDestination(
    input: input,
    originLatitude: originLatitude,
    originLongitude: originLongitude,
    sessionToken: sessionToken,
    language: language,
    region: region,
  );

  Future<PlaceResolutionResult> resolvePlace({
    required String placeId,
    String? sessionToken,
    String language = 'en-US',
    String region = 'US',
  });

  Future<RouteResult> computeRoute({
    required double originLatitude,
    required double originLongitude,
    required String destinationAddress,
    double? destinationLatitude,
    double? destinationLongitude,
    required TravelMode travelMode,
    String language = 'en-US',
    String region = 'US',
  });

  Future<PreviewTileResult> getPreviewTile({
    required double latitude,
    required double longitude,
    int zoom = 16,
  });

  Future<WatchTileResult> getWatchTile({
    required int worldX,
    required int worldY,
    required int zoom,
    int themeMode = 0,
  });
}

class NativeProviderRepository implements ProviderRepository {
  const NativeProviderRepository();

  static const MethodChannel _channel = MethodChannel(
    'com.leapwardkoex.mappy/provider',
  );

  @override
  Future<ProviderStatus> getProviderStatus() async {
    try {
      final result = await _channel.invokeMethod<Object?>('getProviderStatus');
      return ProviderStatus.fromMethodChannel(result);
    } on MissingPluginException {
      return const ProviderStatus.notConfigured();
    } on PlatformException {
      return const ProviderStatus.notConfigured();
    }
  }

  @override
  Future<ProviderStatus> storeApiKey(String apiKey) async {
    try {
      final result = await _channel.invokeMethod<Object?>(
        'storeApiKey',
        <String, Object?>{'apiKey': apiKey},
      );
      return ProviderStatus.fromMethodChannel(result);
    } on MissingPluginException {
      return const ProviderStatus.notConfigured();
    } on PlatformException {
      return const ProviderStatus.notConfigured();
    }
  }

  @override
  Future<ProviderStatus> clearApiKey() async {
    try {
      final result = await _channel.invokeMethod<Object?>('clearApiKey');
      return ProviderStatus.fromMethodChannel(result);
    } on MissingPluginException {
      return const ProviderStatus.notConfigured();
    } on PlatformException {
      return const ProviderStatus.notConfigured();
    }
  }

  @override
  Future<ProviderStatus> validateProviderSetup() async {
    try {
      final result = await _channel.invokeMethod<Object?>(
        'validateProviderSetup',
      );
      return ProviderStatus.fromMethodChannel(result);
    } on MissingPluginException {
      return const ProviderStatus.notConfigured();
    } on PlatformException {
      return const ProviderStatus.notConfigured();
    }
  }

  @override
  Future<MapTileSettingsResult> getMapTileSettings() async {
    try {
      final result = await _channel.invokeMethod<Object?>('getMapTileSettings');
      return MapTileSettingsResult.fromMethodChannel(result);
    } on MissingPluginException {
      return MapTileSettingsResult.unavailable;
    } on PlatformException {
      return MapTileSettingsResult.unavailable;
    }
  }

  @override
  Future<MapTileSettingsResult> setMapTileSettings(
    MapTileSettings settings,
  ) async {
    try {
      final result = await _channel.invokeMethod<Object?>(
        'setMapTileSettings',
        settings.toChannelMap(),
      );
      return MapTileSettingsResult.fromMethodChannel(result);
    } on MissingPluginException {
      return MapTileSettingsResult.unavailable;
    } on PlatformException {
      return MapTileSettingsResult.unavailable;
    }
  }

  @override
  Future<MapTileSettingsResult> clearMapTileCache() async {
    try {
      final result = await _channel.invokeMethod<Object?>('clearMapTileCache');
      return MapTileSettingsResult.fromMethodChannel(result);
    } on MissingPluginException {
      return MapTileSettingsResult.unavailable;
    } on PlatformException {
      return MapTileSettingsResult.unavailable;
    }
  }

  @override
  Future<ProviderStatus> clearProviderValidationCache() async {
    try {
      final result = await _channel.invokeMethod<Object?>(
        'clearProviderValidationCache',
      );
      return ProviderStatus.fromMethodChannel(result);
    } on MissingPluginException {
      return const ProviderStatus.notConfigured();
    } on PlatformException {
      return const ProviderStatus.notConfigured();
    }
  }

  @override
  Future<GeocodeResult> geocodeDestination({
    required String addressText,
    String language = 'en-US',
    String region = 'US',
  }) async {
    try {
      final result = await _channel.invokeMethod<Object?>(
        'geocodeDestination',
        <String, Object?>{
          'addressText': addressText,
          'language': language,
          'region': region,
        },
      );
      return GeocodeResult.fromMethodChannel(result);
    } on MissingPluginException {
      return const GeocodeResult(
        status: ProviderStatus.notConfigured(),
        ok: false,
      );
    } on PlatformException {
      return const GeocodeResult(
        status: ProviderStatus.notConfigured(),
        ok: false,
      );
    }
  }

  @override
  Future<PlaceAutocompleteResult> autocompleteDestination({
    required String input,
    double? originLatitude,
    double? originLongitude,
    String? sessionToken,
    String language = 'en-US',
    String region = 'US',
  }) async {
    try {
      final result = await _channel
          .invokeMethod<Object?>('autocompleteDestination', <String, Object?>{
            'input': input,
            'originLatitude': originLatitude,
            'originLongitude': originLongitude,
            'sessionToken': sessionToken,
            'language': language,
            'region': region,
          });
      return PlaceAutocompleteResult.fromMethodChannel(result);
    } on MissingPluginException {
      return const PlaceAutocompleteResult(
        status: ProviderStatus.notConfigured(),
        ok: false,
      );
    } on PlatformException {
      return const PlaceAutocompleteResult(
        status: ProviderStatus.notConfigured(),
        ok: false,
      );
    }
  }

  @override
  Future<PlaceAutocompleteResult> searchPlaces({
    required String input,
    PlaceSearchRole role = PlaceSearchRole.destination,
    double? originLatitude,
    double? originLongitude,
    String? sessionToken,
    String language = 'en-US',
    String region = 'US',
  }) async {
    try {
      final result = await _channel
          .invokeMethod<Object?>('searchPlaces', <String, Object?>{
            'input': input,
            'role': role.channelName,
            'originLatitude': originLatitude,
            'originLongitude': originLongitude,
            'sessionToken': sessionToken,
            'language': language,
            'region': region,
          });
      return PlaceAutocompleteResult.fromMethodChannel(result);
    } on MissingPluginException {
      return autocompleteDestination(
        input: input,
        originLatitude: originLatitude,
        originLongitude: originLongitude,
        sessionToken: sessionToken,
        language: language,
        region: region,
      );
    } on PlatformException {
      return const PlaceAutocompleteResult(
        status: ProviderStatus.notConfigured(),
        ok: false,
      );
    }
  }

  @override
  Future<PlaceResolutionResult> resolvePlace({
    required String placeId,
    String? sessionToken,
    String language = 'en-US',
    String region = 'US',
  }) async {
    try {
      final result = await _channel
          .invokeMethod<Object?>('resolvePlace', <String, Object?>{
            'placeId': placeId,
            'sessionToken': sessionToken,
            'language': language,
            'region': region,
          });
      return PlaceResolutionResult.fromMethodChannel(result);
    } on MissingPluginException {
      return const PlaceResolutionResult(
        status: ProviderStatus.notConfigured(),
        ok: false,
      );
    } on PlatformException {
      return const PlaceResolutionResult(
        status: ProviderStatus.notConfigured(),
        ok: false,
      );
    }
  }

  @override
  Future<RouteResult> computeRoute({
    required double originLatitude,
    required double originLongitude,
    required String destinationAddress,
    double? destinationLatitude,
    double? destinationLongitude,
    required TravelMode travelMode,
    String language = 'en-US',
    String region = 'US',
  }) async {
    try {
      final result = await _channel
          .invokeMethod<Object?>('computeRoute', <String, Object?>{
            'originLatitude': originLatitude,
            'originLongitude': originLongitude,
            'destinationAddress': destinationAddress,
            'destinationLatitude': destinationLatitude,
            'destinationLongitude': destinationLongitude,
            'travelMode': travelMode.channelName,
            'language': language,
            'region': region,
          });
      return RouteResult.fromMethodChannel(result);
    } on MissingPluginException {
      return const RouteResult(
        status: ProviderStatus.notConfigured(),
        ok: false,
      );
    } on PlatformException {
      return const RouteResult(
        status: ProviderStatus.notConfigured(),
        ok: false,
      );
    }
  }

  @override
  Future<PreviewTileResult> getPreviewTile({
    required double latitude,
    required double longitude,
    int zoom = 16,
  }) async {
    try {
      final result = await _channel.invokeMethod<Object?>(
        'getPreviewTile',
        <String, Object?>{
          'latitude': latitude,
          'longitude': longitude,
          'zoom': zoom,
        },
      );
      return PreviewTileResult.fromMethodChannel(result);
    } on MissingPluginException {
      return const PreviewTileResult(status: ProviderStatus.notConfigured());
    } on PlatformException {
      return const PreviewTileResult(status: ProviderStatus.notConfigured());
    }
  }

  @override
  Future<WatchTileResult> getWatchTile({
    required int worldX,
    required int worldY,
    required int zoom,
    int themeMode = 0,
  }) async {
    try {
      final result = await _channel.invokeMethod<Object?>(
        'getWatchTile',
        <String, Object?>{
          'worldX': worldX,
          'worldY': worldY,
          'zoom': zoom,
          'themeMode': themeMode,
        },
      );
      return WatchTileResult.fromMethodChannel(result);
    } on MissingPluginException {
      return const WatchTileResult(
        ok: false,
        status: ProviderStatus.notConfigured(),
        detail: 'Native watch tile provider is unavailable.',
        errorCategory: 5,
      );
    } on PlatformException {
      return const WatchTileResult(
        ok: false,
        status: ProviderStatus.notConfigured(),
        detail: 'Native watch tile provider failed.',
        errorCategory: 5,
      );
    }
  }
}
