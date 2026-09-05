import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;

import 'about_screen.dart';
import 'battery_optimization_bridge.dart';
import 'bridge_channel.dart';
import 'first_run_setup_checklist.dart';
import 'location_bridge.dart';
import 'provider_bridge.dart';
import 'settings_screens.dart';
import 'watch_phone_worker.dart';
import 'watch_protocol.dart';

export 'settings_screens.dart';

const _startupLocationTimeout = Duration(milliseconds: 1200);
const _fallbackMapTarget = gmaps.LatLng(51.5074, -0.1278);
Future<T> _withFallback<T>(Future<T> future, T fallback) async {
  try {
    return await future;
  } catch (_) {
    return fallback;
  }
}

void main() {
  runApp(const MappyApp(enableEmbeddedGoogleMap: true));
}

class MappyApp extends StatelessWidget {
  const MappyApp({
    super.key,
    this.locationRepository,
    this.providerRepository,
    this.bridgeRepository,
    this.batteryOptimizationRepository,
    this.watchDispatcher,
    this.enableEmbeddedGoogleMap = false,
  });

  final LocationRepository? locationRepository;
  final ProviderRepository? providerRepository;
  final BridgeRepository? bridgeRepository;
  final BatteryOptimizationRepository? batteryOptimizationRepository;
  final WatchMessageDispatcher? watchDispatcher;
  final bool enableEmbeddedGoogleMap;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mappy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1D706D),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: CompanionHome(
        locationRepository:
            locationRepository ?? const NativeLocationRepository(),
        providerRepository:
            providerRepository ?? const NativeProviderRepository(),
        bridgeRepository: bridgeRepository ?? const NativeBridgeRepository(),
        batteryOptimizationRepository:
            batteryOptimizationRepository ??
            const NativeBatteryOptimizationRepository(),
        watchDispatcher: watchDispatcher,
        enableEmbeddedGoogleMap: enableEmbeddedGoogleMap,
      ),
    );
  }
}

enum CompanionTab { navigate, savedLocations, settings }

List<CompanionTab> companionTabs() {
  return [
    CompanionTab.navigate,
    CompanionTab.savedLocations,
    CompanionTab.settings,
  ];
}

class CompanionHome extends StatefulWidget {
  const CompanionHome({
    required this.locationRepository,
    required this.providerRepository,
    required this.bridgeRepository,
    required this.batteryOptimizationRepository,
    this.watchDispatcher,
    this.enableEmbeddedGoogleMap = false,
    super.key,
  });

  final LocationRepository locationRepository;
  final ProviderRepository providerRepository;
  final BridgeRepository bridgeRepository;
  final BatteryOptimizationRepository batteryOptimizationRepository;
  final WatchMessageDispatcher? watchDispatcher;
  final bool enableEmbeddedGoogleMap;

  @override
  State<CompanionHome> createState() => _CompanionHomeState();
}

class _CompanionHomeState extends State<CompanionHome>
    with WidgetsBindingObserver {
  CompanionTab _selectedTab = CompanionTab.navigate;
  LocationAccessStatus _locationAccessStatus =
      const LocationAccessStatus.unavailable();
  ProviderStatus _providerStatus = const ProviderStatus.notConfigured();
  BridgeStatus _bridgeStatus = const BridgeStatus.unavailable();
  RouteResult? _routeResult;
  ShareRoutingStatus? _shareStatus;
  WatchActiveRoute? _activeRoute;
  int _activeRouteSyncEpoch = 0;
  bool _initialActiveRouteSyncComplete = false;
  LocationSnapshot? _location;
  int _locationSyncEpoch = 0;
  MapTileSettings _mapTileSettings = MapTileSettings.defaults;
  WatchDisplaySettings _displaySettings = WatchDisplaySettings.defaults;
  List<WatchDestinationConfig> _savedLocations = const [];
  String? _savedLocationsDetail;
  bool _isComputingRoute = false;
  bool _isLoadingSavedLocations = true;
  bool _isSavingSavedLocation = false;
  bool _isClearingDiagnostics = false;
  bool _isClearingTileCache = false;
  bool _isClearingRouteCache = false;
  bool _isClearingProviderValidationCache = false;
  bool _bridgeReadinessLoaded = false;
  bool _locationReadinessLoaded = false;
  bool _batteryReadinessLoaded = false;
  int _setupReadinessSyncEpoch = 0;
  int _providerStatusEventRevision = 0;
  int _locationAccessEventRevision = 0;
  int _bridgeStatusEventRevision = 0;
  int? _setupChecklistVersion;
  bool _showFirstRunSetupChecklist = false;
  bool _setupChecklistDeferredForSession = false;
  bool _setupChecklistPersistenceScheduled = false;
  String? _watchSessionDetail;
  BatteryOptimizationState _batteryOptimizationState =
      BatteryOptimizationState.unknown;
  final List<String> _diagnosticEvents = [];
  late final WatchMessageDispatcher _navigationDispatcher;
  StreamSubscription<BridgeEvent>? _bridgeSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _navigationDispatcher =
        widget.watchDispatcher ??
        NativeWatchMessageDispatcher(
          providerRepository: widget.providerRepository,
        );
    _bridgeSubscription = widget.bridgeRepository.events.listen(
      _handleBridgeEvent,
      onError: (_) {},
    );
    unawaited(_loadSetupChecklistVersion());
    unawaited(_loadMapTileSettings());
    unawaited(_loadDisplaySettings());
    unawaited(_loadSavedLocations());
    unawaited(_refreshActiveRoute());
    unawaited(_refreshLocation(timeout: _startupLocationTimeout));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_bridgeSubscription?.cancel());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      return;
    }
    unawaited(_refreshLocation(timeout: _startupLocationTimeout));
    unawaited(_refreshActiveRoute());
  }

  Future<void> _refreshActiveRoute() async {
    final epoch = ++_activeRouteSyncEpoch;
    late final WatchActiveRoute? route;
    try {
      route = await _navigationDispatcher.getActiveRoute();
    } catch (error) {
      if (!mounted || epoch != _activeRouteSyncEpoch) return;
      setState(() {
        _initialActiveRouteSyncComplete = true;
        _diagnosticEvents.insert(0, 'Active route refresh failed: $error');
      });
      _maybeShowFirstRunSetupChecklist();
      return;
    }
    if (!mounted || epoch != _activeRouteSyncEpoch) return;
    _setActiveRoute(route, marksInitialSyncComplete: true);
    _maybeShowFirstRunSetupChecklist();
  }

  void _setActiveRoute(
    WatchActiveRoute? route, {
    bool marksInitialSyncComplete = false,
  }) {
    final previous = _activeRoute;
    final changed =
        previous?.requestId != route?.requestId ||
        previous?.updatedAtMillis != route?.updatedAtMillis;
    setState(() {
      if (marksInitialSyncComplete) {
        _initialActiveRouteSyncComplete = true;
      }
      _activeRoute = route;
      if (route != null) {
        _setupChecklistDeferredForSession = true;
        _showFirstRunSetupChecklist = false;
        _shareStatus = null;
      }
      if (changed || route == null) _routeResult = null;
    });
  }

  Future<PermissionsSnapshot> _refreshSetupReadiness() async {
    final epoch = ++_setupReadinessSyncEpoch;
    final providerEventRevision = _providerStatusEventRevision;
    final locationEventRevision = _locationAccessEventRevision;
    final bridgeEventRevision = _bridgeStatusEventRevision;
    final providerFuture = _withFallback(
      widget.providerRepository.getProviderStatus(),
      _providerStatus,
    );
    final locationFuture = _withFallback(
      widget.locationRepository.getLocationAccessStatus(),
      _locationAccessStatus,
    );
    final bridgeFuture = _withFallback(
      widget.bridgeRepository.getBridgeStatus(),
      _bridgeStatus,
    );
    final batteryFuture = _withFallback(
      widget.batteryOptimizationRepository.getBatteryOptimizationState(),
      _batteryOptimizationState,
    );

    final provider = await providerFuture;
    final location = await locationFuture;
    final bridge = await bridgeFuture;
    final battery = await batteryFuture;
    if (!mounted || epoch != _setupReadinessSyncEpoch) {
      return _permissionsSnapshot;
    }

    final effectiveProvider =
        providerEventRevision == _providerStatusEventRevision
        ? provider
        : _providerStatus;
    final effectiveLocation =
        locationEventRevision == _locationAccessEventRevision
        ? location
        : _locationAccessStatus;
    final effectiveBridge =
        (bridgeEventRevision == _bridgeStatusEventRevision
                ? bridge
                : _bridgeStatus)
            .copyWith(
              providerStatus: effectiveProvider,
              locationAccessStatus: effectiveLocation,
            );
    final snapshot = PermissionsSnapshot(
      location: effectiveLocation,
      notification: effectiveBridge.notificationPermissionState,
      battery: battery,
    );
    setState(() {
      _providerStatus = effectiveProvider;
      _locationAccessStatus = effectiveLocation;
      _bridgeStatus = effectiveBridge;
      _batteryOptimizationState = battery;
      _bridgeReadinessLoaded = true;
      _locationReadinessLoaded = true;
      _batteryReadinessLoaded = true;
    });
    _maybeShowFirstRunSetupChecklist();
    return snapshot;
  }

  Future<BridgeStatus> _loadBridgeStatus() async {
    final status = await widget.bridgeRepository.getBridgeStatus();
    if (mounted) {
      await _refreshSetupReadiness();
      return _bridgeStatus;
    }
    return status;
  }

  Future<BridgeStatus> _startWatchApp() async {
    setState(() {
      _watchSessionDetail = null;
    });
    final status = await widget.bridgeRepository.startWatchApp();
    if (!mounted) {
      return status;
    }
    setState(() {
      _watchSessionDetail = status.registered
          ? 'Opening the Mappy watch app.'
          : 'Pebble/Rebble is not ready on this phone.';
    });
    unawaited(_refreshSetupReadiness());
    return status;
  }

  Future<BridgeStatus> _requestNotificationPermission() async {
    setState(() {
      _watchSessionDetail = null;
    });
    final status = await widget.bridgeRepository
        .requestNotificationPermission();
    if (!mounted) {
      return status;
    }
    setState(() {
      _watchSessionDetail =
          status.notificationPermissionState.allowsWatchNotification
          ? 'Watch-session notifications are ready.'
          : 'Allow notifications in Android settings so the watch session can stay visible.';
    });
    return status;
  }

  Future<BatteryOptimizationState> _requestDisableBatteryOptimization() =>
      widget.batteryOptimizationRepository.requestDisableBatteryOptimization();

  void _handleBridgeEvent(BridgeEvent event) {
    if (!mounted) return;
    if (event.type == 'displaySettingsChanged') {
      unawaited(_loadDisplaySettings());
    }
    final status = event.status;
    final providerStatus = event.providerStatus;
    final locationStream = event.locationStream;
    final locationAccess = event.locationAccessStatus;
    final shareStatus = event.shareStatus;
    final diagnostic = _diagnosticLine(event);
    const watchSessionDetailEvents = {
      'navigationQueued',
      'watchLaunchRequested',
      'navigationApplied',
      'navigationDeliveryTimeout',
      'watchLaunchFailed',
      'protocolMismatch',
    };
    final updatesWatchSessionDetail = watchSessionDetailEvents.contains(
      event.type,
    );
    if (status != null || locationStream != null) {
      _bridgeStatusEventRevision += 1;
    }
    if (providerStatus != null) _providerStatusEventRevision += 1;
    if (locationAccess != null) _locationAccessEventRevision += 1;
    final hasVisibleUpdate =
        updatesWatchSessionDetail ||
        status != null ||
        providerStatus != null ||
        locationStream != null ||
        locationAccess != null ||
        event.type == 'activeRouteChanged' ||
        shareStatus != null ||
        diagnostic != null;
    if (!hasVisibleUpdate) return;
    setState(() {
      switch (event.type) {
        case 'navigationQueued':
          _watchSessionDetail = 'Synchronizing route with watch.';
        case 'watchLaunchRequested':
          _watchSessionDetail = 'Opening watch app.';
        case 'navigationApplied':
          _watchSessionDetail = 'Route applied on watch.';
        case 'navigationDeliveryTimeout':
          _watchSessionDetail = 'Route queued; watch did not confirm.';
        case 'watchLaunchFailed':
          _watchSessionDetail = 'Watch app could not be opened.';
        case 'protocolMismatch':
          _watchSessionDetail = 'Update the phone and watch apps together.';
      }
      if (status != null) {
        _bridgeStatus = status;
        _locationAccessStatus = status.locationAccessStatus;
        _bridgeReadinessLoaded = true;
      }
      if (providerStatus != null) {
        _providerStatus = providerStatus;
        _bridgeStatus = _bridgeStatus.copyWith(providerStatus: providerStatus);
      }
      if (locationStream != null) {
        _bridgeStatus = _bridgeStatus.copyWith(locationStream: locationStream);
      }
      if (locationAccess != null) {
        _locationAccessStatus = locationAccess;
        _bridgeStatus = _bridgeStatus.copyWith(
          locationAccessStatus: locationAccess,
        );
        _locationReadinessLoaded = true;
      }
      if (event.type == 'activeRouteChanged') {
        if (event.activeRouteMalformed) {
          _diagnosticEvents.insert(0, 'Ignored malformed active route event.');
        } else {
          _initialActiveRouteSyncComplete = true;
          _activeRouteSyncEpoch++;
          final next = event.activeRoute;
          final changed =
              _activeRoute?.requestId != next?.requestId ||
              _activeRoute?.updatedAtMillis != next?.updatedAtMillis;
          _activeRoute = next;
          if (next != null) {
            _setupChecklistDeferredForSession = true;
            _showFirstRunSetupChecklist = false;
          }
          if (changed || next == null) _routeResult = null;
          if (next != null) _shareStatus = null;
        }
      }
      if (shareStatus != null) {
        _selectedTab = CompanionTab.navigate;
        if (_activeRoute == null) {
          _shareStatus = shareStatus;
          if (!shareStatus.isTerminal) {
            _showFirstRunSetupChecklist = false;
          }
        }
      }
      if (diagnostic != null) {
        _diagnosticEvents.insert(0, diagnostic);
        if (_diagnosticEvents.length > 25) {
          _diagnosticEvents.removeRange(25, _diagnosticEvents.length);
        }
      }
    });
    _maybeShowFirstRunSetupChecklist();
  }

  String? _diagnosticLine(BridgeEvent event) {
    if (event.type == 'providerStatus') {
      final status = event.providerStatus;
      return status == null
          ? null
          : 'Provider ${status.providerLabel}: ${status.keyLabel}';
    }
    if (event.type == 'locationStatus') {
      final stream = event.locationStream;
      return stream == null ? null : 'Location stream: ${stream.label}';
    }
    if (event.type == 'shareStatus') {
      final status = event.shareStatus;
      return status == null ? null : 'Share: ${status.subtitle}';
    }
    if (event.type == 'diagnosticEvent' || event.type == 'deliveryFailure') {
      final command = event.failedCommand ?? event.command;
      final detail =
          event.message ??
          event.detail ??
          event.result ??
          event.reason ??
          event.type;
      final category = event.category == null
          ? ''
          : ' category ${event.category}';
      final commandText = command == null ? '' : ' command $command';
      final severity = event.severity == null ? '' : '${event.severity}: ';
      return '$severity$detail$category$commandText';
    }
    if (event.type == 'sendResult') {
      final command = event.command == null ? '' : ' command ${event.command}';
      return 'Send ${event.result ?? 'updated'}$command';
    }
    return null;
  }

  Future<void> _exportDiagnostics() async {
    final nativePayload = await widget.bridgeRepository.exportDiagnostics();
    final payload = _diagnosticsExportPayload(nativePayload);
    await Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent('  ').convert(payload)),
    );
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Diagnostics copied.')));
  }

  Future<void> _clearDiagnostics() async {
    setState(() {
      _isClearingDiagnostics = true;
    });
    await widget.bridgeRepository.clearDiagnostics();
    if (!mounted) {
      return;
    }
    setState(() {
      _diagnosticEvents.clear();
      _isClearingDiagnostics = false;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Diagnostics cleared.')));
  }

  Map<String, Object?> _diagnosticsExportPayload(
    Map<String, Object?> nativePayload,
  ) {
    final events = nativePayload['events'];
    final hasNativeEvents = events is Iterable && events.isNotEmpty;
    final payload = hasNativeEvents
        ? nativePayload
        : {
            ..._emptyDiagnosticsExportPayload(),
            ...nativePayload,
            'events': _fallbackDiagnosticEvents(),
          };
    final redacted = _redactDiagnosticPayload(payload);
    return redacted is Map<String, Object?>
        ? redacted
        : _emptyDiagnosticsExportPayload();
  }

  Map<String, Object?> _emptyDiagnosticsExportPayload() {
    return {
      'schema_version': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'app_package': 'com.leapwardkoex.mappy',
      'app_version': 'unknown',
      'watch_uuid': '18b376dc-40ef-464f-abfb-b1612ea94f7d',
      'redaction': {'full_keys': 'redacted', 'location': 'default'},
      'status': <String, Object?>{},
      'events': <Object?>[],
    };
  }

  List<Map<String, Object?>> _fallbackDiagnosticEvents() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return [
      for (var index = 0; index < _diagnosticEvents.length; index += 1)
        {
          'id': index + 1,
          'timestamp_wall_ms': now,
          'source': 'flutter',
          'level': 'info',
          'event': 'diagnostics_exported',
          'message': _redactDiagnosticText(_diagnosticEvents[index]),
        },
    ];
  }

  Object? _redactDiagnosticPayload(Object? value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _redactDiagnosticPayload(entry.value),
      };
    }
    if (value is Iterable) {
      return value.map(_redactDiagnosticPayload).toList(growable: false);
    }
    if (value is String) {
      return _redactDiagnosticText(value);
    }
    return value;
  }

  String _redactDiagnosticText(String value) {
    final secretPattern = RegExp(
      r'(api[_ -]?key|token|secret|credential|password)([:= ]+)[^\s,;]+',
      caseSensitive: false,
    );
    var redacted = value.replaceAllMapped(secretPattern, (match) {
      return '${match.group(1)}${match.group(2)}[redacted]';
    });
    redacted = redacted.replaceAll(
      RegExp(r'AIza[0-9A-Za-z_-]{16,}'),
      'AIza...[redacted]',
    );
    redacted = redacted.replaceAll(
      RegExp(r'Authorization\s*[:=]\s*[^\r\n,;]+', caseSensitive: false),
      'Authorization: [redacted]',
    );
    redacted = redacted.replaceAll(
      RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      'Bearer [redacted]',
    );
    redacted = redacted.replaceAllMapped(
      RegExp(
        r'([?&](?:key|token|sessiontoken|session_token|signature|authorization)=)[^\s&#]+',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}[redacted]',
    );
    return redacted;
  }

  Future<void> _loadMapTileSettings() async {
    final result = await widget.providerRepository.getMapTileSettings();
    if (!mounted) {
      return;
    }
    setState(() {
      _mapTileSettings = result.settings;
    });
  }

  Future<void> _loadDisplaySettings() async {
    final settings = await _navigationDispatcher.getDisplaySettings();
    if (!mounted) {
      return;
    }
    setState(() {
      _displaySettings = settings;
    });
  }

  Future<void> _loadSavedLocations() async {
    final destinations = await _navigationDispatcher.getDestinations();
    if (!mounted) {
      return;
    }
    setState(() {
      _savedLocations = _sortedSavedLocations(destinations);
      _isLoadingSavedLocations = false;
    });
  }

  Future<void> _refreshLocation({Duration? timeout}) async {
    await _refreshSetupReadiness();
    await _refreshGpsFix(timeout: timeout);
  }

  Future<void> _refreshGpsFix({Duration? timeout}) async {
    final epoch = ++_locationSyncEpoch;
    final locationAccess = _locationAccessStatus;
    final location =
        locationAccess.servicesEnabled && locationAccess.foregroundGranted
        ? await widget.locationRepository.getCurrentLocation(timeout: timeout)
        : null;

    if (!mounted || epoch != _locationSyncEpoch) {
      return;
    }

    setState(() {
      _location = location;
    });
  }

  Future<LocationAccessStatus> _requestLocationPermission() async {
    return widget.locationRepository.requestForegroundLocationPermission();
  }

  Future<bool> _openAppLocationSettings() =>
      widget.locationRepository.openAppLocationSettings();

  Future<bool> _openLocationServicesSettings() =>
      widget.locationRepository.openLocationServicesSettings();

  Future<bool> _openNotificationSettings() =>
      widget.bridgeRepository.openNotificationSettings();

  Future<PermissionsSnapshot> _refreshPermissionsSnapshot() async {
    return _refreshSetupReadiness();
  }

  Future<ProviderStatus> _storeUserApiKey(String apiKey) =>
      widget.providerRepository.storeApiKey(apiKey);

  Future<ProviderStatus> _validateProviderSetup() async {
    final providerStatus = await widget.providerRepository
        .validateProviderSetup();

    if (mounted) await _refreshSetupReadiness();
    return providerStatus;
  }

  Future<MapTileSettings> _applyMapTileSettings(
    MapTileSettings settings,
  ) async {
    setState(() {
      _mapTileSettings = settings;
    });

    final result = await widget.providerRepository.setMapTileSettings(settings);
    final watchMessage = result.watchMessage;
    if (watchMessage != null) {
      await _navigationDispatcher.sendPhoneMessage(watchMessage);
    }
    if (!mounted) {
      return result.settings;
    }

    setState(() {
      _mapTileSettings = result.settings;
    });
    return result.settings;
  }

  Future<void> _clearMapTileCache() async {
    setState(() {
      _isClearingTileCache = true;
    });

    final result = await widget.providerRepository.clearMapTileCache();
    final watchMessage = result.watchMessage;
    if (watchMessage != null) {
      await _navigationDispatcher.sendPhoneMessage(watchMessage);
    }
    if (!mounted) {
      return;
    }

    setState(() {
      _mapTileSettings = result.settings;
      _isClearingTileCache = false;
    });
  }

  Future<void> _clearRouteCacheFromDiagnostics() async {
    setState(() {
      _isClearingRouteCache = true;
    });
    late final WatchNavigationDispatchResult dispatchResult;
    try {
      dispatchResult = await _navigationDispatcher.clearActiveRoute();
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isClearingRouteCache = false;
      });
      return;
    }
    if (!mounted) {
      return;
    }
    if (dispatchResult.deliveryState ==
        WatchNavigationDeliveryState.deliveryFailed) {
      setState(() => _isClearingRouteCache = false);
      return;
    }
    setState(() {
      _routeResult = null;
      _activeRoute = null;
      _isClearingRouteCache = false;
    });
  }

  Future<void> _clearProviderValidationCache() async {
    setState(() {
      _isClearingProviderValidationCache = true;
    });
    await widget.providerRepository.clearProviderValidationCache();
    if (!mounted) return;
    await _refreshSetupReadiness();
    if (!mounted) return;
    setState(() => _isClearingProviderValidationCache = false);
  }

  Future<WatchDisplaySettings> _applyDisplaySettings(
    WatchDisplaySettings settings,
  ) async {
    setState(() {
      _displaySettings = settings;
    });

    await _navigationDispatcher.setDisplaySettings(settings);

    if (!mounted) {
      return settings;
    }

    setState(() {
      _displaySettings = settings;
    });
    return settings;
  }

  Future<String> _navigateNowRoute({
    required WatchRouteOriginPolicy originPolicy,
    WatchRouteEndpoint? origin,
    required WatchRouteEndpoint destination,
    required TravelMode travelMode,
  }) async {
    if (originPolicy == WatchRouteOriginPolicy.explicitPlace &&
        origin == null) {
      return 'Choose a route origin first.';
    }

    setState(() {
      _isComputingRoute = true;
      _watchSessionDetail = 'Calculating route.';
    });

    late final WatchNavigationDispatchResult dispatchResult;
    try {
      dispatchResult = await _navigationDispatcher.startNavigation(
        WatchNavigationRequest(
          originPolicy: originPolicy,
          origin: origin,
          destination: destination,
          travelMode: _watchTravelModeFor(travelMode),
        ),
      );
    } catch (_) {
      if (!mounted) {
        return 'Route request failed.';
      }
      setState(() {
        _isComputingRoute = false;
      });
      return 'Route request failed.';
    }

    if (!mounted) {
      return 'Route request finished.';
    }

    final routeResult = _routeResultFromWatchResponses(
      dispatchResult.responses,
      status: _navigationDispatcher.lastProviderStatus.configured
          ? _navigationDispatcher.lastProviderStatus
          : _providerStatus,
      travelMode: travelMode,
      destination: destination,
    );
    if (routeResult.ok) await _refreshActiveRoute();
    if (!mounted) return 'Route request finished.';
    setState(() {
      _providerStatus = routeResult.status;
      if (routeResult.ok || routeResult.errorCategory == 7) {
        _routeResult = routeResult;
      }
      if (routeResult.errorCategory == 7) _activeRoute = null;
      _isComputingRoute = false;
      _watchSessionDetail = dispatchResult.detail;
    });
    if (!routeResult.ok) {
      return routeResult.detail ?? 'Route failed.';
    }
    return switch (dispatchResult.deliveryState) {
      WatchNavigationDeliveryState.applied => _navigationSentMessage(
        destination.label,
      ),
      WatchNavigationDeliveryState.launchFailed ||
      WatchNavigationDeliveryState.timedOut ||
      WatchNavigationDeliveryState.queued =>
        dispatchResult.detail ?? 'Route ready on phone; watch did not confirm.',
      WatchNavigationDeliveryState.protocolMismatch =>
        dispatchResult.detail ?? 'Update the phone and watch apps together.',
      WatchNavigationDeliveryState.deliveryFailed =>
        dispatchResult.detail ?? 'Route delivery failed.',
    };
  }

  Future<String> _rerouteActiveRoute() async {
    final activeRoute = _activeRoute;
    if (activeRoute == null) {
      return 'No active route to reroute.';
    }
    final destination = activeRoute.destination;
    final travelMode = _travelModeForWatch(activeRoute.travelMode);

    setState(() {
      _isComputingRoute = true;
      _watchSessionDetail = 'Calculating reroute.';
    });

    late final WatchNavigationDispatchResult dispatchResult;
    try {
      dispatchResult = await _navigationDispatcher.rerouteActiveRoute();
    } catch (_) {
      if (!mounted) {
        return 'Reroute request failed.';
      }
      setState(() {
        _isComputingRoute = false;
      });
      return 'Reroute request failed.';
    }

    if (!mounted) {
      return 'Reroute request finished.';
    }

    final routeResult = _routeResultFromWatchResponses(
      dispatchResult.responses,
      status: _navigationDispatcher.lastProviderStatus.configured
          ? _navigationDispatcher.lastProviderStatus
          : _providerStatus,
      travelMode: travelMode,
      destination: destination,
    );
    if (routeResult.ok) await _refreshActiveRoute();
    if (!mounted) return 'Reroute request finished.';
    setState(() {
      _providerStatus = routeResult.status;
      if (routeResult.ok || routeResult.errorCategory == 7) {
        _routeResult = routeResult;
      }
      if (routeResult.errorCategory == 7) {
        _activeRoute = null;
      }
      _isComputingRoute = false;
      _watchSessionDetail = dispatchResult.detail;
    });
    if (!routeResult.ok) return routeResult.detail ?? 'Reroute failed.';
    return dispatchResult.deliveryState == WatchNavigationDeliveryState.applied
        ? 'Route refreshed and confirmed on watch.'
        : dispatchResult.detail ?? 'Route refreshed; watch did not confirm.';
  }

  Future<String> _clearActiveRoute() async {
    setState(() {
      _isComputingRoute = true;
      _watchSessionDetail = 'Clearing route on watch.';
    });
    late final WatchNavigationDispatchResult dispatchResult;
    try {
      dispatchResult = await _navigationDispatcher.clearActiveRoute();
    } catch (_) {
      if (!mounted) {
        return 'Clear route failed.';
      }
      setState(() {
        _isComputingRoute = false;
      });
      return 'Clear route failed.';
    }
    if (!mounted) {
      return 'Route clear finished.';
    }
    if (dispatchResult.deliveryState ==
        WatchNavigationDeliveryState.deliveryFailed) {
      setState(() {
        _isComputingRoute = false;
        _watchSessionDetail = dispatchResult.detail;
      });
      return dispatchResult.detail ?? 'End navigation failed.';
    }
    setState(() {
      _routeResult = null;
      _activeRoute = null;
      _isComputingRoute = false;
      _watchSessionDetail = dispatchResult.detail;
    });
    return dispatchResult.detail ?? 'Route clear queued.';
  }

  Future<String> _saveSavedLocation(WatchDestinationConfig config) async {
    final result = await _applySavedLocationUpdate(config);
    return result.message;
  }

  Future<String?> _clearSavedLocation(int slotIndex) async {
    final result = await _applySavedLocationUpdate(
      WatchDestinationConfig(
        slotIndex: slotIndex,
        enabled: false,
        label: savedLocationSlotTitle(slotIndex),
        address: savedLocationSlotTitle(slotIndex),
        latitude: 0,
        longitude: 0,
        kind: savedLocationKind(slotIndex),
        defaultTravelMode: WatchTravelMode.drive,
      ),
    );
    return result.success ? null : result.message;
  }

  Future<_SavedLocationUpdateResult> _applySavedLocationUpdate(
    WatchDestinationConfig config,
  ) async {
    setState(() {
      _isSavingSavedLocation = true;
      _savedLocationsDetail = null;
    });

    late final List<WatchMessage> responses;
    try {
      responses = await _navigationDispatcher.replaceDestination(config);
    } catch (error) {
      if (!mounted) {
        return const _SavedLocationUpdateResult.failure(
          'Saved location update failed.',
        );
      }
      setState(() {
        _savedLocationsDetail = 'Saved location update failed.';
        _isSavingSavedLocation = false;
      });
      return const _SavedLocationUpdateResult.failure(
        'Saved location update failed.',
      );
    }

    final errorText = _errorTextFromWatchResponses(responses);
    if (!mounted) {
      return _SavedLocationUpdateResult(
        success: errorText == null,
        message: errorText ?? 'Saved location updated.',
      );
    }

    if (errorText != null) {
      setState(() {
        _savedLocationsDetail = errorText;
        _isSavingSavedLocation = false;
      });
      return _SavedLocationUpdateResult.failure(errorText);
    }

    final previousLabel = _savedLocations
        .where((item) => item.slotIndex == config.slotIndex)
        .map((item) => item.label)
        .firstOrNull;
    setState(() {
      final next = _savedLocations
          .where((item) => item.slotIndex != config.slotIndex)
          .toList();
      if (config.enabled) {
        next.add(config);
      }
      _savedLocations = _sortedSavedLocations(next);
      _savedLocationsDetail = config.enabled
          ? '${config.label} saved.'
          : '${previousLabel ?? savedLocationSlotTitle(config.slotIndex)} cleared.';
      _isSavingSavedLocation = false;
    });
    return _SavedLocationUpdateResult.success(_savedLocationsDetail!);
  }

  List<WatchDestinationConfig> _sortedSavedLocations(
    List<WatchDestinationConfig> destinations,
  ) {
    return destinations
        .where((item) => item.enabled && isSavedLocationId(item.slotIndex))
        .toList()
      ..sort((a, b) => a.slotIndex.compareTo(b.slotIndex));
  }

  String? _errorTextFromWatchResponses(List<WatchMessage> responses) {
    for (final response in responses) {
      if (response.command == WatchCommands.errorState) {
        final text = response.fields[WatchKeys.instruction];
        return text is String && text.trim().isNotEmpty
            ? text.trim()
            : 'Watch rejected the update.';
      }
    }
    return null;
  }

  RouteResult _routeResultFromWatchResponses(
    List<WatchMessage> responses, {
    required ProviderStatus status,
    required TravelMode travelMode,
    required WatchRouteEndpoint destination,
  }) {
    DecodedRoutePayload? routePayload;
    DecodedNavStepsPayload? navPayload;
    int? errorCategory;
    String? errorText;

    for (final response in responses) {
      switch (response.command) {
        case WatchCommands.routePoints:
          final bytes = response.chunkData;
          if (bytes != null) {
            routePayload = decodeRoutePoints(bytes);
          }
        case WatchCommands.navSteps:
          final bytes = response.chunkData;
          if (bytes != null) {
            navPayload = decodeNavSteps(bytes);
          }
        case WatchCommands.errorState:
          errorCategory = asInt(response.fields[WatchKeys.buttonId]);
          errorText = response.fields[WatchKeys.instruction] as String?;
      }
    }

    if (routePayload != null &&
        !routePayload.clearsRoute &&
        routePayload.points.length >= 2) {
      final navSteps = navPayload?.steps ?? const <WatchNavStep>[];
      final firstStep = navSteps.isEmpty ? null : navSteps.first;
      return RouteResult(
        ok: true,
        status: status,
        travelMode: travelMode,
        distanceMeters: firstStep?.remainingMeters,
        durationSeconds: firstStep?.remainingSeconds,
        destinationLatitude: destination.latitude,
        destinationLongitude: destination.longitude,
        formattedAddress: destination.address,
        placeId: destination.placeId,
        routePoints: routePayload.points
            .map(
              (point) => RoutePoint(
                latitude: 0,
                longitude: 0,
                worldX: point.worldX,
                worldY: point.worldY,
              ),
            )
            .toList(growable: false),
        steps: navSteps
            .map(
              (step) => RouteStep(
                index: step.globalIndex,
                startLatitude: 0,
                startLongitude: 0,
                startWorldX: step.startWorldX,
                startWorldY: step.startWorldY,
                instruction: step.instruction,
                distanceMeters: 0,
                durationSeconds: 0,
                remainingMeters: step.remainingMeters,
                remainingSeconds: step.remainingSeconds,
              ),
            )
            .toList(growable: false),
        detail: 'Watch route payload sent.',
        routeWarning: _routeWarningFor(travelMode),
      );
    }

    return RouteResult(
      ok: false,
      status: status,
      travelMode: travelMode,
      destinationLatitude: destination.latitude,
      destinationLongitude: destination.longitude,
      formattedAddress: destination.address,
      placeId: destination.placeId,
      detail: errorText ?? 'Navigation did not return a route.',
      errorCategory: errorCategory,
      routeWarning: _routeWarningFor(travelMode),
    );
  }

  WatchTravelMode _watchTravelModeFor(TravelMode mode) {
    return switch (mode) {
      TravelMode.drive => WatchTravelMode.drive,
      TravelMode.walk => WatchTravelMode.walk,
      TravelMode.bike => WatchTravelMode.bike,
    };
  }

  TravelMode _travelModeForWatch(WatchTravelMode mode) {
    return switch (mode) {
      WatchTravelMode.drive => TravelMode.drive,
      WatchTravelMode.walk => TravelMode.walk,
      WatchTravelMode.bike => TravelMode.bike,
    };
  }

  String? _routeWarningFor(TravelMode mode) {
    return mode == TravelMode.drive
        ? null
        : 'Walk and bike routes may miss safe pedestrian or bicycling path detail.';
  }

  Future<ProviderStatus> _clearApiKey() async {
    final providerStatus = await widget.providerRepository.clearApiKey();
    if (!mounted) return providerStatus;
    await _refreshSetupReadiness();
    if (!mounted) return providerStatus;
    setState(() => _routeResult = null);
    return providerStatus;
  }

  bool get _readinessLoaded =>
      _bridgeReadinessLoaded &&
      _locationReadinessLoaded &&
      _batteryReadinessLoaded;

  SetupChecklistSnapshot get _setupChecklistSnapshot => SetupChecklistSnapshot(
    providerStatus: _providerStatus,
    permissions: _permissionsSnapshot,
  );

  Future<void> _loadSetupChecklistVersion() async {
    final version = await _withFallback(
      widget.bridgeRepository.getSetupChecklistVersion(),
      0,
    );
    if (!mounted) return;
    setState(() => _setupChecklistVersion = math.max(0, version));
    _maybeShowFirstRunSetupChecklist();
  }

  void _maybeShowFirstRunSetupChecklist() {
    if (!mounted ||
        _showFirstRunSetupChecklist ||
        _setupChecklistDeferredForSession ||
        _setupChecklistVersion == null ||
        _setupChecklistVersion! >= setupChecklistCurrentVersion ||
        !_readinessLoaded ||
        !_initialActiveRouteSyncComplete ||
        _activeRoute != null ||
        _shareStatus != null) {
      return;
    }
    setState(() {
      _showFirstRunSetupChecklist = true;
    });
    if (_setupChecklistPersistenceScheduled) return;
    _setupChecklistPersistenceScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupChecklistPersistenceScheduled = false;
      if (!mounted ||
          !_showFirstRunSetupChecklist ||
          _activeRoute != null ||
          _shareStatus != null) {
        return;
      }
      unawaited(_recordSetupChecklistShown());
    });
  }

  Future<void> _recordSetupChecklistShown() async {
    final stored = await _withFallback(
      widget.bridgeRepository.setSetupChecklistVersion(
        setupChecklistCurrentVersion,
      ),
      false,
    );
    if (!mounted) return;
    setState(() {
      if (stored) {
        _setupChecklistVersion = setupChecklistCurrentVersion;
      } else {
        _diagnosticEvents.insert(
          0,
          'Setup checklist state could not be saved.',
        );
      }
    });
  }

  void _closeFirstRunSetupChecklist() {
    setState(() {
      _showFirstRunSetupChecklist = false;
      _setupChecklistDeferredForSession = true;
    });
  }

  bool get _providerNeedsAttention => !_providerReady(_providerStatus);

  bool get _permissionsNeedAttention =>
      !_locationAccessStatus.isReady ||
      !_bridgeStatus.notificationPermissionState.allowsWatchNotification ||
      _batteryOptimizationState != BatteryOptimizationState.disabled;

  String get _setupChecklistSummary {
    if (!_readinessLoaded) return 'Checking…';
    final snapshot = _setupChecklistSnapshot;
    if (!snapshot.requiredReady) return 'Required setup incomplete';
    if (!snapshot.reliabilityReady) return 'Recommendations available';
    return 'Ready';
  }

  PermissionsSnapshot get _permissionsSnapshot => PermissionsSnapshot(
    location: _locationAccessStatus,
    notification: _bridgeStatus.notificationPermissionState,
    battery: _batteryOptimizationState,
  );

  void _pushPage(Widget page) {
    Navigator.of(
      context,
    ).push<void>(MaterialPageRoute<void>(builder: (_) => page));
  }

  Future<ProviderStatus> _openGoogleSetup() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => GoogleMapsSetupScreen(
          initialStatus: _providerStatus,
          onStoreApiKey: _storeUserApiKey,
          onValidateProviderSetup: _validateProviderSetup,
          onRemoveKey: _clearApiKey,
        ),
      ),
    );
    if (mounted) await _refreshSetupReadiness();
    return _providerStatus;
  }

  Future<PermissionsSnapshot> _openPermissions({
    PermissionsFocus? focus,
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PermissionsScreen(
          initialSnapshot: _permissionsSnapshot,
          focus: focus,
          onRefresh: _refreshPermissionsSnapshot,
          onRequestForegroundLocation: _requestLocationPermission,
          onOpenAppLocationSettings: _openAppLocationSettings,
          onOpenLocationServicesSettings: _openLocationServicesSettings,
          onRequestNotifications: _requestNotificationPermission,
          onOpenNotificationSettings: _openNotificationSettings,
          onRequestBatteryExemption: _requestDisableBatteryOptimization,
        ),
      ),
    );
    final snapshot = await _refreshSetupReadiness();
    if (mounted) {
      unawaited(_refreshGpsFix(timeout: _startupLocationTimeout));
    }
    return snapshot;
  }

  void _openWatchConnection() => _pushPage(
    WatchConnectionScreen(
      initialStatus: _bridgeStatus,
      initialDetail: _watchSessionDetail,
      onRefresh: _loadBridgeStatus,
      onOpenWatch: _startWatchApp,
    ),
  );

  void _openNavigationPreferences() => _pushPage(
    NavigationPreferencesScreen(
      initialSettings: _displaySettings,
      onChanged: _applyDisplaySettings,
    ),
  );

  void _openAppearancePreferences() => _pushPage(
    AppearancePreferencesScreen(
      initialSettings: _displaySettings,
      onChanged: _applyDisplaySettings,
    ),
  );

  void _openWatchMapPreferences() => _pushPage(
    WatchMapPreferencesScreen(
      initialDisplaySettings: _displaySettings,
      initialMapSettings: _mapTileSettings,
      onDisplayChanged: _applyDisplaySettings,
      onMapChanged: _applyMapTileSettings,
    ),
  );

  void _openDiagnostics() => _pushPage(
    DiagnosticsScreen(
      events: _diagnosticEvents,
      isClearingDiagnostics: _isClearingDiagnostics,
      onExportDiagnostics: _exportDiagnostics,
      onClearDiagnostics: _clearDiagnostics,
      isClearingTileCache: _isClearingTileCache,
      onClearTileCache: _clearMapTileCache,
      isClearingRouteCache: _isClearingRouteCache,
      onClearRouteCache: _clearRouteCacheFromDiagnostics,
      isClearingProviderValidationCache: _isClearingProviderValidationCache,
      onClearProviderValidationCache: _clearProviderValidationCache,
    ),
  );

  void _openSetupChecklist() => _pushPage(
    _ManualSetupChecklistPage(
      initialSnapshot: _setupChecklistSnapshot,
      onRefresh: () async {
        await _refreshSetupReadiness();
        return _setupChecklistSnapshot;
      },
      onOpenGoogleSetup: () async {
        await _openGoogleSetup();
      },
      onOpenPermissions: (focus) async {
        await _openPermissions(focus: focus);
      },
    ),
  );

  void _openAbout() => _pushPage(const AboutScreen());

  void _dismissShareStatus() {
    setState(() => _shareStatus = null);
    _maybeShowFirstRunSetupChecklist();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = companionTabs();
    final settingsNeedsAttention =
        _readinessLoaded &&
        (_providerNeedsAttention || _permissionsNeedAttention);
    final setupChecklistChecking =
        _activeRoute == null &&
        _shareStatus == null &&
        (_setupChecklistVersion == null ||
            !_readinessLoaded ||
            !_initialActiveRouteSyncComplete);
    final title = switch (_selectedTab) {
      CompanionTab.navigate => 'Navigate',
      CompanionTab.savedLocations => 'Saved Locations',
      CompanionTab.settings => 'Settings',
    };

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: IndexedStack(
          index: tabs.indexOf(_selectedTab),
          children: [
            TickerMode(
              enabled: _selectedTab == CompanionTab.navigate,
              child: NavigateScreen(
                key: const PageStorageKey('navigate-tab'),
                providerStatus: _providerStatus,
                location: _location,
                routeResult: _routeResult,
                shareStatus: _shareStatus,
                activeRoute: _activeRoute,
                setupChecklistChecking: setupChecklistChecking,
                showSetupChecklist: _showFirstRunSetupChecklist,
                setupChecklistSnapshot: _setupChecklistSnapshot,
                savedLocations: _savedLocations,
                locationReady: _locationAccessStatus.isReady,
                backgroundReadinessWarning:
                    !_bridgeStatus
                        .notificationPermissionState
                        .allowsWatchNotification ||
                    _batteryOptimizationState !=
                        BatteryOptimizationState.disabled,
                isComputingRoute: _isComputingRoute,
                providerRepository: widget.providerRepository,
                enableEmbeddedGoogleMap: widget.enableEmbeddedGoogleMap,
                defaultTravelMode: _travelModeForWatch(
                  _displaySettings.travelMode,
                ),
                onNavigateNow: _navigateNowRoute,
                onRerouteActiveRoute: _rerouteActiveRoute,
                onClearActiveRoute: _clearActiveRoute,
                onOpenSetup: () {
                  unawaited(_openGoogleSetup());
                },
                onOpenPermissions: () {
                  unawaited(_openPermissions());
                },
                onDismissShareStatus: _dismissShareStatus,
                onOpenChecklistGoogleSetup: () {
                  unawaited(_openGoogleSetup());
                },
                onOpenChecklistPermissions: (focus) {
                  unawaited(_openPermissions(focus: focus));
                },
                onFinishSetupChecklist: _closeFirstRunSetupChecklist,
              ),
            ),
            TickerMode(
              enabled: _selectedTab == CompanionTab.savedLocations,
              child: SavedLocationsScreen(
                key: const PageStorageKey('saved-tab'),
                providerRepository: widget.providerRepository,
                providerStatus: _providerStatus,
                location: _location,
                destinations: _savedLocations,
                defaultTravelMode: _displaySettings.travelMode,
                isLoading: _isLoadingSavedLocations,
                isSaving: _isSavingSavedLocation,
                detail: _savedLocationsDetail,
                onSave: _saveSavedLocation,
                onClear: _clearSavedLocation,
                onOpenSetup: _openGoogleSetup,
              ),
            ),
            TickerMode(
              enabled: _selectedTab == CompanionTab.settings,
              child: SettingsHubScreen(
                key: const PageStorageKey('settings-tab'),
                providerStatus: _providerStatus,
                setupChecklistSummary: _setupChecklistSummary,
                setupChecklistNeedsAttention:
                    _readinessLoaded && _setupChecklistSnapshot.needsAttention,
                permissionsSummary: _permissionsNeedAttention
                    ? 'Needs attention'
                    : 'Ready',
                watchSummary: _bridgeStatus.watchDetailLabel,
                readinessLoaded: _readinessLoaded,
                providerNeedsAttention: _providerNeedsAttention,
                permissionsNeedAttention: _permissionsNeedAttention,
                onOpenSetupChecklist: _openSetupChecklist,
                onOpenGoogleSetup: () {
                  unawaited(_openGoogleSetup());
                },
                onOpenPermissions: () {
                  unawaited(_openPermissions());
                },
                onOpenWatchConnection: _openWatchConnection,
                onOpenNavigationPreferences: _openNavigationPreferences,
                onOpenAppearancePreferences: _openAppearancePreferences,
                onOpenWatchMapPreferences: _openWatchMapPreferences,
                onOpenDiagnostics: _openDiagnostics,
                onOpenAbout: _openAbout,
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tabs.indexOf(_selectedTab),
        onDestinationSelected: (index) {
          setState(() {
            _selectedTab = tabs[index];
          });
        },
        destinations: [
          for (final tab in tabs)
            switch (tab) {
              CompanionTab.navigate => const NavigationDestination(
                icon: Icon(Icons.navigation_outlined),
                selectedIcon: Icon(Icons.navigation),
                label: 'Navigate',
              ),
              CompanionTab.savedLocations => const NavigationDestination(
                icon: Icon(Icons.bookmark_border),
                selectedIcon: Icon(Icons.bookmark),
                label: 'Saved',
              ),
              CompanionTab.settings => NavigationDestination(
                icon: Semantics(
                  label: settingsNeedsAttention
                      ? 'Settings, setup needs attention'
                      : 'Settings',
                  child: Badge(
                    isLabelVisible: settingsNeedsAttention,
                    smallSize: 9,
                    backgroundColor: const Color(0xFFE0A000),
                    child: const Icon(Icons.tune_outlined),
                  ),
                ),
                selectedIcon: Semantics(
                  label: settingsNeedsAttention
                      ? 'Settings, setup needs attention'
                      : 'Settings',
                  child: Badge(
                    isLabelVisible: settingsNeedsAttention,
                    smallSize: 9,
                    backgroundColor: const Color(0xFFE0A000),
                    child: const Icon(Icons.tune),
                  ),
                ),
                label: 'Settings',
              ),
            },
        ],
      ),
    );
  }
}

class _ManualSetupChecklistPage extends StatefulWidget {
  const _ManualSetupChecklistPage({
    required this.initialSnapshot,
    required this.onRefresh,
    required this.onOpenGoogleSetup,
    required this.onOpenPermissions,
  });

  final SetupChecklistSnapshot initialSnapshot;
  final Future<SetupChecklistSnapshot> Function() onRefresh;
  final Future<void> Function() onOpenGoogleSetup;
  final Future<void> Function(PermissionsFocus focus) onOpenPermissions;

  @override
  State<_ManualSetupChecklistPage> createState() =>
      _ManualSetupChecklistPageState();
}

class _ManualSetupChecklistPageState extends State<_ManualSetupChecklistPage>
    with WidgetsBindingObserver {
  late SetupChecklistSnapshot _snapshot;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _snapshot = widget.initialSnapshot;
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final snapshot = await widget.onRefresh();
      if (!mounted) return;
      setState(() => _snapshot = snapshot);
    } catch (_) {
      if (mounted) _showChecklistFailure();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await action();
      final snapshot = await widget.onRefresh();
      if (!mounted) return;
      setState(() => _snapshot = snapshot);
    } catch (_) {
      if (mounted) _showChecklistFailure();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _showChecklistFailure() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Setup status could not be refreshed.')),
    );
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      FirstRunSetupChecklist(
        snapshot: _snapshot,
        manual: true,
        onOpenGoogleSetup: () {
          unawaited(_run(widget.onOpenGoogleSetup));
        },
        onOpenPermissions: (focus) {
          unawaited(_run(() => widget.onOpenPermissions(focus)));
        },
        onContinue: () => Navigator.pop(context),
        onDismiss: () => Navigator.pop(context),
      ),
      if (_refreshing)
        const Positioned(
          top: 12,
          right: 16,
          child: SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
    ],
  );
}

class NavigateScreen extends StatelessWidget {
  const NavigateScreen({
    required this.providerStatus,
    required this.location,
    required this.routeResult,
    required this.shareStatus,
    required this.activeRoute,
    required this.setupChecklistChecking,
    required this.showSetupChecklist,
    required this.setupChecklistSnapshot,
    required this.savedLocations,
    required this.locationReady,
    required this.backgroundReadinessWarning,
    required this.isComputingRoute,
    required this.providerRepository,
    required this.enableEmbeddedGoogleMap,
    required this.defaultTravelMode,
    required this.onNavigateNow,
    required this.onRerouteActiveRoute,
    required this.onClearActiveRoute,
    required this.onOpenSetup,
    required this.onOpenPermissions,
    required this.onDismissShareStatus,
    required this.onOpenChecklistGoogleSetup,
    required this.onOpenChecklistPermissions,
    required this.onFinishSetupChecklist,
    super.key,
  });

  final ProviderStatus providerStatus;
  final LocationSnapshot? location;
  final RouteResult? routeResult;
  final ShareRoutingStatus? shareStatus;
  final WatchActiveRoute? activeRoute;
  final bool setupChecklistChecking;
  final bool showSetupChecklist;
  final SetupChecklistSnapshot setupChecklistSnapshot;
  final List<WatchDestinationConfig> savedLocations;
  final bool locationReady;
  final bool backgroundReadinessWarning;
  final bool isComputingRoute;
  final ProviderRepository providerRepository;
  final bool enableEmbeddedGoogleMap;
  final TravelMode defaultTravelMode;
  final Future<String> Function({
    required WatchRouteOriginPolicy originPolicy,
    WatchRouteEndpoint? origin,
    required WatchRouteEndpoint destination,
    required TravelMode travelMode,
  })
  onNavigateNow;
  final Future<String> Function() onRerouteActiveRoute;
  final Future<String> Function() onClearActiveRoute;
  final VoidCallback onOpenSetup;
  final VoidCallback onOpenPermissions;
  final VoidCallback onDismissShareStatus;
  final VoidCallback onOpenChecklistGoogleSetup;
  final ValueChanged<PermissionsFocus> onOpenChecklistPermissions;
  final VoidCallback onFinishSetupChecklist;

  @override
  Widget build(BuildContext context) {
    final providerReady = _providerReady(providerStatus);
    final share = activeRoute == null ? shareStatus : null;
    final shareFailed =
        share != null && share.isTerminal && !share.isActiveRoute;
    final showShareProgress =
        share != null && !shareFailed && !share.isActiveRoute;
    final showShareFailure = share != null && shareFailed;
    if (activeRoute == null && share == null && setupChecklistChecking) {
      return const Center(child: _CompactCheckingSetup());
    }
    if (activeRoute == null && share == null && showSetupChecklist) {
      return FirstRunSetupChecklist(
        snapshot: setupChecklistSnapshot,
        onOpenGoogleSetup: onOpenChecklistGoogleSetup,
        onOpenPermissions: onOpenChecklistPermissions,
        onContinue: onFinishSetupChecklist,
        onDismiss: onFinishSetupChecklist,
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (showShareProgress) ...[
          _CompactNotice(
            icon: Icons.ios_share_outlined,
            title: share.title,
            detail: share.subtitle,
            busy: true,
          ),
          const SizedBox(height: 12),
        ],
        if (showShareFailure) ...[
          _CompactNotice(
            icon: share.state == 'queuedUnconfirmed'
                ? Icons.watch_later_outlined
                : Icons.error_outline,
            title: share.title,
            detail: share.subtitle,
            onDismiss: onDismissShareStatus,
          ),
          const SizedBox(height: 12),
        ],
        if (activeRoute != null)
          _ActiveRouteSummaryCard(
            activeRoute: activeRoute!,
            routeResult: routeResult,
            busy: isComputingRoute,
            canReroute:
                providerReady &&
                (activeRoute!.originPolicy ==
                        WatchRouteOriginPolicy.explicitPlace ||
                    locationReady),
            onReroute: onRerouteActiveRoute,
            onEndNavigation: onClearActiveRoute,
          )
        else if (!providerReady)
          _RequiredSetupCard(onOpenSetup: onOpenSetup)
        else ...[
          if (!locationReady) ...[
            _CompactNotice(
              icon: Icons.location_off_outlined,
              title: 'Location setup required',
              detail:
                  'Turn on location and allow Mappy to use it in the background before starting navigation.',
              actionLabel: 'Permissions',
              onAction: onOpenPermissions,
            ),
            const SizedBox(height: 12),
          ] else if (backgroundReadinessWarning) ...[
            _CompactNotice(
              icon: Icons.warning_amber_outlined,
              title: 'Background reliability needs attention',
              detail:
                  'Notifications or unrestricted battery usage still need setup.',
              actionLabel: 'Permissions',
              onAction: onOpenPermissions,
            ),
            const SizedBox(height: 12),
          ],
          RouteProbePanel(
            location: location,
            providerRepository: providerRepository,
            providerStatus: providerStatus,
            routeResult: routeResult,
            isComputingRoute: isComputingRoute,
            enableEmbeddedGoogleMap: enableEmbeddedGoogleMap,
            defaultTravelMode: defaultTravelMode,
            canStartNavigation: locationReady,
            savedLocations: savedLocations,
            onNavigateNow: onNavigateNow,
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class _CompactCheckingSetup extends StatelessWidget {
  const _CompactCheckingSetup();

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Checking setup',
    liveRegion: true,
    child: const Padding(
      padding: EdgeInsets.all(24),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          SizedBox(width: 12),
          Expanded(child: Text('Checking setup…')),
        ],
      ),
    ),
  );
}

class _RequiredSetupCard extends StatelessWidget {
  const _RequiredSetupCard({required this.onOpenSetup});

  final VoidCallback onOpenSetup;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.key_off_outlined,
            size: 32,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            'Set up Google Maps to navigate',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Mappy needs your validated Google API key, Android package, and signing SHA-1 before place search or routing can be used.',
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('open-google-setup'),
            onPressed: onOpenSetup,
            icon: const Icon(Icons.key_outlined),
            label: const Text('Set up Google Maps'),
          ),
        ],
      ),
    ),
  );
}

class _CompactNotice extends StatelessWidget {
  const _CompactNotice({
    required this.icon,
    required this.title,
    required this.detail,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
    this.busy = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;
  final bool busy;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: ListTile(
      leading: busy
          ? const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          : Icon(icon),
      title: Text(title),
      subtitle: Text(detail),
      trailing: onDismiss != null
          ? IconButton(
              tooltip: 'Dismiss',
              onPressed: onDismiss,
              icon: const Icon(Icons.close),
            )
          : actionLabel == null
          ? null
          : TextButton(onPressed: onAction, child: Text(actionLabel!)),
    ),
  );
}

class _ActiveRouteSummaryCard extends StatefulWidget {
  const _ActiveRouteSummaryCard({
    required this.activeRoute,
    required this.routeResult,
    required this.busy,
    required this.canReroute,
    required this.onReroute,
    required this.onEndNavigation,
  });

  final WatchActiveRoute activeRoute;
  final RouteResult? routeResult;
  final bool busy;
  final bool canReroute;
  final Future<String> Function() onReroute;
  final Future<String> Function() onEndNavigation;

  @override
  State<_ActiveRouteSummaryCard> createState() =>
      _ActiveRouteSummaryCardState();
}

class _ActiveRouteSummaryCardState extends State<_ActiveRouteSummaryCard> {
  String? _message;

  Future<void> _run(Future<String> Function() action) async {
    final message = await action();
    if (mounted) setState(() => _message = message);
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.activeRoute;
    final result = widget.routeResult;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.navigation,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Active navigation',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              route.destination.label,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              route.destination.address,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (result?.ok == true) ...[
              const SizedBox(height: 10),
              Text(result!.summaryLabel),
            ],
            const SizedBox(height: 10),
            StatusPill(
              icon: Icons.alt_route_outlined,
              label: route.travelMode.label,
              tone: StatusTone.ok,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('reroute-active'),
                  onPressed: widget.busy || !widget.canReroute
                      ? null
                      : () => _run(widget.onReroute),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reroute'),
                ),
                FilledButton.tonalIcon(
                  key: const ValueKey('end-navigation'),
                  onPressed: widget.busy
                      ? null
                      : () => _run(widget.onEndNavigation),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('End navigation'),
                ),
              ],
            ),
            if (!widget.canReroute) ...[
              const SizedBox(height: 8),
              const Text('Fix setup or location access before rerouting.'),
            ],
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!),
            ],
          ],
        ),
      ),
    );
  }
}

String _navigationSentMessage(String destinationLabel) =>
    'Navigation to $destinationLabel sent to watch';

class RouteProbePanel extends StatefulWidget {
  const RouteProbePanel({
    required this.location,
    required this.providerRepository,
    required this.providerStatus,
    required this.routeResult,
    required this.isComputingRoute,
    required this.enableEmbeddedGoogleMap,
    required this.defaultTravelMode,
    required this.canStartNavigation,
    required this.savedLocations,
    required this.onNavigateNow,
    super.key,
  });

  final LocationSnapshot? location;
  final ProviderRepository providerRepository;
  final ProviderStatus providerStatus;
  final RouteResult? routeResult;
  final bool isComputingRoute;
  final bool enableEmbeddedGoogleMap;
  final TravelMode defaultTravelMode;
  final bool canStartNavigation;
  final List<WatchDestinationConfig> savedLocations;
  final Future<String> Function({
    required WatchRouteOriginPolicy originPolicy,
    WatchRouteEndpoint? origin,
    required WatchRouteEndpoint destination,
    required TravelMode travelMode,
  })
  onNavigateNow;

  @override
  State<RouteProbePanel> createState() => _RouteProbePanelState();
}

class _RouteProbePanelState extends State<RouteProbePanel> {
  final math.Random _random = math.Random();
  late final _NavigatePlaceDraft _origin;
  late final _NavigatePlaceDraft _destination;
  WatchRouteOriginPolicy _originPolicy = WatchRouteOriginPolicy.currentLocation;
  late TravelMode _travelMode;
  String? _localMessage;
  String? _sentDestinationLabel;
  gmaps.GoogleMapController? _destinationMapController;
  gmaps.LatLng _destinationMapCenter = _fallbackMapTarget;
  bool _resolving = false;
  bool _updatingText = false;

  @override
  void initState() {
    super.initState();
    _origin = _NavigatePlaceDraft(
      keyPrefix: 'status-navigate-origin',
      role: PlaceSearchRole.origin,
      emptyMessage: 'Origin is empty.',
      random: _random,
    );
    _destination = _NavigatePlaceDraft(
      keyPrefix: 'status-navigate-destination',
      role: PlaceSearchRole.destination,
      emptyMessage: 'Destination is empty.',
      random: _random,
    );
    _origin.controller.addListener(() => _onTextChanged(_origin));
    _destination.controller.addListener(() => _onTextChanged(_destination));
    _travelMode = widget.defaultTravelMode;
  }

  @override
  void didUpdateWidget(covariant RouteProbePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_travelMode == oldWidget.defaultTravelMode &&
        widget.defaultTravelMode != oldWidget.defaultTravelMode) {
      _travelMode = widget.defaultTravelMode;
    }
    if (_shouldAutoCenterMapOnLocation(oldWidget.location, widget.location)) {
      unawaited(_moveDestinationMapToLocation(widget.location!));
    }
  }

  @override
  void dispose() {
    _destinationMapController?.dispose();
    _origin.dispose();
    _destination.dispose();
    super.dispose();
  }

  void _onTextChanged(_NavigatePlaceDraft draft) {
    if (_updatingText) {
      return;
    }
    draft.selectedSuggestion = null;
    draft.resolvedEndpoint = null;
    draft.resolvingSelection = false;
    draft.debounce?.cancel();
    final input = draft.controller.text.trim();
    if (input.length < 3) {
      setState(() {
        draft.suggestions = const [];
        draft.searching = false;
        draft.resolvingSelection = false;
        draft.attribution = null;
        draft.detail = null;
        _localMessage = null;
        _sentDestinationLabel = null;
      });
      return;
    }
    setState(() {
      draft.searching = true;
      draft.detail = null;
      _localMessage = null;
      _sentDestinationLabel = null;
    });
    draft.debounce = Timer(
      const Duration(milliseconds: 350),
      () => _searchPlaces(draft, input),
    );
  }

  Future<void> _searchPlaces(_NavigatePlaceDraft draft, String input) async {
    final biasLocation = widget.location;
    PlaceAutocompleteResult result;
    try {
      result = await widget.providerRepository.searchPlaces(
        input: input,
        role: draft.role,
        originLatitude: biasLocation?.latitude,
        originLongitude: biasLocation?.longitude,
        sessionToken: draft.sessionToken,
      );
    } catch (error) {
      result = PlaceAutocompleteResult(
        ok: false,
        status: widget.providerStatus,
        detail: error.toString(),
      );
    }

    if (!mounted || draft.controller.text.trim() != input) {
      return;
    }
    setState(() {
      draft.searching = false;
      draft.suggestions = result.ok ? result.suggestions : const [];
      draft.attribution = result.ok && result.suggestions.isNotEmpty
          ? 'Powered by Google'
          : null;
      draft.detail = result.ok ? null : result.detail ?? 'Search failed.';
    });
  }

  void _selectSuggestion(
    _NavigatePlaceDraft draft,
    PlaceAutocompleteSuggestion suggestion,
  ) {
    _updatingText = true;
    draft.controller.text = suggestion.displayText;
    draft.controller.selection = TextSelection.collapsed(
      offset: draft.controller.text.length,
    );
    _updatingText = false;
    setState(() {
      draft.selectedSuggestion = suggestion;
      draft.resolvedEndpoint = null;
      draft.resolvingSelection = true;
      draft.suggestions = const [];
      draft.attribution = null;
      draft.detail = 'Loading preview...';
      _localMessage = null;
      _sentDestinationLabel = null;
    });
    unawaited(_resolveSelectedSuggestionForPreview(draft, suggestion));
  }

  Future<void> _resolveSelectedSuggestionForPreview(
    _NavigatePlaceDraft draft,
    PlaceAutocompleteSuggestion suggestion,
  ) async {
    late final PlaceResolutionResult resolved;
    try {
      resolved = await widget.providerRepository.resolvePlace(
        placeId: suggestion.placeId,
        sessionToken: draft.sessionToken,
      );
    } catch (error) {
      resolved = PlaceResolutionResult(
        ok: false,
        status: widget.providerStatus,
        detail: error.toString(),
      );
    }

    if (!mounted ||
        draft.selectedSuggestion?.placeId != suggestion.placeId ||
        draft.controller.text.trim() != suggestion.displayText) {
      return;
    }

    final endpoint = _endpointFromPlaceResolution(
      resolved,
      selected: suggestion,
      input: suggestion.displayText,
      fallbackLabel: draft.role == PlaceSearchRole.destination
          ? 'Destination'
          : 'Origin',
    );
    setState(() {
      draft.resolvingSelection = false;
      if (endpoint == null) {
        draft.detail =
            resolved.detail ??
            '${draft.role == PlaceSearchRole.destination ? 'Destination' : 'Origin'} could not be resolved.';
      } else {
        draft.resolvedEndpoint = endpoint;
        draft.detail = _endpointDetailLabel(endpoint);
      }
    });
    if (endpoint != null && identical(draft, _destination)) {
      unawaited(_moveDestinationMapTo(endpoint));
    }
  }

  WatchRouteEndpoint? _endpointFromPlaceResolution(
    PlaceResolutionResult resolved, {
    required PlaceAutocompleteSuggestion? selected,
    required String input,
    required String fallbackLabel,
  }) {
    final latitude = resolved.latitude;
    final longitude = resolved.longitude;
    if (!resolved.ok || latitude == null || longitude == null) {
      return null;
    }

    final label = _firstNonBlankValue([
      resolved.label,
      selected?.primaryText,
      input,
      fallbackLabel,
    ]);
    final address = _firstNonBlankValue([
      resolved.formattedAddress,
      selected?.displayText,
      input,
      label,
    ]);
    return WatchRouteEndpoint(
      label: label,
      address: address,
      latitude: latitude,
      longitude: longitude,
      placeId: resolved.placeId ?? selected?.placeId,
    );
  }

  String _endpointDetailLabel(WatchRouteEndpoint endpoint) {
    final coordinates =
        '${endpoint.latitude.toStringAsFixed(5)}, ${endpoint.longitude.toStringAsFixed(5)}';
    return endpoint.address == coordinates
        ? coordinates
        : '${endpoint.address}\n$coordinates';
  }

  Future<WatchRouteEndpoint?> _resolveEndpoint(
    _NavigatePlaceDraft draft,
    String fallbackLabel,
  ) async {
    final input = draft.controller.text.trim();
    if (input.isEmpty) {
      setState(() {
        draft.detail = draft.emptyMessage;
      });
      return null;
    }

    final resolvedEndpoint = draft.resolvedEndpoint;
    if (resolvedEndpoint != null) {
      return resolvedEndpoint;
    }

    final selected = draft.selectedSuggestion;
    late final PlaceResolutionResult resolved;
    try {
      if (selected != null) {
        resolved = await widget.providerRepository.resolvePlace(
          placeId: selected.placeId,
          sessionToken: draft.sessionToken,
        );
      } else {
        final geocode = await widget.providerRepository.geocodeDestination(
          addressText: input,
        );
        resolved = PlaceResolutionResult(
          ok: geocode.ok,
          status: geocode.status,
          latitude: geocode.latitude,
          longitude: geocode.longitude,
          formattedAddress: geocode.formattedAddress,
          placeId: geocode.placeId,
          provider: geocode.provider,
          detail: geocode.detail,
          errorCategory: geocode.errorCategory,
          attribution: 'Google Geocoding',
        );
      }
    } catch (error) {
      resolved = PlaceResolutionResult(
        ok: false,
        status: widget.providerStatus,
        detail: error.toString(),
      );
    }

    if (!mounted) {
      return null;
    }
    final endpoint = _endpointFromPlaceResolution(
      resolved,
      selected: selected,
      input: input,
      fallbackLabel: fallbackLabel,
    );
    if (endpoint == null) {
      setState(() {
        draft.detail =
            resolved.detail ?? '$fallbackLabel could not be resolved.';
      });
      return null;
    }

    setState(() {
      draft.suggestions = const [];
      draft.selectedSuggestion = null;
      draft.resolvedEndpoint = endpoint;
      draft.resolvingSelection = false;
      draft.sessionToken = _newSessionToken(_random);
      draft.attribution = null;
      draft.detail = _endpointDetailLabel(endpoint);
    });
    if (identical(draft, _destination)) {
      unawaited(_moveDestinationMapTo(endpoint));
    }
    return endpoint;
  }

  Future<void> _navigateNow() async {
    if (!widget.canStartNavigation) {
      setState(() {
        _localMessage = 'Finish location setup before starting navigation.';
      });
      return;
    }
    setState(() {
      _resolving = true;
      _localMessage = null;
      _sentDestinationLabel = null;
    });

    WatchRouteEndpoint? origin;
    if (_originPolicy == WatchRouteOriginPolicy.explicitPlace) {
      origin = await _resolveEndpoint(_origin, 'Origin');
      if (!mounted || origin == null) {
        setState(() {
          _resolving = false;
        });
        return;
      }
    }

    final destination = await _resolveEndpoint(_destination, 'Destination');
    if (!mounted || destination == null) {
      setState(() {
        _resolving = false;
      });
      return;
    }

    final message = await widget.onNavigateNow(
      originPolicy: _originPolicy,
      origin: origin,
      destination: destination,
      travelMode: _travelMode,
    );
    if (!mounted) {
      return;
    }
    final sentMessage = _navigationSentMessage(destination.label);
    setState(() {
      _resolving = false;
      _localMessage = message == sentMessage ? null : message;
      _sentDestinationLabel = message == sentMessage ? destination.label : null;
    });
  }

  void _onDestinationMapCreated(gmaps.GoogleMapController controller) {
    _destinationMapController = controller;
    unawaited(
      _moveDestinationMapCamera(
        _destinationMapInitialTarget(),
        zoom: _destination.resolvedEndpoint == null ? 14.25 : 15.5,
        animated: false,
      ),
    );
  }

  void _onDestinationMapCameraMove(gmaps.CameraPosition position) {
    _destinationMapCenter = position.target;
  }

  void _selectDestinationMapCenter() {
    _selectDestinationFromMap(_destinationMapCenter);
  }

  void _selectDestinationFromMap(gmaps.LatLng target) {
    final endpoint = WatchRouteEndpoint(
      label: 'Dropped Pin',
      address: _coordinateText(target.latitude, target.longitude),
      latitude: target.latitude,
      longitude: target.longitude,
    );
    _updatingText = true;
    _destination.controller.text = endpoint.address;
    _destination.controller.selection = TextSelection.collapsed(
      offset: _destination.controller.text.length,
    );
    _updatingText = false;
    setState(() {
      _destination.selectedSuggestion = null;
      _destination.resolvedEndpoint = endpoint;
      _destination.resolvingSelection = false;
      _destination.suggestions = const [];
      _destination.attribution = null;
      _destination.detail = _endpointDetailLabel(endpoint);
      _localMessage = null;
      _sentDestinationLabel = null;
    });
    unawaited(_moveDestinationMapTo(endpoint));
  }

  Future<void> _moveDestinationMapTo(
    WatchRouteEndpoint endpoint, {
    bool animated = true,
  }) async {
    await _moveDestinationMapCamera(
      gmaps.LatLng(endpoint.latitude, endpoint.longitude),
      zoom: 15.5,
      animated: animated,
    );
  }

  Future<void> _moveDestinationMapToLocation(
    LocationSnapshot location, {
    bool animated = true,
  }) async {
    await _moveDestinationMapCamera(
      gmaps.LatLng(location.latitude, location.longitude),
      zoom: 14.25,
      animated: animated,
    );
  }

  Future<void> _moveDestinationMapCamera(
    gmaps.LatLng target, {
    required double zoom,
    required bool animated,
  }) async {
    _destinationMapCenter = target;
    final controller = _destinationMapController;
    if (!widget.enableEmbeddedGoogleMap || controller == null) {
      return;
    }
    try {
      final update = gmaps.CameraUpdate.newLatLngZoom(target, zoom);
      if (animated) {
        await controller.animateCamera(update);
      } else {
        await controller.moveCamera(update);
      }
    } catch (_) {
      // The native map can reject camera updates during teardown.
    }
  }

  bool _shouldAutoCenterMapOnLocation(
    LocationSnapshot? previous,
    LocationSnapshot? next,
  ) {
    if (next == null ||
        _destination.resolvedEndpoint != null ||
        _routeHasDestination(widget.routeResult)) {
      return false;
    }
    return !_sameLocation(previous, next);
  }

  bool _routeHasDestination(RouteResult? routeResult) {
    return routeResult?.destinationLatitude != null &&
        routeResult?.destinationLongitude != null;
  }

  bool _sameLocation(LocationSnapshot? previous, LocationSnapshot next) {
    return previous != null &&
        previous.latitude == next.latitude &&
        previous.longitude == next.longitude;
  }

  gmaps.LatLng _destinationMapInitialTarget() {
    final endpoint = _destination.resolvedEndpoint;
    if (endpoint != null) {
      return gmaps.LatLng(endpoint.latitude, endpoint.longitude);
    }
    final route = widget.routeResult;
    final routeLatitude = route?.destinationLatitude;
    final routeLongitude = route?.destinationLongitude;
    if (routeLatitude != null && routeLongitude != null) {
      return gmaps.LatLng(routeLatitude, routeLongitude);
    }
    final location = widget.location;
    if (location != null) {
      return gmaps.LatLng(location.latitude, location.longitude);
    }
    return _fallbackMapTarget;
  }

  Future<void> _chooseOriginPolicy() async {
    final selected = await showModalBottomSheet<WatchRouteOriginPolicy>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.my_location),
              title: const Text('Current location'),
              trailing: _originPolicy == WatchRouteOriginPolicy.currentLocation
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.pop(
                context,
                WatchRouteOriginPolicy.currentLocation,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.place_outlined),
              title: const Text('Choose a place'),
              trailing: _originPolicy == WatchRouteOriginPolicy.explicitPlace
                  ? const Icon(Icons.check)
                  : null,
              onTap: () =>
                  Navigator.pop(context, WatchRouteOriginPolicy.explicitPlace),
            ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() {
        _originPolicy = selected;
        _localMessage = null;
      });
    }
  }

  Future<void> _chooseTravelMode() async {
    final selected = await showModalBottomSheet<TravelMode>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in TravelMode.values)
              ListTile(
                leading: Icon(switch (mode) {
                  TravelMode.drive => Icons.directions_car_outlined,
                  TravelMode.walk => Icons.directions_walk,
                  TravelMode.bike => Icons.directions_bike,
                }),
                title: Text(mode.label),
                trailing: mode == _travelMode ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, mode),
              ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) setState(() => _travelMode = selected);
  }

  Future<void> _chooseSavedDestination() async {
    final destinations = widget.savedLocations
        .where((destination) => destination.enabled)
        .toList(growable: false);
    if (destinations.isEmpty) {
      setState(() => _localMessage = 'No saved locations yet.');
      return;
    }
    final selected = await showModalBottomSheet<WatchDestinationConfig>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final destination in destinations)
              ListTile(
                leading: Icon(savedLocationSlotIcon(destination.slotIndex)),
                title: Text(destination.label),
                subtitle: Text(destination.address),
                onTap: () => Navigator.pop(context, destination),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final endpoint = WatchRouteEndpoint(
      label: selected.label,
      address: selected.address,
      latitude: selected.latitude,
      longitude: selected.longitude,
      placeId: selected.placeId,
    );
    _updatingText = true;
    _destination.controller.text = selected.address;
    _destination.controller.selection = TextSelection.collapsed(
      offset: _destination.controller.text.length,
    );
    _updatingText = false;
    setState(() {
      _destination.resolvedEndpoint = endpoint;
      _destination.selectedSuggestion = null;
      _destination.suggestions = const [];
      _destination.detail = null;
      _localMessage = null;
      _travelMode = _travelModeForSaved(selected.defaultTravelMode);
    });
    unawaited(_moveDestinationMapTo(endpoint));
  }

  TravelMode _travelModeForSaved(WatchTravelMode mode) => switch (mode) {
    WatchTravelMode.drive => TravelMode.drive,
    WatchTravelMode.walk => TravelMode.walk,
    WatchTravelMode.bike => TravelMode.bike,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _resolving || widget.isComputingRoute;
    final providerReady = _providerReady(widget.providerStatus);
    final canNavigate = providerReady && widget.canStartNavigation && !busy;
    final warning = _travelMode == TravelMode.drive
        ? widget.routeResult?.routeWarning
        : 'Walk and bike routes may miss safe pedestrian or bicycling path detail.';
    final mapTarget = _destinationMapInitialTarget();
    if (_destinationMapController == null) {
      _destinationMapCenter = mapTarget;
    }
    final originButton = OutlinedButton.icon(
      onPressed: busy ? null : _chooseOriginPolicy,
      icon: Icon(
        _originPolicy == WatchRouteOriginPolicy.currentLocation
            ? Icons.my_location
            : Icons.place_outlined,
      ),
      label: Text(
        _originPolicy == WatchRouteOriginPolicy.currentLocation
            ? 'From current'
            : 'From place',
      ),
    );
    final travelModeButton = OutlinedButton.icon(
      onPressed: busy ? null : _chooseTravelMode,
      icon: const Icon(Icons.alt_route_outlined),
      label: Text(_travelMode.label),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('New route', style: theme.textTheme.titleMedium),
                ),
                if (busy)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _placeField(
              context,
              _destination,
              labelText: 'Destination',
              showSavedButton: true,
            ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) {
                final useColumn =
                    constraints.maxWidth < 360 ||
                    MediaQuery.textScalerOf(context).scale(14) > 18;
                if (useColumn) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      originButton,
                      const SizedBox(height: 8),
                      travelModeButton,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: originButton),
                    const SizedBox(width: 8),
                    Expanded(child: travelModeButton),
                  ],
                );
              },
            ),
            if (_originPolicy == WatchRouteOriginPolicy.explicitPlace) ...[
              const SizedBox(height: 10),
              _placeField(context, _origin, labelText: 'Origin'),
            ],
            if (_destination.resolvedEndpoint != null) ...[
              const SizedBox(height: 10),
              _DestinationMapPanel(
                key: const ValueKey('status-navigate-destination-map'),
                enableGoogleMap: widget.enableEmbeddedGoogleMap,
                initialTarget: mapTarget,
                destination: _destination.resolvedEndpoint,
                location: widget.location,
                routeResult: widget.routeResult,
                onMapCreated: _onDestinationMapCreated,
                onCameraMove: _onDestinationMapCameraMove,
                onTap: _selectDestinationFromMap,
                onUseCenter: _selectDestinationMapCenter,
              ),
            ],
            if (warning != null) ...[
              const SizedBox(height: 10),
              Text(warning, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const ValueKey('status-navigate-now'),
                onPressed: canNavigate ? _navigateNow : null,
                icon: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.navigation_outlined),
                label: Text(busy ? 'Starting navigation' : 'Start navigation'),
              ),
            ),
            if (_localMessage != null) ...[
              const SizedBox(height: 10),
              Text(_localMessage!, style: theme.textTheme.bodySmall),
            ],
            if (_sentDestinationLabel != null) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.watch_outlined,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _navigationSentMessage(_sentDestinationLabel!),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _placeField(
    BuildContext context,
    _NavigatePlaceDraft draft, {
    required String labelText,
    bool showSavedButton = false,
  }) {
    final theme = Theme.of(context);
    final busy = _resolving || widget.isComputingRoute;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: ValueKey('${draft.keyPrefix}-search'),
          controller: draft.controller,
          enabled: !busy,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: labelText,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: draft.searching || draft.resolvingSelection
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : showSavedButton
                ? IconButton(
                    tooltip: 'Choose saved location',
                    onPressed: busy ? null : _chooseSavedDestination,
                    icon: const Icon(Icons.bookmarks_outlined),
                  )
                : null,
          ),
          textInputAction: draft.role == PlaceSearchRole.destination
              ? TextInputAction.go
              : TextInputAction.next,
          onSubmitted: draft.role == PlaceSearchRole.destination
              ? (_) {
                  if (widget.canStartNavigation && !busy) _navigateNow();
                }
              : null,
        ),
        if (draft.suggestions.isNotEmpty) ...[
          const SizedBox(height: 8),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Material(
              color: Colors.transparent,
              child: Column(
                children: [
                  for (final suggestion in draft.suggestions.take(4))
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.place_outlined),
                      title: Text(suggestion.primaryText),
                      subtitle: suggestion.secondaryText.isEmpty
                          ? null
                          : Text(suggestion.secondaryText),
                      onTap: busy
                          ? null
                          : () => _selectSuggestion(draft, suggestion),
                    ),
                  if (draft.attribution != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          draft.attribution!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        if (draft.detail != null) ...[
          const SizedBox(height: 6),
          Text(
            draft.detail!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

String _coordinateText(double latitude, double longitude) =>
    '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';

class _DestinationMapPanel extends StatelessWidget {
  const _DestinationMapPanel({
    required this.enableGoogleMap,
    required this.initialTarget,
    required this.destination,
    required this.location,
    required this.routeResult,
    required this.onMapCreated,
    required this.onCameraMove,
    required this.onTap,
    required this.onUseCenter,
    super.key,
  });

  final bool enableGoogleMap;
  final gmaps.LatLng initialTarget;
  final WatchRouteEndpoint? destination;
  final LocationSnapshot? location;
  final RouteResult? routeResult;
  final ValueChanged<gmaps.GoogleMapController> onMapCreated;
  final ValueChanged<gmaps.CameraPosition> onCameraMove;
  final ValueChanged<gmaps.LatLng> onTap;
  final VoidCallback onUseCenter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final routePoints = routeResult?.fullRoutePoints ?? const <RoutePoint>[];
    final mapChild = enableGoogleMap
        ? gmaps.GoogleMap(
            initialCameraPosition: gmaps.CameraPosition(
              target: initialTarget,
              zoom: destination == null ? 13 : 15.5,
            ),
            markers: _markers(),
            polylines: _polylines(theme, routePoints),
            myLocationButtonEnabled: false,
            myLocationEnabled: false,
            mapToolbarEnabled: false,
            zoomControlsEnabled: false,
            compassEnabled: false,
            onMapCreated: onMapCreated,
            onCameraMove: onCameraMove,
            onTap: onTap,
            onLongPress: onTap,
            gestureRecognizers: {
              Factory<OneSequenceGestureRecognizer>(
                () => EagerGestureRecognizer(),
              ),
            },
          )
        : _StaticDestinationMapPreview(
            destination: destination,
            location: location,
            routePoints: routePoints,
            onTap: () => onTap(initialTarget),
          );

    return Semantics(
      label: 'Destination map preview',
      button: false,
      child: SizedBox(
        height: 320,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Stack(
              children: [
                Positioned.fill(child: mapChild),
                if (destination != null)
                  Positioned(
                    left: 10,
                    top: 10,
                    right: 10,
                    child: _DestinationMapBadge(destination: destination!),
                  ),
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('status-map-use-center'),
                    onPressed: onUseCenter,
                    icon: const Icon(Icons.add_location_alt_outlined),
                    label: const Text('Use Center'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Set<gmaps.Marker> _markers() {
    final markers = <gmaps.Marker>{};
    final currentLocation = location;
    if (currentLocation?.isFresh == true) {
      markers.add(
        gmaps.Marker(
          markerId: const gmaps.MarkerId('current-location'),
          position: gmaps.LatLng(
            currentLocation!.latitude,
            currentLocation.longitude,
          ),
          icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
            gmaps.BitmapDescriptor.hueAzure,
          ),
          infoWindow: const gmaps.InfoWindow(title: 'Current location'),
        ),
      );
    }
    final selectedDestination = destination;
    if (selectedDestination != null) {
      markers.add(
        gmaps.Marker(
          markerId: const gmaps.MarkerId('destination'),
          position: gmaps.LatLng(
            selectedDestination.latitude,
            selectedDestination.longitude,
          ),
          infoWindow: gmaps.InfoWindow(title: selectedDestination.label),
        ),
      );
    }
    return markers;
  }

  Set<gmaps.Polyline> _polylines(
    ThemeData theme,
    List<RoutePoint> routePoints,
  ) {
    if (routePoints.length < 2) {
      return const <gmaps.Polyline>{};
    }
    return {
      gmaps.Polyline(
        polylineId: const gmaps.PolylineId('active-route'),
        color: theme.colorScheme.primary,
        width: 5,
        points: [
          for (final point in routePoints)
            gmaps.LatLng(point.latitude, point.longitude),
        ],
      ),
    };
  }
}

class _DestinationMapBadge extends StatelessWidget {
  const _DestinationMapBadge({required this.destination});

  final WatchRouteEndpoint destination;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.place, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                destination.label,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _coordinateText(destination.latitude, destination.longitude),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StaticDestinationMapPreview extends StatelessWidget {
  const _StaticDestinationMapPreview({
    required this.destination,
    required this.location,
    required this.routePoints,
    required this.onTap,
  });

  final WatchRouteEndpoint? destination;
  final LocationSnapshot? location;
  final List<RoutePoint> routePoints;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              painter: _StaticMapPainter(
                colorScheme: theme.colorScheme,
                hasRoute: routePoints.length > 1,
              ),
            ),
            if (location?.isFresh == true)
              Align(
                alignment: destination == null
                    ? Alignment.center
                    : const Alignment(-0.52, 0.44),
                child: _MapPinIcon(
                  icon: Icons.my_location,
                  color: theme.colorScheme.tertiary,
                ),
              ),
            Align(
              alignment: destination == null
                  ? Alignment.center
                  : const Alignment(0.34, -0.24),
              child: _MapPinIcon(
                icon: destination == null
                    ? Icons.add_location_alt_outlined
                    : Icons.place,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MapPinIcon extends StatelessWidget {
  const _MapPinIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.94),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withValues(alpha: 0.18),
            blurRadius: 10,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, color: color, size: 22),
      ),
    );
  }
}

class _StaticMapPainter extends CustomPainter {
  const _StaticMapPainter({required this.colorScheme, required this.hasRoute});

  final ColorScheme colorScheme;
  final bool hasRoute;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = colorScheme.surfaceContainerHighest;
    canvas.drawRect(Offset.zero & size, background);

    final minorRoad = Paint()
      ..color = colorScheme.surface.withValues(alpha: 0.68)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    final majorRoad = Paint()
      ..color = colorScheme.surface.withValues(alpha: 0.92)
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    for (var x = -size.width * 0.2; x < size.width * 1.2; x += 48) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.width * 0.38, size.height),
        minorRoad,
      );
    }
    for (var y = 28.0; y < size.height; y += 52) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y + 18), minorRoad);
    }

    final mainPath = Path()
      ..moveTo(-10, size.height * 0.72)
      ..cubicTo(
        size.width * 0.22,
        size.height * 0.48,
        size.width * 0.48,
        size.height * 0.74,
        size.width * 0.7,
        size.height * 0.42,
      )
      ..cubicTo(
        size.width * 0.82,
        size.height * 0.25,
        size.width * 0.95,
        size.height * 0.28,
        size.width + 10,
        size.height * 0.16,
      );
    canvas.drawPath(mainPath, majorRoad);

    if (hasRoute) {
      final routePaint = Paint()
        ..color = colorScheme.primary
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      final route = Path()
        ..moveTo(size.width * 0.26, size.height * 0.72)
        ..lineTo(size.width * 0.42, size.height * 0.57)
        ..lineTo(size.width * 0.56, size.height * 0.48)
        ..lineTo(size.width * 0.66, size.height * 0.34);
      canvas.drawPath(route, routePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _StaticMapPainter oldDelegate) {
    return oldDelegate.colorScheme != colorScheme ||
        oldDelegate.hasRoute != hasRoute;
  }
}

class _NavigatePlaceDraft {
  _NavigatePlaceDraft({
    required this.keyPrefix,
    required this.role,
    required this.emptyMessage,
    required math.Random random,
  }) : sessionToken = _newSessionToken(random);

  final String keyPrefix;
  final PlaceSearchRole role;
  final String emptyMessage;
  final TextEditingController controller = TextEditingController();
  Timer? debounce;
  List<PlaceAutocompleteSuggestion> suggestions = const [];
  PlaceAutocompleteSuggestion? selectedSuggestion;
  WatchRouteEndpoint? resolvedEndpoint;
  String sessionToken;
  String? attribution;
  String? detail;
  bool searching = false;
  bool resolvingSelection = false;

  void dispose() {
    debounce?.cancel();
    controller.dispose();
  }
}

String _firstNonBlankValue(List<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return 'Place';
}

String _newSessionToken(math.Random random) =>
    '${DateTime.now().microsecondsSinceEpoch}-${random.nextInt(0x7fffffff)}';

bool _providerReady(ProviderStatus status) =>
    status.configured &&
    status.validationState == ProviderValidationState.valid;

String savedLocationSlotTitle(int slotIndex) {
  return switch (slotIndex) {
    0 => 'Home',
    1 => 'Work',
    _ => 'Location ${slotIndex + 1}',
  };
}

int savedLocationKind(int slotIndex) {
  return switch (slotIndex) {
    0 => 0,
    1 => 1,
    _ => 2,
  };
}

IconData savedLocationSlotIcon(int slotIndex) {
  return switch (slotIndex) {
    0 => Icons.home_outlined,
    1 => Icons.work_outline,
    _ => Icons.bookmark_border,
  };
}

String _watchDestinationLabel(String value, int slotIndex) {
  final fallback = savedLocationSlotTitle(slotIndex);
  final raw = value.trim().isEmpty ? fallback : value.trim();
  return utf8.decode(truncateUtf8Bytes(raw, maxDestinationLabelBytes));
}

class _WatchDestinationLabelFormatter extends TextInputFormatter {
  const _WatchDestinationLabelFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final capped = utf8.decode(
      truncateUtf8Bytes(newValue.text, maxDestinationLabelBytes),
    );
    if (capped == newValue.text) {
      return newValue;
    }
    return TextEditingValue(
      text: capped,
      selection: TextSelection.collapsed(offset: capped.length),
    );
  }
}

class _SavedLocationUpdateResult {
  const _SavedLocationUpdateResult({
    required this.success,
    required this.message,
  });

  const _SavedLocationUpdateResult.success(String message)
    : this(success: true, message: message);

  const _SavedLocationUpdateResult.failure(String message)
    : this(success: false, message: message);

  final bool success;
  final String message;
}

class SavedLocationsScreen extends StatefulWidget {
  const SavedLocationsScreen({
    required this.providerRepository,
    required this.providerStatus,
    required this.location,
    required this.destinations,
    required this.defaultTravelMode,
    required this.isLoading,
    required this.isSaving,
    required this.onSave,
    required this.onClear,
    required this.onOpenSetup,
    this.detail,
    this.initialSlot,
    this.editorOnly = false,
    super.key,
  });

  final ProviderRepository providerRepository;
  final ProviderStatus providerStatus;
  final LocationSnapshot? location;
  final List<WatchDestinationConfig> destinations;
  final WatchTravelMode defaultTravelMode;
  final bool isLoading;
  final bool isSaving;
  final String? detail;
  final int? initialSlot;
  final bool editorOnly;
  final Future<String> Function(WatchDestinationConfig config) onSave;

  /// Returns an error message when the native update fails, otherwise null.
  final Future<String?> Function(int slotIndex) onClear;
  final Future<ProviderStatus> Function() onOpenSetup;

  @override
  State<SavedLocationsScreen> createState() => _SavedLocationsScreenState();
}

class _SavedLocationsScreenState extends State<SavedLocationsScreen> {
  final math.Random _random = math.Random();
  final TextEditingController _nameController = TextEditingController();
  late final _NavigatePlaceDraft _destination;
  late int _selectedSlot;
  late ProviderStatus _providerStatus;
  WatchTravelMode _travelMode = WatchTravelMode.drive;
  String? _localMessage;
  String? _loadedSignature;
  bool _resolving = false;
  bool _updatingText = false;

  @override
  void initState() {
    super.initState();
    _destination = _NavigatePlaceDraft(
      keyPrefix: 'saved-location-destination',
      role: PlaceSearchRole.destination,
      emptyMessage: 'Destination is empty.',
      random: _random,
    );
    _destination.controller.addListener(_onDestinationTextChanged);
    _providerStatus = widget.providerStatus;
    _selectedSlot = _initialSelectedSlot();
    _loadSelectedSlot();
  }

  @override
  void didUpdateWidget(covariant SavedLocationsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _providerStatus = widget.providerStatus;
    final existing = _destinationForSlot(_selectedSlot);
    final signature = _slotSignature(existing);
    final defaultChangedForEmptySlot =
        existing == null &&
        widget.defaultTravelMode != oldWidget.defaultTravelMode;
    if (!isSavedLocationId(_selectedSlot)) {
      _selectedSlot = _initialSelectedSlot();
    }
    if (!_resolving &&
        (signature != _loadedSignature || defaultChangedForEmptySlot)) {
      _loadSelectedSlot();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _destination.dispose();
    super.dispose();
  }

  Future<void> _openSetup() async {
    final status = await widget.onOpenSetup();
    if (!mounted) return;
    setState(() => _providerStatus = status);
  }

  List<WatchDestinationConfig> _enabledDestinations() {
    return widget.destinations
        .where(
          (destination) =>
              destination.enabled && isSavedLocationId(destination.slotIndex),
        )
        .toList()
      ..sort((a, b) => a.slotIndex.compareTo(b.slotIndex));
  }

  int _initialSelectedSlot() {
    final requested = widget.initialSlot;
    if (requested != null && isSavedLocationId(requested)) {
      return requested;
    }
    final existing = _enabledDestinations();
    if (existing.isNotEmpty) {
      return existing.first.slotIndex;
    }
    return _nextAvailableSlot() ?? 0;
  }

  int? _nextAvailableSlot() {
    final destinations = _enabledDestinations();
    if (destinations.length >= maxDestinationRecords) {
      return null;
    }
    final used = destinations
        .map((destination) => destination.slotIndex)
        .toSet();
    for (var slot = 0; slot <= maxSavedLocationId; slot++) {
      if (!used.contains(slot)) {
        return slot;
      }
    }
    return null;
  }

  WatchDestinationConfig? _destinationForSlot(int slotIndex) {
    for (final destination in widget.destinations) {
      if (destination.enabled && destination.slotIndex == slotIndex) {
        return destination;
      }
    }
    return null;
  }

  String _slotSignature(WatchDestinationConfig? destination) {
    if (destination == null) {
      return 'empty';
    }
    return [
      destination.slotIndex,
      destination.label,
      destination.address,
      destination.latitude,
      destination.longitude,
      destination.defaultTravelMode.protocolValue,
      destination.placeId ?? '',
      destination.updatedAtMillis ?? 0,
      destination.geocodeStatus,
    ].join('|');
  }

  void _loadSelectedSlot() {
    final existing = _destinationForSlot(_selectedSlot);
    _loadedSignature = _slotSignature(existing);
    _updatingText = true;
    _nameController.text =
        existing?.label ?? savedLocationSlotTitle(_selectedSlot);
    _destination.controller.text = existing?.address ?? '';
    _destination.controller.selection = TextSelection.collapsed(
      offset: _destination.controller.text.length,
    );
    _updatingText = false;
    _travelMode = existing?.defaultTravelMode ?? widget.defaultTravelMode;
    _destination
      ..debounce?.cancel()
      ..suggestions = const []
      ..selectedSuggestion = null
      ..sessionToken = _newSessionToken(_random)
      ..attribution = null
      ..detail = null;
    _localMessage = null;
  }

  Future<void> _openEditor(int slotIndex) async {
    final existing = _destinationForSlot(slotIndex);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (routeContext) => Scaffold(
          appBar: AppBar(
            title: Text(existing?.label ?? 'Add saved location'),
            actions: [
              if (existing != null)
                PopupMenuButton<String>(
                  tooltip: 'More actions',
                  onSelected: (value) async {
                    if (value != 'delete') return;
                    final confirmed = await showDialog<bool>(
                      context: routeContext,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('Delete saved location?'),
                        content: Text(
                          '${existing.label} will be removed from the phone and watch.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(dialogContext, true),
                            child: const Text('Delete'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true || !routeContext.mounted) return;
                    final error = await widget.onClear(slotIndex);
                    if (!routeContext.mounted) return;
                    if (error == null) {
                      Navigator.pop(routeContext);
                    } else {
                      ScaffoldMessenger.of(
                        routeContext,
                      ).showSnackBar(SnackBar(content: Text(error)));
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
            ],
          ),
          body: SavedLocationsScreen(
            providerRepository: widget.providerRepository,
            providerStatus: widget.providerStatus,
            location: widget.location,
            destinations: widget.destinations,
            defaultTravelMode: widget.defaultTravelMode,
            isLoading: false,
            isSaving: widget.isSaving,
            detail: widget.detail,
            initialSlot: slotIndex,
            editorOnly: true,
            onSave: widget.onSave,
            onClear: widget.onClear,
            onOpenSetup: widget.onOpenSetup,
          ),
        ),
      ),
    );
  }

  void _onDestinationTextChanged() {
    if (_updatingText) {
      return;
    }
    _destination.selectedSuggestion = null;
    _destination.debounce?.cancel();
    final input = _destination.controller.text.trim();
    if (input.length < 3) {
      setState(() {
        _destination.suggestions = const [];
        _destination.searching = false;
        _destination.attribution = null;
        _destination.detail = null;
      });
      return;
    }
    setState(() {
      _destination.searching = true;
      _destination.detail = null;
    });
    _destination.debounce = Timer(
      const Duration(milliseconds: 350),
      () => _searchPlaces(input),
    );
  }

  Future<void> _searchPlaces(String input) async {
    final biasLocation = widget.location;
    PlaceAutocompleteResult result;
    try {
      result = await widget.providerRepository.searchPlaces(
        input: input,
        role: PlaceSearchRole.destination,
        originLatitude: biasLocation?.latitude,
        originLongitude: biasLocation?.longitude,
        sessionToken: _destination.sessionToken,
      );
    } catch (error) {
      result = PlaceAutocompleteResult(
        ok: false,
        status: widget.providerStatus,
        detail: error.toString(),
      );
    }

    if (!mounted || _destination.controller.text.trim() != input) {
      return;
    }
    setState(() {
      _destination.searching = false;
      _destination.suggestions = result.ok ? result.suggestions : const [];
      _destination.attribution = result.ok && result.suggestions.isNotEmpty
          ? 'Powered by Google'
          : null;
      _destination.detail = result.ok
          ? null
          : result.detail ?? 'Search failed.';
    });
  }

  void _selectSuggestion(PlaceAutocompleteSuggestion suggestion) {
    _updatingText = true;
    _destination.controller.text = suggestion.displayText;
    _destination.controller.selection = TextSelection.collapsed(
      offset: _destination.controller.text.length,
    );
    _updatingText = false;
    setState(() {
      _destination.selectedSuggestion = suggestion;
      _destination.suggestions = const [];
      _destination.attribution = null;
      _destination.detail = suggestion.secondaryText.isEmpty
          ? suggestion.displayText
          : suggestion.secondaryText;
    });
  }

  Future<WatchRouteEndpoint?> _resolveDestination() async {
    final input = _destination.controller.text.trim();
    if (input.isEmpty) {
      setState(() {
        _destination.detail = _destination.emptyMessage;
      });
      return null;
    }

    final selected = _destination.selectedSuggestion;
    late final PlaceResolutionResult resolved;
    try {
      if (selected != null) {
        resolved = await widget.providerRepository.resolvePlace(
          placeId: selected.placeId,
          sessionToken: _destination.sessionToken,
        );
      } else {
        final geocode = await widget.providerRepository.geocodeDestination(
          addressText: input,
        );
        resolved = PlaceResolutionResult(
          ok: geocode.ok,
          status: geocode.status,
          latitude: geocode.latitude,
          longitude: geocode.longitude,
          formattedAddress: geocode.formattedAddress,
          placeId: geocode.placeId,
          provider: geocode.provider,
          detail: geocode.detail,
          errorCategory: geocode.errorCategory,
          attribution: 'Google Geocoding',
        );
      }
    } catch (error) {
      resolved = PlaceResolutionResult(
        ok: false,
        status: widget.providerStatus,
        detail: error.toString(),
      );
    }

    if (!mounted) {
      return null;
    }
    final latitude = resolved.latitude;
    final longitude = resolved.longitude;
    if (!resolved.ok || latitude == null || longitude == null) {
      setState(() {
        _destination.detail =
            resolved.detail ?? 'Destination could not be resolved.';
      });
      return null;
    }

    final label = _firstNonBlankValue([
      resolved.label,
      selected?.primaryText,
      input,
      savedLocationSlotTitle(_selectedSlot),
    ]);
    final address = _firstNonBlankValue([
      resolved.formattedAddress,
      selected?.displayText,
      input,
      label,
    ]);
    setState(() {
      _destination.suggestions = const [];
      _destination.selectedSuggestion = null;
      _destination.sessionToken = _newSessionToken(_random);
      _destination.attribution = null;
      _destination.detail = null;
    });
    return WatchRouteEndpoint(
      label: label,
      address: address,
      latitude: latitude,
      longitude: longitude,
      placeId: resolved.placeId ?? selected?.placeId,
    );
  }

  Future<void> _saveSelectedSlot() async {
    setState(() {
      _resolving = true;
      _localMessage = null;
    });

    final resolved = await _resolveDestination();
    if (!mounted) {
      return;
    }
    if (resolved == null) {
      setState(() {
        _resolving = false;
      });
      return;
    }

    final config = WatchDestinationConfig(
      slotIndex: _selectedSlot,
      label: _watchDestinationLabel(_nameController.text, _selectedSlot),
      address: resolved.address,
      latitude: resolved.latitude,
      longitude: resolved.longitude,
      kind: savedLocationKind(_selectedSlot),
      defaultTravelMode: _travelMode,
      placeId: resolved.placeId,
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
      geocodeStatus: 'resolved',
    );
    final message = await widget.onSave(config);
    if (!mounted) {
      return;
    }
    setState(() {
      _resolving = false;
      _localMessage = message;
      _loadedSignature = _slotSignature(config);
      _nameController.text = config.label;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _resolving || widget.isSaving || widget.isLoading;
    final savedDestinations = _enabledDestinations();
    final currentDestination = _destinationForSlot(_selectedSlot);
    final canAdd = !busy && _nextAvailableSlot() != null;
    final canSave =
        _providerReady(_providerStatus) &&
        !busy &&
        (currentDestination != null ||
            savedDestinations.length < maxDestinationRecords);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (!widget.editorOnly) ...[
          Material(
            color: theme.colorScheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  if (widget.isLoading)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (savedDestinations.isEmpty)
                    const ListTile(
                      key: ValueKey('saved-location-empty'),
                      leading: Icon(Icons.bookmark_border),
                      title: Text('No saved locations'),
                      subtitle: Text('Add a location to show it on the watch.'),
                    ),
                  for (final destination in savedDestinations)
                    _SavedLocationSlotTile(
                      slotIndex: destination.slotIndex,
                      selected: false,
                      destination: destination,
                      enabled: !busy,
                      onTap: () => _openEditor(destination.slotIndex),
                    ),
                  ListTile(
                    key: const ValueKey('saved-location-add'),
                    enabled: canAdd,
                    leading: const Icon(Icons.add_location_alt_outlined),
                    title: const Text('Add Location'),
                    subtitle: const Text('Create another watch shortcut.'),
                    onTap: canAdd
                        ? () => _openEditor(_nextAvailableSlot()!)
                        : null,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (widget.editorOnly) ...[
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        savedLocationSlotIcon(_selectedSlot),
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          currentDestination?.label ?? 'New Saved Location',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      if (busy)
                        const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('saved-location-name'),
                    controller: _nameController,
                    enabled: !busy && _providerReady(_providerStatus),
                    inputFormatters: const [_WatchDestinationLabelFormatter()],
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Display name',
                      prefixIcon: Icon(Icons.label_outline),
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  _placeField(
                    context,
                    busy: busy || !_providerReady(_providerStatus),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<WatchTravelMode>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: WatchTravelMode.drive,
                        icon: Icon(Icons.directions_car_outlined),
                        label: Text('Drive'),
                      ),
                      ButtonSegment(
                        value: WatchTravelMode.walk,
                        icon: Icon(Icons.directions_walk),
                        label: Text('Walk'),
                      ),
                      ButtonSegment(
                        value: WatchTravelMode.bike,
                        icon: Icon(Icons.directions_bike),
                        label: Text('Bike'),
                      ),
                    ],
                    selected: {_travelMode},
                    onSelectionChanged: busy || !_providerReady(_providerStatus)
                        ? null
                        : (selection) {
                            setState(() {
                              _travelMode = selection.first;
                            });
                          },
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        key: const ValueKey('saved-location-save'),
                        onPressed: canSave ? _saveSelectedSlot : null,
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('Save Location'),
                      ),
                    ],
                  ),
                  if (!_providerReady(_providerStatus)) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Validate a Google API key before changing destinations.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _openSetup,
                      icon: const Icon(Icons.key_outlined),
                      label: const Text('Set up Google Maps'),
                    ),
                  ],
                  if (_localMessage != null || widget.detail != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _localMessage ?? widget.detail!,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _placeField(BuildContext context, {required bool busy}) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('saved-location-search'),
          controller: _destination.controller,
          enabled: !busy,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: 'Destination',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _destination.searching
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) {
            if (!busy) {
              unawaited(_saveSelectedSlot());
            }
          },
        ),
        if (_destination.suggestions.isNotEmpty) ...[
          const SizedBox(height: 8),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Material(
              color: Colors.transparent,
              child: Column(
                children: [
                  for (final suggestion in _destination.suggestions.take(4))
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.place_outlined),
                      title: Text(suggestion.primaryText),
                      subtitle: suggestion.secondaryText.isEmpty
                          ? null
                          : Text(suggestion.secondaryText),
                      onTap: busy ? null : () => _selectSuggestion(suggestion),
                    ),
                  if (_destination.attribution != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _destination.attribution!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        if (_destination.detail != null) ...[
          const SizedBox(height: 6),
          Text(
            _destination.detail!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _SavedLocationSlotTile extends StatelessWidget {
  const _SavedLocationSlotTile({
    required this.slotIndex,
    required this.selected,
    required this.destination,
    required this.enabled,
    required this.onTap,
  });

  final int slotIndex;
  final bool selected;
  final WatchDestinationConfig? destination;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configured = destination != null;
    final subtitle = configured
        ? '${destination!.address}\n${destination!.defaultTravelMode.label}'
        : 'Empty';
    return ListTile(
      key: ValueKey('saved-location-slot-$slotIndex'),
      enabled: enabled,
      selected: selected,
      leading: Icon(savedLocationSlotIcon(slotIndex)),
      title: Text(
        configured ? destination!.label : savedLocationSlotTitle(slotIndex),
      ),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      selectedTileColor: theme.colorScheme.secondaryContainer.withValues(
        alpha: 0.28,
      ),
      onTap: enabled ? onTap : null,
    );
  }
}
