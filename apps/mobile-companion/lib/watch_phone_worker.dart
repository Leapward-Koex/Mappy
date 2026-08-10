import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'location_bridge.dart';
import 'provider_bridge.dart';
import 'watch_protocol.dart';

abstract class WatchMessageDispatcher {
  Future<List<WatchMessage>> handleWatchMessage(WatchMessage message);

  Future<void> sendPhoneMessage(WatchMessage message);

  Future<List<WatchDestinationConfig>> getDestinations();

  Future<WatchDisplaySettings> getDisplaySettings();

  Future<List<WatchMessage>> setDisplaySettings(WatchDisplaySettings settings);

  Future<List<WatchMessage>> replaceDestination(WatchDestinationConfig config);

  Future<List<WatchMessage>> startNavigation(WatchNavigationRequest request);

  Future<List<WatchMessage>> rerouteActiveRoute();

  Future<List<WatchMessage>> clearActiveRoute();

  Future<WatchMapOrientation> getMapOrientation();

  Future<WatchMessage> setMapOrientation(WatchMapOrientation orientation);

  ProviderStatus get lastProviderStatus;
}

class NativeWatchMessageDispatcher implements WatchMessageDispatcher {
  NativeWatchMessageDispatcher({required this.providerRepository});

  final ProviderRepository providerRepository;
  ProviderStatus _lastProviderStatus = const ProviderStatus.notConfigured();
  DateTime? _lastProviderStatusRefresh;

  static const MethodChannel _channel = MethodChannel(
    'com.leapwardkoex.mappy/watch',
  );

  @override
  ProviderStatus get lastProviderStatus => _lastProviderStatus;

  @override
  Future<List<WatchMessage>> handleWatchMessage(WatchMessage message) async {
    final Object? result;
    try {
      result = await _channel.invokeMethod<Object?>(
        'handleWatchMessage',
        message.fields,
      );
    } finally {
      await _refreshProviderStatus(
        force: message.command != WatchCommands.tileRequest,
      );
    }
    return _messagesFromChannelResult(result);
  }

  @override
  Future<void> sendPhoneMessage(WatchMessage message) async {
    try {
      await _channel.invokeMethod<Object?>('sendPhoneMessage', message.fields);
    } on MissingPluginException {
      // Native watch delivery is unavailable on non-Android test hosts.
    } on PlatformException {
      // Settings persistence already succeeded; watch sync can recover on init.
    }
  }

  @override
  Future<List<WatchDestinationConfig>> getDestinations() async {
    try {
      final result = await _channel.invokeMethod<Object?>('getDestinations');
      if (result is List) {
        return result
            .map(WatchDestinationConfig.fromChannelMap)
            .nonNulls
            .toList(growable: false);
      }
    } on MissingPluginException {
      // Native watch storage is unavailable on non-Android test hosts.
    } on PlatformException {
      // Fall back to the protocol defaults; Android remains the source of truth.
    }
    return const [];
  }

  @override
  Future<List<WatchMessage>> replaceDestination(
    WatchDestinationConfig config,
  ) async {
    final Object? result;
    try {
      result = await _channel.invokeMethod<Object?>(
        'setDestination',
        config.toChannelMap(),
      );
    } finally {
      await _refreshProviderStatus();
    }
    final messages = _messagesFromChannelResult(result);
    await _sendReturnedPhoneMessages(messages);
    return messages;
  }

  @override
  Future<List<WatchMessage>> startNavigation(
    WatchNavigationRequest request,
  ) async {
    final Object? result;
    try {
      result = await _channel.invokeMethod<Object?>(
        'startNavigation',
        request.toChannelMap(),
      );
    } finally {
      await _refreshProviderStatus();
    }
    final messages = _messagesFromChannelResult(result);
    await _sendReturnedPhoneMessages(messages);
    return messages;
  }

  @override
  Future<List<WatchMessage>> rerouteActiveRoute() async {
    final Object? result;
    try {
      result = await _channel.invokeMethod<Object?>('rerouteActiveRoute');
    } finally {
      await _refreshProviderStatus();
    }
    final messages = _messagesFromChannelResult(result);
    await _sendReturnedPhoneMessages(messages);
    return messages;
  }

  @override
  Future<List<WatchMessage>> clearActiveRoute() async {
    final Object? result;
    try {
      result = await _channel.invokeMethod<Object?>('clearActiveRoute');
    } finally {
      await _refreshProviderStatus();
    }
    final messages = _messagesFromChannelResult(result);
    await _sendReturnedPhoneMessages(messages);
    return messages;
  }

  Future<void> _sendReturnedPhoneMessages(List<WatchMessage> messages) async {
    for (final message in messages) {
      await sendPhoneMessage(message);
    }
  }

  @override
  Future<WatchDisplaySettings> getDisplaySettings() async {
    try {
      final result = await _channel.invokeMethod<Object?>('getSettings');
      if (result is Map) {
        return WatchDisplaySettings.fromChannelMap(result);
      }
    } on MissingPluginException {
      // Native settings storage is unavailable on non-Android test hosts.
    } on PlatformException {
      // Fall back to the protocol defaults; the watch can recover on init.
    }
    return WatchDisplaySettings.defaults;
  }

  @override
  Future<WatchMapOrientation> getMapOrientation() async {
    return (await getDisplaySettings()).mapOrientation;
  }

  @override
  Future<List<WatchMessage>> setDisplaySettings(
    WatchDisplaySettings settings,
  ) async {
    final Object? result;
    try {
      result = await _channel.invokeMethod<Object?>(
        'setSettings',
        settings.toChannelMap(),
      );
    } on MissingPluginException {
      final messages = settings.toMessages();
      await _sendReturnedPhoneMessages(messages);
      return messages;
    } on PlatformException {
      final messages = settings.toMessages();
      await _sendReturnedPhoneMessages(messages);
      return messages;
    }
    final messages = _messagesFromChannelResult(result);
    await _sendReturnedPhoneMessages(messages);
    return messages;
  }

  @override
  Future<WatchMessage> setMapOrientation(
    WatchMapOrientation orientation,
  ) async {
    WatchMessage? persistedMessage;
    try {
      final result = await _channel.invokeMethod<Object?>('setSettings', {
        'mapOrientation': orientation.protocolValue,
      });
      persistedMessage = _messagesFromChannelResult(result)
          .where((message) => message.command == WatchCommands.mapOrientation)
          .firstOrNull;
    } on MissingPluginException {
      // Native settings storage is unavailable on non-Android test hosts.
    } on PlatformException {
      // Settings persistence failed; still emit the requested message locally.
    }

    final message =
        persistedMessage ??
        WatchMessage.command(WatchCommands.mapOrientation, {
          WatchKeys.buttonId: orientation.protocolValue,
        });
    await sendPhoneMessage(message);
    return message;
  }

  Future<void> _refreshProviderStatus({bool force = true}) async {
    final now = DateTime.now();
    final lastRefresh = _lastProviderStatusRefresh;
    if (!force &&
        lastRefresh != null &&
        now.difference(lastRefresh) < const Duration(seconds: 2)) {
      return;
    }
    _lastProviderStatusRefresh = now;
    try {
      _lastProviderStatus = await providerRepository.getProviderStatus();
    } on MissingPluginException {
      // Provider status is best-effort on hosts without the native plugin.
    } on PlatformException {
      // Provider status is best-effort when native status refresh fails.
    }
  }

  List<WatchMessage> _messagesFromChannelResult(Object? result) {
    if (result is! List) {
      return const [];
    }
    return result
        .whereType<Map>()
        .map((raw) {
          final fields = <String, Object?>{};
          for (final entry in raw.entries) {
            fields[entry.key.toString()] = entry.value;
          }
          return WatchMessage(fields);
        })
        .toList(growable: false);
  }
}

class WatchDisplaySettings {
  const WatchDisplaySettings({
    required this.themeMode,
    required this.travelMode,
    required this.unitsMode,
    required this.backlightMode,
    required this.mapOrientation,
    required this.tileAnimationMode,
  });

  final WatchThemeMode themeMode;
  final WatchTravelMode travelMode;
  final WatchUnitsMode unitsMode;
  final WatchBacklightMode backlightMode;
  final WatchMapOrientation mapOrientation;
  final WatchTileAnimationMode tileAnimationMode;

  static const defaults = WatchDisplaySettings(
    themeMode: WatchThemeMode.auto,
    travelMode: WatchTravelMode.drive,
    unitsMode: WatchUnitsMode.metric,
    backlightMode: WatchBacklightMode.system,
    mapOrientation: WatchMapOrientation.northUp,
    tileAnimationMode: WatchTileAnimationMode.fadeIn,
  );

  WatchDisplaySettings copyWith({
    WatchThemeMode? themeMode,
    WatchTravelMode? travelMode,
    WatchUnitsMode? unitsMode,
    WatchBacklightMode? backlightMode,
    WatchMapOrientation? mapOrientation,
    WatchTileAnimationMode? tileAnimationMode,
  }) {
    return WatchDisplaySettings(
      themeMode: themeMode ?? this.themeMode,
      travelMode: travelMode ?? this.travelMode,
      unitsMode: unitsMode ?? this.unitsMode,
      backlightMode: backlightMode ?? this.backlightMode,
      mapOrientation: mapOrientation ?? this.mapOrientation,
      tileAnimationMode: tileAnimationMode ?? this.tileAnimationMode,
    );
  }

  Map<String, Object?> toChannelMap() {
    return <String, Object?>{
      'themeMode': themeMode.protocolValue,
      'travelMode': travelMode.protocolValue,
      'unitsMode': unitsMode.protocolValue,
      'backlightMode': backlightMode.protocolValue,
      'mapOrientation': mapOrientation.protocolValue,
      'tileAnimationMode': tileAnimationMode.protocolValue,
    };
  }

  List<WatchMessage> toMessages() {
    return [
      WatchMessage.command(WatchCommands.theme, {
        WatchKeys.buttonId: themeMode.protocolValue,
      }),
      WatchMessage.command(WatchCommands.travelMode, {
        WatchKeys.buttonId: travelMode.protocolValue,
      }),
      WatchMessage.command(WatchCommands.units, {
        WatchKeys.buttonId: unitsMode.protocolValue,
      }),
      WatchMessage.command(WatchCommands.backlight, {
        WatchKeys.buttonId: backlightMode.protocolValue,
      }),
      WatchMessage.command(WatchCommands.mapOrientation, {
        WatchKeys.buttonId: mapOrientation.protocolValue,
      }),
      WatchMessage.command(WatchCommands.tileAnimation, {
        WatchKeys.buttonId: tileAnimationMode.protocolValue,
      }),
    ];
  }

  static WatchDisplaySettings fromChannelMap(Map<dynamic, dynamic> value) {
    final tileAnimationValue = asInt(value['tileAnimationMode']);
    return WatchDisplaySettings(
      themeMode: WatchThemeMode.fromProtocol(asInt(value['themeMode'])),
      travelMode: WatchTravelMode.fromProtocol(asInt(value['travelMode'])),
      unitsMode: WatchUnitsMode.fromProtocol(asInt(value['unitsMode'])),
      backlightMode: WatchBacklightMode.fromProtocol(
        asInt(value['backlightMode']),
      ),
      mapOrientation: WatchMapOrientation.fromProtocol(
        asInt(value['mapOrientation']),
      ),
      tileAnimationMode: tileAnimationValue == null
          ? WatchTileAnimationMode.fadeIn
          : WatchTileAnimationMode.fromProtocol(tileAnimationValue),
    );
  }
}

class WatchDestinationConfig {
  const WatchDestinationConfig({
    required this.slotIndex,
    required this.label,
    required this.address,
    required this.latitude,
    required this.longitude,
    required this.kind,
    required this.defaultTravelMode,
    this.enabled = true,
    this.placeId,
    this.updatedAtMillis,
    this.geocodeStatus = 'resolved',
  });

  final int slotIndex;
  final String label;
  final String address;
  final double latitude;
  final double longitude;
  final int kind;
  final WatchTravelMode defaultTravelMode;
  final bool enabled;
  final String? placeId;
  final int? updatedAtMillis;
  final String geocodeStatus;

  WatchDestinationConfig copyWith({
    String? label,
    String? address,
    double? latitude,
    double? longitude,
    int? kind,
    WatchTravelMode? defaultTravelMode,
    bool? enabled,
    String? placeId,
    int? updatedAtMillis,
    String? geocodeStatus,
  }) {
    return WatchDestinationConfig(
      slotIndex: slotIndex,
      label: label ?? this.label,
      address: address ?? this.address,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      kind: kind ?? this.kind,
      defaultTravelMode: defaultTravelMode ?? this.defaultTravelMode,
      enabled: enabled ?? this.enabled,
      placeId: placeId ?? this.placeId,
      updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
      geocodeStatus: geocodeStatus ?? this.geocodeStatus,
    );
  }

  WatchDestinationRecord toProtocolRecord() {
    return WatchDestinationRecord(
      slotIndex: slotIndex,
      kind: kind,
      defaultTravelMode: defaultTravelMode,
      latitude: latitude,
      longitude: longitude,
      label: label,
    );
  }

  Map<String, Object?> toChannelMap() {
    return <String, Object?>{
      'slotIndex': slotIndex,
      'label': label,
      'address': address,
      'latitude': latitude,
      'longitude': longitude,
      'kind': kind,
      'defaultTravelMode': defaultTravelMode.protocolValue,
      'enabled': enabled,
      'placeId': placeId,
      'updatedAtMillis': updatedAtMillis,
      'geocodeStatus': geocodeStatus,
    };
  }

  static WatchDestinationConfig? fromChannelMap(Object? value) {
    if (value is! Map) {
      return null;
    }
    final slot = asInt(value['slotIndex']) ?? asInt(value['slot']);
    final latitude = _asDouble(value['latitude']);
    final longitude = _asDouble(value['longitude']);
    final label = (value['label'] as String?)?.trim() ?? '';
    final address = (value['address'] as String?)?.trim() ?? label;
    final kind = asInt(value['kind'])?.clamp(0, 2).toInt() ?? 2;
    final placeId = value['placeId'] is String
        ? (value['placeId'] as String).trim()
        : '';
    final geocodeStatus = value['geocodeStatus'] is String
        ? (value['geocodeStatus'] as String).trim()
        : '';
    if (slot == null ||
        !isSavedLocationId(slot) ||
        latitude == null ||
        longitude == null ||
        label.isEmpty) {
      return null;
    }
    return WatchDestinationConfig(
      slotIndex: slot,
      label: label,
      address: address.isEmpty ? label : address,
      latitude: latitude,
      longitude: longitude,
      kind: kind,
      defaultTravelMode: WatchTravelMode.fromProtocol(
        asInt(value['defaultTravelMode']),
      ),
      enabled: _asBool(value['enabled']) ?? true,
      placeId: placeId.isEmpty ? null : placeId,
      updatedAtMillis: asInt(value['updatedAtMillis']),
      geocodeStatus: geocodeStatus.isEmpty ? 'resolved' : geocodeStatus,
    );
  }
}

double? _asDouble(Object? value) {
  if (value is int) {
    return value.toDouble();
  }
  if (value is double && value.isFinite) {
    return value;
  }
  return null;
}

bool? _asBool(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is int) {
    return value != 0;
  }
  return null;
}

enum WatchRouteOriginPolicy {
  currentLocation('current_location', 'Current location'),
  explicitPlace('explicit_place', 'Specific place');

  const WatchRouteOriginPolicy(this.channelName, this.label);

  final String channelName;
  final String label;
}

class WatchRouteEndpoint {
  const WatchRouteEndpoint({
    required this.label,
    required this.address,
    required this.latitude,
    required this.longitude,
    this.placeId,
  });

  final String label;
  final String address;
  final double latitude;
  final double longitude;
  final String? placeId;

  Map<String, Object?> toChannelMap() {
    return <String, Object?>{
      'label': label,
      'address': address,
      'latitude': latitude,
      'longitude': longitude,
      'placeId': placeId,
    };
  }
}

class WatchNavigationRequest {
  const WatchNavigationRequest({
    required this.destination,
    required this.travelMode,
    this.originPolicy = WatchRouteOriginPolicy.currentLocation,
    this.origin,
  });

  final WatchRouteOriginPolicy originPolicy;
  final WatchRouteEndpoint? origin;
  final WatchRouteEndpoint destination;
  final WatchTravelMode travelMode;

  Map<String, Object?> toChannelMap() {
    return <String, Object?>{
      'originPolicy': originPolicy.channelName,
      'origin': origin?.toChannelMap(),
      'destination': destination.toChannelMap(),
      'travelMode': travelMode.protocolValue,
    };
  }
}

class WatchPhoneWorker implements WatchMessageDispatcher {
  WatchPhoneWorker({
    required this.locationRepository,
    required this.providerRepository,
    List<WatchDestinationConfig>? destinations,
  }) : destinations = List<WatchDestinationConfig>.from(
         destinations ?? const <WatchDestinationConfig>[],
       );

  final LocationRepository locationRepository;
  final ProviderRepository providerRepository;
  final List<WatchDestinationConfig> destinations;

  WatchThemeMode themeMode = WatchThemeMode.auto;
  WatchTravelMode travelMode = WatchTravelMode.drive;
  WatchMapOrientation mapOrientation = WatchMapOrientation.northUp;
  WatchTileAnimationMode tileAnimationMode = WatchTileAnimationMode.fadeIn;
  WatchUnitsMode unitsMode = WatchUnitsMode.metric;
  WatchBacklightMode backlightMode = WatchBacklightMode.system;
  @override
  ProviderStatus lastProviderStatus = const ProviderStatus.notConfigured();

  LocationSnapshot? _lastLocation;
  List<WorldPoint> _routePoints = const [];
  List<WorldPoint> _fullRoutePoints = const [];
  List<WatchNavStep> _routeSteps = const [];
  int _routeGeneration = 0;
  WatchRouteOriginPolicy _activeRouteOriginPolicy =
      WatchRouteOriginPolicy.currentLocation;
  WatchRouteEndpoint? _activeRouteOrigin;
  WatchRouteEndpoint? _activeRouteTarget;
  int? _activeRouteSlot;
  WatchTravelMode? _activeRouteMode;
  DateTime? _lastRouteRequestedAt;
  String? _lastRouteError;
  static const Duration _routeLocationFreshness = Duration(seconds: 20);

  @override
  Future<List<WatchDestinationConfig>> getDestinations() async =>
      List<WatchDestinationConfig>.unmodifiable(destinations);

  @override
  Future<List<WatchMessage>> replaceDestination(
    WatchDestinationConfig config,
  ) async {
    final existing = destinations.indexWhere(
      (destination) => destination.slotIndex == config.slotIndex,
    );
    if (!config.enabled) {
      if (existing >= 0) {
        destinations.removeAt(existing);
      }
    } else if (existing >= 0) {
      destinations[existing] = config;
    } else {
      destinations.add(config);
    }
    destinations.sort((a, b) => a.slotIndex.compareTo(b.slotIndex));
    if (_activeRouteSlot == config.slotIndex) {
      _clearActiveRoute();
    }
    return [_destinationsMessage()];
  }

  @override
  Future<List<WatchMessage>> startNavigation(
    WatchNavigationRequest request,
  ) async {
    travelMode = request.travelMode;

    final origin = await _routeOriginForRequest(request);
    if (origin == null) {
      final missingExplicitOrigin =
          request.originPolicy == WatchRouteOriginPolicy.explicitPlace;
      return [
        _errorMessage(
          category: missingExplicitOrigin ? 8 : 3,
          failedCommand: WatchCommands.routeRequest,
          text: missingExplicitOrigin
              ? 'Route origin is missing.'
              : 'Waiting for GPS.',
        ),
      ];
    }

    return _routeResponses(
      originLatitude: origin.latitude,
      originLongitude: origin.longitude,
      targetEndpoint: request.destination,
      requestedMode: request.travelMode,
      errorOffset: 0,
      activeRouteSlot: null,
      originPolicy: request.originPolicy,
      cachedOrigin: request.originPolicy == WatchRouteOriginPolicy.explicitPlace
          ? request.origin
          : null,
    );
  }

  @override
  Future<List<WatchMessage>> rerouteActiveRoute() {
    return _rerouteActiveRoute(
      requestedMode: travelMode,
      requestSlot: _activeRouteSlot,
    );
  }

  @override
  Future<List<WatchMessage>> clearActiveRoute() async {
    _clearActiveRoute();
    return [WatchMessage.command(WatchCommands.routeClear)];
  }

  @override
  Future<List<WatchMessage>> handleWatchMessage(WatchMessage message) async {
    switch (message.command) {
      case WatchCommands.init:
        return _handleInit(message);
      case WatchCommands.tileRequest:
        return _handleTileRequest(message);
      case WatchCommands.button:
        return _handleButton(message);
      case WatchCommands.routeRequest:
        return _handleRouteRequest(message);
      case WatchCommands.routeWindowRequest:
        return _handleRouteWindowRequest(message);
      case WatchCommands.navSteps:
        return _handleNavStepsRequest(message);
      case WatchCommands.routeClear:
        _clearActiveRoute();
        return [WatchMessage.command(WatchCommands.routeClear)];
      case WatchCommands.theme:
        themeMode = WatchThemeMode.fromProtocol(
          asInt(message.fields[WatchKeys.buttonId]),
        );
        return [_themeMessage()];
      case WatchCommands.travelMode:
        travelMode = WatchTravelMode.fromProtocol(
          asInt(message.fields[WatchKeys.buttonId]),
        );
        return [_travelModeMessage()];
      case WatchCommands.mapOrientation:
        mapOrientation = WatchMapOrientation.fromProtocol(
          asInt(message.fields[WatchKeys.buttonId]),
        );
        return [_mapOrientationMessage()];
      case WatchCommands.tileAnimation:
        tileAnimationMode = WatchTileAnimationMode.fromProtocol(
          asInt(message.fields[WatchKeys.buttonId]),
        );
        return [_tileAnimationMessage()];
      case WatchCommands.units:
        unitsMode = WatchUnitsMode.fromProtocol(
          asInt(message.fields[WatchKeys.buttonId]),
        );
        return [_unitsMessage()];
      case WatchCommands.backlight:
        backlightMode = WatchBacklightMode.fromProtocol(
          asInt(message.fields[WatchKeys.buttonId]),
        );
        return [_backlightMessage()];
      case WatchCommands.logEvent:
        return const [];
      default:
        return [
          _errorMessage(
            category: 6,
            failedCommand: message.command ?? 0,
            text: 'Unsupported watch command.',
          ),
        ];
    }
  }

  @override
  Future<void> sendPhoneMessage(WatchMessage message) async {}

  @override
  Future<WatchDisplaySettings> getDisplaySettings() async =>
      WatchDisplaySettings(
        themeMode: themeMode,
        travelMode: travelMode,
        unitsMode: unitsMode,
        backlightMode: backlightMode,
        mapOrientation: mapOrientation,
        tileAnimationMode: tileAnimationMode,
      );

  @override
  Future<WatchMapOrientation> getMapOrientation() async => mapOrientation;

  @override
  Future<List<WatchMessage>> setDisplaySettings(
    WatchDisplaySettings settings,
  ) async {
    themeMode = settings.themeMode;
    travelMode = settings.travelMode;
    unitsMode = settings.unitsMode;
    backlightMode = settings.backlightMode;
    mapOrientation = settings.mapOrientation;
    tileAnimationMode = settings.tileAnimationMode;
    final messages = [
      _themeMessage(),
      _travelModeMessage(),
      _unitsMessage(),
      _backlightMessage(),
      _mapOrientationMessage(),
      _tileAnimationMessage(),
    ];
    for (final message in messages) {
      await sendPhoneMessage(message);
    }
    return messages;
  }

  @override
  Future<WatchMessage> setMapOrientation(
    WatchMapOrientation orientation,
  ) async {
    mapOrientation = orientation;
    final message = _mapOrientationMessage();
    await sendPhoneMessage(message);
    return message;
  }

  Future<List<WatchMessage>> _handleInit(WatchMessage message) async {
    themeMode = WatchThemeMode.fromProtocol(
      asInt(message.fields[WatchKeys.tileZoom]),
    );
    travelMode = WatchTravelMode.fromProtocol(
      asInt(message.fields[WatchKeys.buttonId]),
    );
    backlightMode = WatchBacklightMode.fromProtocol(
      asInt(message.fields[WatchKeys.totalBytes]),
    );
    mapOrientation = WatchMapOrientation.fromProtocol(
      asInt(message.fields[WatchKeys.chunkOffset]),
    );

    final responses = <WatchMessage>[
      _themeMessage(),
      _travelModeMessage(),
      _unitsMessage(),
      _backlightMessage(),
      WatchMessage.command(WatchCommands.mapSettings, {WatchKeys.buttonId: 0}),
      _mapOrientationMessage(),
      _tileAnimationMessage(),
      _destinationsMessage(),
    ];

    lastProviderStatus = await providerRepository.getProviderStatus();
    if (!lastProviderStatus.configured) {
      responses.add(
        _errorMessage(
          category: 1,
          failedCommand: WatchCommands.init,
          text: 'Missing Google API key.',
        ),
      );
    }

    responses.add(await _gpsOrError());
    responses.addAll(_activeRouteMessages());
    return responses;
  }

  Future<List<WatchMessage>> _handleTileRequest(WatchMessage message) async {
    final worldX = asInt(message.fields[WatchKeys.worldX]);
    final worldY = asInt(message.fields[WatchKeys.worldY]);
    final zoom = asInt(message.fields[WatchKeys.tileZoom]);
    final theme =
        asInt(message.fields[WatchKeys.isColor]) ?? themeMode.protocolValue;

    if (worldX == null || worldY == null || zoom == null) {
      return [
        _errorMessage(
          category: 5,
          failedCommand: WatchCommands.tileRequest,
          text: 'Tile request missing x, y, or zoom.',
        ),
      ];
    }

    final tile = await providerRepository.getWatchTile(
      worldX: worldX,
      worldY: worldY,
      zoom: zoom,
      themeMode: theme,
    );
    lastProviderStatus = tile.status;

    if (!tile.ok || tile.chunkData == null) {
      return [
        _errorMessage(
          category: tile.errorCategory ?? 5,
          failedCommand: WatchCommands.tileRequest,
          text: tile.detail ?? 'Watch tile provider failed.',
          worldX: worldX,
          worldY: worldY,
          zoom: zoom,
        ),
      ];
    }

    return [
      WatchMessage.command(WatchCommands.tile, {
        WatchKeys.worldX: tile.worldX ?? worldX,
        WatchKeys.worldY: tile.worldY ?? worldY,
        WatchKeys.tileZoom: tile.zoom ?? zoom,
        WatchKeys.totalBytes: tile.totalBytes ?? tile.chunkData!.length,
        WatchKeys.chunkData: tile.chunkData,
      }),
    ];
  }

  List<WatchMessage> _handleButton(WatchMessage message) {
    final delta = asInt(message.fields[WatchKeys.buttonId]);
    if (delta == 1 || delta == -1) {
      return const [];
    }
    return [
      _errorMessage(
        category: 6,
        failedCommand: WatchCommands.button,
        text: 'Unsupported button event.',
      ),
    ];
  }

  Future<List<WatchMessage>> _handleRouteRequest(WatchMessage message) async {
    final slot = asInt(message.fields[WatchKeys.buttonId]);
    final requestedMode = WatchTravelMode.fromProtocol(
      asInt(message.fields[WatchKeys.isColor]),
    );
    travelMode = requestedMode;
    if (slot == null || !isSavedLocationId(slot)) {
      return _rerouteActiveRoute(
        requestedMode: requestedMode,
        requestSlot: slot,
      );
    }

    final destination = destinations
        .where((candidate) => candidate.slotIndex == slot && candidate.enabled)
        .firstOrNull;
    if (destination == null) {
      return [
        _errorMessage(
          category: 8,
          failedCommand: WatchCommands.routeRequest,
          text: 'Destination not configured.',
          offset: slot,
        ),
      ];
    }

    final location = await _freshRouteLocation();
    if (location == null) {
      return [
        _errorMessage(
          category: 3,
          failedCommand: WatchCommands.routeRequest,
          text: 'Waiting for GPS.',
          offset: slot,
        ),
      ];
    }
    return _routeResponses(
      originLatitude: location.latitude,
      originLongitude: location.longitude,
      targetEndpoint: WatchRouteEndpoint(
        label: destination.label,
        address: destination.address,
        latitude: destination.latitude,
        longitude: destination.longitude,
        placeId: destination.placeId,
      ),
      requestedMode: requestedMode,
      errorOffset: slot,
      activeRouteSlot: slot,
      originPolicy: WatchRouteOriginPolicy.currentLocation,
      cachedOrigin: null,
    );
  }

  Future<List<WatchMessage>> _rerouteActiveRoute({
    required WatchTravelMode requestedMode,
    required int? requestSlot,
  }) async {
    final target = _activeRouteTarget;
    if (target == null) {
      return [
        _errorMessage(
          category: 8,
          failedCommand: WatchCommands.routeRequest,
          text: 'No active route target.',
          offset: requestSlot ?? 0,
        ),
      ];
    }

    final origin =
        _activeRouteOriginPolicy == WatchRouteOriginPolicy.explicitPlace
        ? _activeRouteOrigin
        : await _routeOriginForRequest(
            WatchNavigationRequest(
              destination: target,
              travelMode: requestedMode,
            ),
          );
    if (origin == null) {
      return [
        _errorMessage(
          category:
              _activeRouteOriginPolicy == WatchRouteOriginPolicy.explicitPlace
              ? 8
              : 3,
          failedCommand: WatchCommands.routeRequest,
          text: _activeRouteOriginPolicy == WatchRouteOriginPolicy.explicitPlace
              ? 'Active route origin is missing.'
              : 'Waiting for GPS.',
          offset: _activeRouteSlot ?? requestSlot ?? 0,
        ),
      ];
    }

    return _routeResponses(
      originLatitude: origin.latitude,
      originLongitude: origin.longitude,
      targetEndpoint: target,
      requestedMode: requestedMode,
      errorOffset: _activeRouteSlot ?? requestSlot ?? 0,
      activeRouteSlot: _activeRouteSlot,
      originPolicy: _activeRouteOriginPolicy,
      cachedOrigin:
          _activeRouteOriginPolicy == WatchRouteOriginPolicy.explicitPlace
          ? _activeRouteOrigin
          : null,
    );
  }

  Future<WatchRouteEndpoint?> _routeOriginForRequest(
    WatchNavigationRequest request,
  ) async {
    if (request.originPolicy == WatchRouteOriginPolicy.explicitPlace) {
      return request.origin;
    }

    final location = await _freshRouteLocation();
    if (location == null) {
      return null;
    }
    return WatchRouteEndpoint(
      label: 'Current location',
      address: 'Current location',
      latitude: location.latitude,
      longitude: location.longitude,
    );
  }

  Future<List<WatchMessage>> _routeResponses({
    required double originLatitude,
    required double originLongitude,
    required WatchRouteEndpoint targetEndpoint,
    required WatchTravelMode requestedMode,
    required int errorOffset,
    required int? activeRouteSlot,
    required WatchRouteOriginPolicy originPolicy,
    required WatchRouteEndpoint? cachedOrigin,
  }) async {
    _beginActiveRouteRequest(
      requestedMode: requestedMode,
      originPolicy: originPolicy,
      cachedOrigin: cachedOrigin,
      targetEndpoint: targetEndpoint,
      activeRouteSlot: activeRouteSlot,
    );
    final route = await providerRepository.computeRoute(
      originLatitude: originLatitude,
      originLongitude: originLongitude,
      destinationAddress: targetEndpoint.address,
      destinationLatitude: targetEndpoint.latitude,
      destinationLongitude: targetEndpoint.longitude,
      travelMode: _providerTravelMode(requestedMode),
    );
    lastProviderStatus = route.status;

    if (!route.ok) {
      final category =
          route.errorCategory ?? _providerStatusToCategory(route.status);
      if (category == 7) {
        _clearActiveRoute(incrementGeneration: false);
        _lastRouteError = route.detail ?? 'No route found.';
        return [
          WatchMessage.command(WatchCommands.routePoints, {
            WatchKeys.buttonId: 1,
            WatchKeys.isColor: requestedMode.protocolValue,
            WatchKeys.totalBytes: _routeGeneration,
            WatchKeys.chunkData: encodeRoutePoints(const []),
          }),
          _errorMessage(
            category: 7,
            failedCommand: WatchCommands.routeRequest,
            text: route.detail ?? 'No route found.',
            offset: errorOffset,
          ),
        ];
      }
      _lastRouteError = route.detail ?? 'Route provider failed.';
      return [
        _errorMessage(
          category: category == 0 ? 6 : category,
          failedCommand: WatchCommands.routeRequest,
          text: route.detail ?? 'Route provider failed.',
          offset: errorOffset,
        ),
      ];
    }

    final points = route.routePoints
        .map((point) => WorldPoint(worldX: point.worldX, worldY: point.worldY))
        .toList(growable: false);
    final fullPoints =
        (route.fullRoutePoints.isEmpty
                ? route.routePoints
                : route.fullRoutePoints)
            .map(
              (point) => WorldPoint(worldX: point.worldX, worldY: point.worldY),
            )
            .toList(growable: false);
    if (points.length < 2) {
      _lastRouteError = 'Route geometry is invalid.';
      return [
        _errorMessage(
          category: 6,
          failedCommand: WatchCommands.routeRequest,
          text: 'Route geometry is invalid.',
          offset: errorOffset,
        ),
      ];
    }

    _routePoints = points;
    _fullRoutePoints = fullPoints.length >= 2 ? fullPoints : points;
    _activeRouteSlot = activeRouteSlot;
    _activeRouteOriginPolicy = originPolicy;
    _activeRouteOrigin = originPolicy == WatchRouteOriginPolicy.explicitPlace
        ? cachedOrigin
        : null;
    _activeRouteTarget = targetEndpoint;
    _activeRouteMode = requestedMode;
    _lastRouteRequestedAt = DateTime.now();
    _lastRouteError = null;
    _routeSteps = route.steps
        .map(
          (step) => WatchNavStep(
            globalIndex: step.index,
            startWorldX: step.startWorldX,
            startWorldY: step.startWorldY,
            remainingMeters: step.remainingMeters,
            remainingSeconds: step.remainingSeconds,
            instruction: step.instruction,
          ),
        )
        .toList(growable: false);

    final responses = <WatchMessage>[
      WatchMessage.command(WatchCommands.routePoints, {
        WatchKeys.buttonId: 1,
        WatchKeys.isColor: requestedMode.protocolValue,
        WatchKeys.totalBytes: _routeGeneration,
        WatchKeys.chunkData: encodeRoutePoints(points),
      }),
    ];
    if (_routeSteps.isNotEmpty) {
      responses.add(
        WatchMessage.command(WatchCommands.navSteps, {
          WatchKeys.chunkData: encodeNavSteps(_routeSteps, 0),
        }),
      );
    }
    return responses;
  }

  void _beginActiveRouteRequest({
    required WatchTravelMode requestedMode,
    required WatchRouteOriginPolicy originPolicy,
    required WatchRouteEndpoint? cachedOrigin,
    required WatchRouteEndpoint targetEndpoint,
    required int? activeRouteSlot,
  }) {
    travelMode = requestedMode;
    _routeGeneration++;
    _activeRouteSlot = activeRouteSlot;
    _activeRouteOriginPolicy = originPolicy;
    _activeRouteOrigin = originPolicy == WatchRouteOriginPolicy.explicitPlace
        ? cachedOrigin
        : null;
    _activeRouteTarget = targetEndpoint;
    _lastRouteRequestedAt = DateTime.now();
    _lastRouteError = null;
  }

  Future<LocationSnapshot?> _freshRouteLocation() async {
    final cached = _lastLocation;
    if (cached != null && _isFreshForRouting(cached)) {
      return cached;
    }

    final location = await locationRepository.getCurrentLocation();
    if (location == null || !_isFreshForRouting(location)) {
      return null;
    }
    _lastLocation = location;
    return location;
  }

  bool _isFreshForRouting(LocationSnapshot location) {
    if (!location.isFresh) {
      return false;
    }
    final age = DateTime.now().difference(location.timestamp).abs();
    return age <= _routeLocationFreshness;
  }

  List<WatchMessage> _activeRouteMessages() {
    if (_routePoints.length < 2) {
      return const [];
    }
    final responses = <WatchMessage>[
      WatchMessage.command(WatchCommands.routePoints, {
        WatchKeys.buttonId: 1,
        WatchKeys.isColor: (_activeRouteMode ?? travelMode).protocolValue,
        WatchKeys.totalBytes: _routeGeneration,
        WatchKeys.chunkData: encodeRoutePoints(_routePoints),
      }),
    ];
    if (_routeSteps.isNotEmpty) {
      responses.add(
        WatchMessage.command(WatchCommands.navSteps, {
          WatchKeys.chunkData: encodeNavSteps(_routeSteps, 0),
        }),
      );
    }
    return responses;
  }

  void _clearActiveRoute({bool incrementGeneration = true}) {
    if (incrementGeneration) {
      _routeGeneration++;
    }
    _routePoints = const [];
    _fullRoutePoints = const [];
    _routeSteps = const [];
    _activeRouteOriginPolicy = WatchRouteOriginPolicy.currentLocation;
    _activeRouteOrigin = null;
    _activeRouteTarget = null;
    _activeRouteSlot = null;
    _activeRouteMode = null;
    _lastRouteRequestedAt = null;
    _lastRouteError = null;
  }

  List<WatchMessage> _handleRouteWindowRequest(WatchMessage message) {
    final centerX = asInt(message.fields[WatchKeys.worldX]);
    final centerY = asInt(message.fields[WatchKeys.worldY]);
    final zoom = asInt(message.fields[WatchKeys.tileZoom]);
    final width = asInt(message.fields[WatchKeys.width]);
    final height = asInt(message.fields[WatchKeys.height]);
    if (centerX == null ||
        centerY == null ||
        zoom == null ||
        width == null ||
        height == null) {
      return [
        _errorMessage(
          category: 6,
          failedCommand: WatchCommands.routeWindowRequest,
          text: 'Route window request missing bounds.',
        ),
      ];
    }

    final requestedGeneration = asInt(message.fields[WatchKeys.totalBytes]);
    final responseGeneration = requestedGeneration ?? _routeGeneration;
    if (_fullRoutePoints.length < 2 ||
        (requestedGeneration != null &&
            requestedGeneration != _routeGeneration)) {
      return [
        _routeWindowPointsMessage(
          points: const [],
          generation: responseGeneration,
          centerX: centerX,
          centerY: centerY,
          zoom: zoom,
          width: width,
          height: height,
        ),
      ];
    }

    final points = _routeWindowPoints(
      points: _fullRoutePoints,
      centerX: centerX,
      centerY: centerY,
      width: width,
      height: height,
    );
    return [
      _routeWindowPointsMessage(
        points: points,
        generation: _routeGeneration,
        centerX: centerX,
        centerY: centerY,
        zoom: zoom,
        width: width,
        height: height,
      ),
    ];
  }

  WatchMessage _routeWindowPointsMessage({
    required List<WorldPoint> points,
    required int generation,
    required int centerX,
    required int centerY,
    required int zoom,
    required int width,
    required int height,
  }) {
    final safeWidth = width.clamp(1, 1 << 30).toInt();
    final safeHeight = height.clamp(1, 1 << 30).toInt();
    return WatchMessage.command(WatchCommands.routeWindowPoints, {
      WatchKeys.worldX: centerX,
      WatchKeys.worldY: centerY,
      WatchKeys.tileZoom: zoom,
      WatchKeys.width: safeWidth,
      WatchKeys.height: safeHeight,
      WatchKeys.totalBytes: generation,
      WatchKeys.chunkData: encodeRoutePoints(points),
    });
  }

  List<WorldPoint> _routeWindowPoints({
    required List<WorldPoint> points,
    required int centerX,
    required int centerY,
    required int width,
    required int height,
  }) {
    final safeWidth = width.clamp(1, 1 << 30).toInt();
    final safeHeight = height.clamp(1, 1 << 30).toInt();
    final halfWidth = (safeWidth ~/ 2).clamp(1, 1 << 30).toInt();
    final halfHeight = (safeHeight ~/ 2).clamp(1, 1 << 30).toInt();
    final minX = centerX - halfWidth;
    final maxX = centerX + halfWidth;
    final minY = centerY - halfHeight;
    final maxY = centerY + halfHeight;
    final selected = <WorldPoint>[];
    for (var index = 1; index < points.length; index++) {
      final previous = points[index - 1];
      final current = points[index];
      if (_segmentIntersectsBounds(previous, current, minX, maxX, minY, maxY)) {
        if (selected.isEmpty || selected.last != previous) {
          selected.add(previous);
        }
        if (selected.last != current) {
          selected.add(current);
        }
      }
    }
    return _downsampleWorldPoints(selected, maxRoutePoints);
  }

  bool _segmentIntersectsBounds(
    WorldPoint start,
    WorldPoint end,
    int minX,
    int maxX,
    int minY,
    int maxY,
  ) {
    bool contains(WorldPoint point) =>
        point.worldX >= minX &&
        point.worldX <= maxX &&
        point.worldY >= minY &&
        point.worldY <= maxY;
    if (contains(start) || contains(end)) {
      return true;
    }
    final segmentMinX = math.min(start.worldX, end.worldX);
    final segmentMaxX = math.max(start.worldX, end.worldX);
    final segmentMinY = math.min(start.worldY, end.worldY);
    final segmentMaxY = math.max(start.worldY, end.worldY);
    return segmentMaxX >= minX &&
        segmentMinX <= maxX &&
        segmentMaxY >= minY &&
        segmentMinY <= maxY;
  }

  List<WorldPoint> _downsampleWorldPoints(
    List<WorldPoint> points,
    int maxPoints,
  ) {
    if (points.length <= maxPoints) {
      return points;
    }
    final lastIndex = points.length - 1;
    return [
      for (var index = 0; index < maxPoints; index++)
        points[(index * lastIndex) ~/ (maxPoints - 1)],
    ];
  }

  List<WatchMessage> _handleNavStepsRequest(WatchMessage message) {
    final firstIndex = asInt(message.fields[WatchKeys.buttonId]) ?? 0;
    if (_routeSteps.isEmpty) {
      return [
        _errorMessage(
          category: 6,
          failedCommand: WatchCommands.navSteps,
          text: 'No nav-step cache.',
          offset: firstIndex,
        ),
      ];
    }
    try {
      return [
        WatchMessage.command(WatchCommands.navSteps, {
          WatchKeys.chunkData: encodeNavSteps(_routeSteps, firstIndex),
        }),
      ];
    } on WatchProtocolException catch (error) {
      return [
        _errorMessage(
          category: 6,
          failedCommand: WatchCommands.navSteps,
          text: error.message,
          offset: firstIndex,
        ),
      ];
    }
  }

  Future<WatchMessage> _gpsOrError() async {
    final permission = await locationRepository.getPermissionState();
    if (!permission.allowsLocation) {
      return _errorMessage(
        category: 3,
        failedCommand: WatchCommands.gps,
        text: permission.label,
      );
    }
    final location = await locationRepository.getCurrentLocation();
    if (location == null) {
      return _errorMessage(
        category: 3,
        failedCommand: WatchCommands.gps,
        text: 'No location fix.',
      );
    }
    _lastLocation = location;
    final world = latLngToWorldPixels(location.latitude, location.longitude);
    return gpsMessageFromWorld(world);
  }

  WatchMessage gpsMessageFromWorld(
    WorldPoint world, {
    int headingDegrees = -1,
    int? sequence,
    int? elapsedMs,
    int? accuracyCm,
    String? provider,
  }) {
    final fields = <String, Object?>{
      WatchKeys.worldX: world.worldX,
      WatchKeys.worldY: world.worldY,
      WatchKeys.tileZoom: routeWorldZoom,
      WatchKeys.buttonId: headingDegrees,
    };
    if (sequence != null) {
      fields[WatchKeys.gpsSequence] = sequence;
    }
    if (elapsedMs != null) {
      fields[WatchKeys.gpsElapsedMs] = elapsedMs;
    }
    if (accuracyCm != null) {
      fields[WatchKeys.gpsAccuracyCm] = accuracyCm;
    }
    if (provider != null) {
      fields[WatchKeys.gpsProvider] = provider;
    }
    return WatchMessage.command(WatchCommands.gps, fields);
  }

  WatchMessage _destinationsMessage() {
    final payload = encodeDestinations(
      destinations
          .where((destination) => destination.enabled)
          .map((destination) => destination.toProtocolRecord())
          .toList(growable: false),
    );
    return WatchMessage.command(WatchCommands.destinations, {
      WatchKeys.totalBytes: payload.length,
      WatchKeys.chunkData: payload,
    });
  }

  WatchMessage _themeMessage() {
    return WatchMessage.command(WatchCommands.theme, {
      WatchKeys.buttonId: themeMode.protocolValue,
    });
  }

  WatchMessage _travelModeMessage() {
    return WatchMessage.command(WatchCommands.travelMode, {
      WatchKeys.buttonId: travelMode.protocolValue,
    });
  }

  WatchMessage _unitsMessage() {
    return WatchMessage.command(WatchCommands.units, {
      WatchKeys.buttonId: unitsMode.protocolValue,
    });
  }

  WatchMessage _backlightMessage() {
    return WatchMessage.command(WatchCommands.backlight, {
      WatchKeys.buttonId: backlightMode.protocolValue,
    });
  }

  WatchMessage _mapOrientationMessage() {
    return WatchMessage.command(WatchCommands.mapOrientation, {
      WatchKeys.buttonId: mapOrientation.protocolValue,
    });
  }

  WatchMessage _tileAnimationMessage() {
    return WatchMessage.command(WatchCommands.tileAnimation, {
      WatchKeys.buttonId: tileAnimationMode.protocolValue,
    });
  }

  WatchMessage _errorMessage({
    required int category,
    required int failedCommand,
    required String text,
    int offset = 0,
    int? worldX,
    int? worldY,
    int? zoom,
  }) {
    final instruction = utf8.decode(truncateUtf8Bytes(text, maxWatchTextBytes));
    final fields = <String, Object?>{
      WatchKeys.buttonId: category,
      WatchKeys.chunkIndex: failedCommand,
      WatchKeys.chunkOffset: offset,
      WatchKeys.instruction: instruction,
    };
    if (worldX != null) {
      fields[WatchKeys.worldX] = worldX;
    }
    if (worldY != null) {
      fields[WatchKeys.worldY] = worldY;
    }
    if (zoom != null) {
      fields[WatchKeys.tileZoom] = zoom;
    }
    return WatchMessage.command(WatchCommands.errorState, fields);
  }

  int _providerStatusToCategory(ProviderStatus status) {
    return switch (status.validationState) {
      ProviderValidationState.notConfigured => 1,
      ProviderValidationState.networkUnavailable => 4,
      ProviderValidationState.valid => 0,
      _ => 2,
    };
  }

  TravelMode _providerTravelMode(WatchTravelMode mode) {
    return switch (mode) {
      WatchTravelMode.walk => TravelMode.walk,
      WatchTravelMode.bike => TravelMode.bike,
      WatchTravelMode.drive => TravelMode.drive,
    };
  }

  int? get activeRouteSlot => _activeRouteSlot;
  WatchRouteEndpoint? get activeRouteTarget => _activeRouteTarget;
  DateTime? get lastRouteRequestedAt => _lastRouteRequestedAt;
  String? get lastRouteError => _lastRouteError;
}
