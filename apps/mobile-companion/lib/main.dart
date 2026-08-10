import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:introduction_screen/introduction_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:showcaseview/showcaseview.dart';

import 'battery_optimization_bridge.dart';
import 'bridge_channel.dart';
import 'location_bridge.dart';
import 'provider_bridge.dart';
import 'watch_phone_worker.dart';
import 'watch_protocol.dart';

const _startupLocationTimeout = Duration(milliseconds: 1200);
const _welcomeSeenPreferenceKey = 'mappy_welcome_seen_v1';
const _fallbackMapTarget = gmaps.LatLng(51.5074, -0.1278);
final _googleApiKeyPattern = RegExp(r'^AIza[0-9A-Za-z_-]{16,}$');

String? googleApiKeyValidationError(String input) {
  final value = input.trim();
  if (value.isEmpty) {
    return 'Enter a Google API key before validating.';
  }
  if (!_googleApiKeyPattern.hasMatch(value)) {
    return 'Enter a valid Google API key starting with AIza, without spaces or surrounding text.';
  }
  return null;
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

enum CompanionTab {
  navigate,
  status,
  setup,
  savedLocations,
  settings,
  diagnostics,
}

List<CompanionTab> companionTabs() {
  return [
    CompanionTab.navigate,
    CompanionTab.status,
    CompanionTab.setup,
    CompanionTab.savedLocations,
    CompanionTab.settings,
    CompanionTab.diagnostics,
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

class _CompanionHomeState extends State<CompanionHome> {
  CompanionTab _selectedTab = CompanionTab.navigate;
  LocationPermissionState _permissionState = LocationPermissionState.unknown;
  ProviderStatus _providerStatus = const ProviderStatus.notConfigured();
  BridgeStatus _bridgeStatus = const BridgeStatus.unavailable();
  RouteResult? _routeResult;
  ShareRoutingStatus? _shareStatus;
  WatchRouteEndpoint? _activeRouteDestination;
  TravelMode? _activeRouteTravelMode;
  LocationSnapshot? _location;
  MapTileSettings _mapTileSettings = MapTileSettings.defaults;
  WatchDisplaySettings _displaySettings = WatchDisplaySettings.defaults;
  List<WatchDestinationConfig> _savedLocations = const [];
  String? _mapTileSettingsDetail;
  String? _displaySettingsDetail;
  String? _savedLocationsDetail;
  bool _isRefreshingLocation = false;
  bool _isValidatingProvider = false;
  bool _isComputingRoute = false;
  bool _isSavingMapTileSettings = false;
  bool _isSavingDisplaySettings = false;
  bool _isLoadingSavedLocations = true;
  bool _isSavingSavedLocation = false;
  bool _isClearingDiagnostics = false;
  bool _isClearingTileCache = false;
  bool _isClearingRouteCache = false;
  bool _isClearingProviderValidationCache = false;
  bool _isStartingWatchApp = false;
  bool _isRequestingNotificationPermission = false;
  bool _isRequestingBatteryOptimization = false;
  bool _welcomeStateLoaded = false;
  bool _showWelcomeFlow = false;
  bool _welcomeDebugReplay = false;
  String? _watchSessionDetail;
  BatteryOptimizationState _batteryOptimizationState =
      BatteryOptimizationState.unknown;
  final List<String> _diagnosticEvents = [];
  final GlobalKey _navigateShowcaseKey = GlobalKey();
  late final WatchMessageDispatcher _navigationDispatcher;
  StreamSubscription<BridgeEvent>? _bridgeSubscription;

  @override
  void initState() {
    super.initState();
    ShowcaseView.register(
      enableAutoScroll: true,
      blurValue: 1,
      overlayOpacity: 0.72,
      globalTooltipActionConfig: const TooltipActionConfig(
        position: TooltipActionPosition.inside,
        alignment: MainAxisAlignment.spaceBetween,
        gapBetweenContentAndAction: 12,
      ),
      globalTooltipActions: const [
        TooltipActionButton(type: TooltipDefaultActionType.skip),
        TooltipActionButton(type: TooltipDefaultActionType.next),
      ],
    );
    _navigationDispatcher =
        widget.watchDispatcher ??
        NativeWatchMessageDispatcher(
          providerRepository: widget.providerRepository,
        );
    _bridgeSubscription = widget.bridgeRepository.events.listen(
      _handleBridgeEvent,
      onError: (_) {},
    );
    unawaited(_loadBridgeStatus());
    unawaited(_loadBatteryOptimizationState());
    unawaited(_loadMapTileSettings());
    unawaited(_loadDisplaySettings());
    unawaited(_loadSavedLocations());
    unawaited(_loadWelcomeState());
    _refreshLocation(timeout: _startupLocationTimeout);
  }

  @override
  void dispose() {
    unawaited(_bridgeSubscription?.cancel());
    ShowcaseView.get().unregister();
    super.dispose();
  }

  Future<void> _loadWelcomeState() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) {
      return;
    }
    setState(() {
      _showWelcomeFlow =
          _shareStatus == null &&
          !(preferences.getBool(_welcomeSeenPreferenceKey) ?? false);
      _welcomeStateLoaded = true;
    });
  }

  Future<void> _finishWelcomeFlow() async {
    if (!_welcomeDebugReplay) {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(_welcomeSeenPreferenceKey, true);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _showWelcomeFlow = false;
      _welcomeDebugReplay = false;
      _selectedTab = CompanionTab.navigate;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _startShowcaseTour());
  }

  void _replayWelcomeFlow() {
    setState(() {
      _welcomeDebugReplay = true;
      _showWelcomeFlow = true;
    });
  }

  void _startShowcaseTour() {
    if (!mounted) {
      return;
    }
    ShowcaseView.get().startShowCase([_navigateShowcaseKey]);
  }

  Future<void> _loadBridgeStatus() async {
    final status = await widget.bridgeRepository.getBridgeStatus();
    if (!mounted) {
      return;
    }
    setState(() {
      _bridgeStatus = status;
    });
  }

  Future<void> _startWatchApp() async {
    setState(() {
      _isStartingWatchApp = true;
      _watchSessionDetail = null;
    });
    final status = await widget.bridgeRepository.startWatchApp();
    if (!mounted) {
      return;
    }
    setState(() {
      _bridgeStatus = status;
      _isStartingWatchApp = false;
      _watchSessionDetail = status.registered
          ? 'Opening the Mappy watch app.'
          : 'Pebble/Rebble is not ready on this phone.';
    });
  }

  Future<void> _requestNotificationPermission() async {
    setState(() {
      _isRequestingNotificationPermission = true;
      _watchSessionDetail = null;
    });
    final status = await widget.bridgeRepository
        .requestNotificationPermission();
    if (!mounted) {
      return;
    }
    setState(() {
      _bridgeStatus = status;
      _isRequestingNotificationPermission = false;
      _watchSessionDetail =
          status.notificationPermissionState.allowsWatchNotification
          ? 'Watch-session notifications are ready.'
          : 'Allow notifications in Android settings so the watch session can stay visible.';
    });
  }

  Future<void> _loadBatteryOptimizationState() async {
    final state = await widget.batteryOptimizationRepository
        .getBatteryOptimizationState();
    if (!mounted) {
      return;
    }
    setState(() {
      _batteryOptimizationState = state;
    });
  }

  Future<void> _requestDisableBatteryOptimization() async {
    setState(() {
      _isRequestingBatteryOptimization = true;
    });
    final state = await widget.batteryOptimizationRepository
        .requestDisableBatteryOptimization();
    if (!mounted) {
      return;
    }
    setState(() {
      _batteryOptimizationState = state;
      _isRequestingBatteryOptimization = false;
    });
  }

  void _handleBridgeEvent(BridgeEvent event) {
    if (!mounted) {
      return;
    }
    final status = event.status;
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
      }
      final providerStatus = event.providerStatus;
      if (providerStatus != null) {
        _providerStatus = providerStatus;
      }
      final locationStream = event.locationStream;
      if (locationStream != null) {
        _bridgeStatus = _bridgeStatus.copyWith(locationStream: locationStream);
        _permissionState = locationStream.permissionState;
      }
      final shareStatus = event.shareStatus;
      if (shareStatus != null) {
        _shareStatus = shareStatus;
        _selectedTab = CompanionTab.navigate;
        _showWelcomeFlow = false;
      }
      final diagnostic = _diagnosticLine(event);
      if (diagnostic != null) {
        _diagnosticEvents.insert(0, diagnostic);
        if (_diagnosticEvents.length > 25) {
          _diagnosticEvents.removeRange(25, _diagnosticEvents.length);
        }
      }
    });
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
      _mapTileSettingsDetail = result.detail;
      if (result.status.configured ||
          result.status.validationState !=
              ProviderValidationState.notConfigured) {
        _providerStatus = result.status;
      }
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
    setState(() {
      _isRefreshingLocation = true;
    });

    final permissionState = await widget.locationRepository
        .getPermissionState();
    final providerStatus = await widget.providerRepository.getProviderStatus();
    final location = permissionState.allowsLocation
        ? await widget.locationRepository.getCurrentLocation(timeout: timeout)
        : null;

    if (!mounted) {
      return;
    }

    setState(() {
      _permissionState = permissionState;
      _providerStatus = providerStatus;
      _location = location;
      _isRefreshingLocation = false;
    });
  }

  Future<void> _requestLocationPermission() async {
    setState(() {
      _isRefreshingLocation = true;
    });

    final permissionState = await widget.locationRepository
        .requestLocationPermission();
    final providerStatus = await widget.providerRepository.getProviderStatus();
    final location = permissionState.allowsLocation
        ? await widget.locationRepository.getCurrentLocation()
        : null;

    if (!mounted) {
      return;
    }

    setState(() {
      _permissionState = permissionState;
      _providerStatus = providerStatus;
      _location = location;
      _isRefreshingLocation = false;
    });
  }

  Future<void> _storeUserApiKey(String apiKey) async {
    setState(() {
      _isValidatingProvider = true;
    });

    var providerStatus = await widget.providerRepository.storeApiKey(apiKey);
    providerStatus = await widget.providerRepository.validateProviderSetup();

    if (!mounted) {
      return;
    }

    setState(() {
      _providerStatus = providerStatus;
      _isValidatingProvider = false;
    });
    await _refreshLocation();
  }

  Future<void> _validateProviderSetup() async {
    setState(() {
      _isValidatingProvider = true;
    });

    final providerStatus = await widget.providerRepository
        .validateProviderSetup();

    if (!mounted) {
      return;
    }

    setState(() {
      _providerStatus = providerStatus;
      _isValidatingProvider = false;
    });
    await _refreshLocation();
  }

  Future<void> _applyMapTileSettings(MapTileSettings settings) async {
    setState(() {
      _isSavingMapTileSettings = true;
      _mapTileSettings = settings;
      _mapTileSettingsDetail = null;
    });

    final result = await widget.providerRepository.setMapTileSettings(settings);
    final watchMessage = result.watchMessage;
    if (watchMessage != null) {
      await _navigationDispatcher.sendPhoneMessage(watchMessage);
    }
    if (!mounted) {
      return;
    }

    setState(() {
      _mapTileSettings = result.settings;
      _providerStatus = result.status;
      _mapTileSettingsDetail = result.detail;
      _isSavingMapTileSettings = false;
    });
  }

  Future<void> _clearMapTileCache() async {
    setState(() {
      _isSavingMapTileSettings = true;
      _isClearingTileCache = true;
      _mapTileSettingsDetail = null;
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
      _providerStatus = result.status;
      _mapTileSettingsDetail = result.detail;
      _isSavingMapTileSettings = false;
      _isClearingTileCache = false;
    });
  }

  Future<void> _clearRouteCacheFromDiagnostics() async {
    setState(() {
      _isClearingRouteCache = true;
    });
    try {
      await _navigationDispatcher.clearActiveRoute();
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
    setState(() {
      _routeResult = null;
      _activeRouteDestination = null;
      _activeRouteTravelMode = null;
      _isClearingRouteCache = false;
    });
  }

  Future<void> _clearProviderValidationCache() async {
    setState(() {
      _isClearingProviderValidationCache = true;
    });
    final status = await widget.providerRepository
        .clearProviderValidationCache();
    if (!mounted) {
      return;
    }
    setState(() {
      _providerStatus = status;
      _isClearingProviderValidationCache = false;
    });
  }

  Future<void> _applyDisplaySettings(WatchDisplaySettings settings) async {
    setState(() {
      _isSavingDisplaySettings = true;
      _displaySettings = settings;
      _displaySettingsDetail = null;
    });

    await _navigationDispatcher.setDisplaySettings(settings);

    if (!mounted) {
      return;
    }

    setState(() {
      _displaySettings = settings;
      _displaySettingsDetail = 'Watch display settings updated.';
      _isSavingDisplaySettings = false;
    });
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
    setState(() {
      _providerStatus = routeResult.status;
      _routeResult = routeResult;
      if (routeResult.ok) {
        _activeRouteDestination = destination;
        _activeRouteTravelMode = travelMode;
      } else if (routeResult.errorCategory == 7) {
        _activeRouteDestination = null;
        _activeRouteTravelMode = null;
      }
      _isComputingRoute = false;
      _watchSessionDetail = dispatchResult.detail;
    });
    if (!routeResult.ok) {
      return routeResult.detail ?? 'Route failed.';
    }
    return switch (dispatchResult.deliveryState) {
      WatchNavigationDeliveryState.applied => _navigationSentMessage(destination.label),
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
    final destination = _activeRouteDestination;
    final travelMode = _activeRouteTravelMode;
    if (destination == null || travelMode == null) {
      return 'No active route to reroute.';
    }

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
    setState(() {
      _providerStatus = routeResult.status;
      if (routeResult.ok || routeResult.errorCategory == 7) {
      _routeResult = routeResult;
      }
      if (routeResult.errorCategory == 7) {
        _activeRouteDestination = null;
        _activeRouteTravelMode = null;
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
    setState(() {
      _routeResult = null;
      _activeRouteDestination = null;
      _activeRouteTravelMode = null;
      _isComputingRoute = false;
      _watchSessionDetail = dispatchResult.detail;
    });
    return dispatchResult.detail ?? 'Route clear queued.';
  }

  Future<String> _saveSavedLocation(WatchDestinationConfig config) async {
    return _applySavedLocationUpdate(config);
  }

  Future<String> _clearSavedLocation(int slotIndex) async {
    return _applySavedLocationUpdate(
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
  }

  Future<String> _applySavedLocationUpdate(
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
        return 'Saved location update failed.';
      }
      setState(() {
        _savedLocationsDetail = 'Saved location update failed.';
        _isSavingSavedLocation = false;
      });
      return 'Saved location update failed.';
    }

    final errorText = _errorTextFromWatchResponses(responses);
    if (!mounted) {
      return errorText ?? 'Saved location updated.';
    }

    if (errorText != null) {
      setState(() {
        _savedLocationsDetail = errorText;
        _isSavingSavedLocation = false;
      });
      return errorText;
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
    return _savedLocationsDetail!;
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

  Future<void> _clearApiKey() async {
    final providerStatus = await widget.providerRepository.clearApiKey();
    if (!mounted) {
      return;
    }

    setState(() {
      _providerStatus = providerStatus;
      _routeResult = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_welcomeStateLoaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_showWelcomeFlow) {
      return WelcomeFlowScreen(
        permissionState: _permissionState,
        notificationPermissionState: _bridgeStatus.notificationPermissionState,
        batteryOptimizationState: _batteryOptimizationState,
        isRequestingLocation: _isRefreshingLocation,
        isRequestingNotificationPermission: _isRequestingNotificationPermission,
        isRequestingBatteryOptimization: _isRequestingBatteryOptimization,
        onRequestLocation: _requestLocationPermission,
        onRequestNotificationPermission: _requestNotificationPermission,
        onRequestBatteryOptimization: _requestDisableBatteryOptimization,
        onDone: _finishWelcomeFlow,
      );
    }

    final tabs = companionTabs();
    if (!tabs.contains(_selectedTab)) {
      _selectedTab = tabs.first;
    }
    final title = switch (_selectedTab) {
      CompanionTab.navigate => 'Navigate',
      CompanionTab.status => 'Status',
      CompanionTab.setup => 'Setup',
      CompanionTab.savedLocations => 'Saved Locations',
      CompanionTab.settings => 'Settings',
      CompanionTab.diagnostics => 'Diagnostics',
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _isRefreshingLocation ? null : _refreshLocation,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'View Welcome',
            onPressed: _replayWelcomeFlow,
            icon: const Icon(Icons.help_outline),
          ),
        ],
      ),
      body: SafeArea(
        child: switch (_selectedTab) {
          CompanionTab.navigate => NavigateScreen(
            providerStatus: _providerStatus,
            location: _location,
            routeResult: _routeResult,
            shareStatus: _shareStatus,
            activeDestinationLabel: _activeRouteDestination?.label,
            isComputingRoute: _isComputingRoute,
            providerRepository: widget.providerRepository,
            enableEmbeddedGoogleMap: widget.enableEmbeddedGoogleMap,
            defaultTravelMode: _travelModeForWatch(_displaySettings.travelMode),
            onNavigateNow: _navigateNowRoute,
            onRerouteActiveRoute: _rerouteActiveRoute,
            onClearActiveRoute: _clearActiveRoute,
            navigateShowcaseKey: _navigateShowcaseKey,
          ),
          CompanionTab.status => StatusScreen(
            permissionState: _permissionState,
            providerStatus: _providerStatus,
            bridgeStatus: _bridgeStatus,
            location: _location,
            isRefreshingLocation: _isRefreshingLocation,
            isStartingWatchApp: _isStartingWatchApp,
            isRequestingNotificationPermission:
                _isRequestingNotificationPermission,
            watchSessionDetail: _watchSessionDetail,
            onRequestLocation: _requestLocationPermission,
            onRefreshLocation: _refreshLocation,
            onValidateProvider: _validateProviderSetup,
            onStartWatchApp: _startWatchApp,
            onRequestNotificationPermission: _requestNotificationPermission,
            onOpenSetup: () {
              setState(() {
                _selectedTab = CompanionTab.setup;
              });
            },
          ),
          CompanionTab.setup => SetupScreen(
            providerStatus: _providerStatus,
            bridgeStatus: _bridgeStatus,
            permissionState: _permissionState,
            location: _location,
            isValidatingProvider: _isValidatingProvider,
            onStoreApiKey: _storeUserApiKey,
            onValidateProvider: _validateProviderSetup,
            onClearApiKey: _clearApiKey,
          ),
          CompanionTab.savedLocations => SavedLocationsScreen(
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
          ),
          CompanionTab.settings => SettingsScreen(
            settings: _mapTileSettings,
            displaySettings: _displaySettings,
            isSaving: _isSavingMapTileSettings,
            isSavingDisplaySettings: _isSavingDisplaySettings,
            detail: _mapTileSettingsDetail,
            displaySettingsDetail: _displaySettingsDetail,
            onChanged: _applyMapTileSettings,
            onDisplaySettingsChanged: _applyDisplaySettings,
            onClearCache: _clearMapTileCache,
          ),
          CompanionTab.diagnostics => DiagnosticsScreen(
            events: _diagnosticEvents,
            isClearingDiagnostics: _isClearingDiagnostics,
            onExportDiagnostics: _exportDiagnostics,
            onClearDiagnostics: _clearDiagnostics,
            isClearingTileCache: _isClearingTileCache,
            onClearTileCache: _clearMapTileCache,
            isClearingRouteCache: _isClearingRouteCache,
            onClearRouteCache: _clearRouteCacheFromDiagnostics,
            isClearingProviderValidationCache:
                _isClearingProviderValidationCache,
            onClearProviderValidationCache: _clearProviderValidationCache,
          ),
        },
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
              CompanionTab.status => const NavigationDestination(
                icon: Icon(Icons.check_circle_outline),
                selectedIcon: Icon(Icons.check_circle),
                label: 'Status',
              ),
              CompanionTab.setup => const NavigationDestination(
                icon: Icon(Icons.key_outlined),
                selectedIcon: Icon(Icons.key),
                label: 'Setup',
              ),
              CompanionTab.savedLocations => const NavigationDestination(
                icon: Icon(Icons.bookmark_border),
                selectedIcon: Icon(Icons.bookmark),
                label: 'Saved',
              ),
              CompanionTab.settings => const NavigationDestination(
                icon: Icon(Icons.tune_outlined),
                selectedIcon: Icon(Icons.tune),
                label: 'Settings',
              ),
              CompanionTab.diagnostics => const NavigationDestination(
                icon: Icon(Icons.receipt_long_outlined),
                selectedIcon: Icon(Icons.receipt_long),
                label: 'Diagnostics',
              ),
            },
        ],
      ),
    );
  }
}

class WelcomeFlowScreen extends StatelessWidget {
  const WelcomeFlowScreen({
    required this.permissionState,
    required this.notificationPermissionState,
    required this.batteryOptimizationState,
    required this.isRequestingLocation,
    required this.isRequestingNotificationPermission,
    required this.isRequestingBatteryOptimization,
    required this.onRequestLocation,
    required this.onRequestNotificationPermission,
    required this.onRequestBatteryOptimization,
    required this.onDone,
    super.key,
  });

  final LocationPermissionState permissionState;
  final NotificationPermissionState notificationPermissionState;
  final BatteryOptimizationState batteryOptimizationState;
  final bool isRequestingLocation;
  final bool isRequestingNotificationPermission;
  final bool isRequestingBatteryOptimization;
  final VoidCallback onRequestLocation;
  final VoidCallback onRequestNotificationPermission;
  final VoidCallback onRequestBatteryOptimization;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pageDecoration = PageDecoration(
      titleTextStyle: theme.textTheme.headlineSmall!.copyWith(
        fontWeight: FontWeight.w700,
      ),
      bodyTextStyle: theme.textTheme.bodyLarge!.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
      imageFlex: 2,
      bodyFlex: 3,
      footerFlex: 2,
      safeArea: 92,
      pageColor: theme.colorScheme.surface,
      contentMargin: const EdgeInsets.symmetric(horizontal: 24),
      footerPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
    );

    return IntroductionScreen(
      pages: [
        PageViewModel(
          title: 'Navigate from the phone',
          body:
              'Search for a place, choose current GPS or a specific origin, and send the route straight to the Pebble watch.',
          image: const _WelcomeIcon(icon: Icons.navigation_outlined),
          decoration: pageDecoration,
        ),
        PageViewModel(
          title: 'Allow all-the-time location',
          body:
              'Mappy sends live geolocation to the Pebble watch while the phone app is backgrounded. Android needs location set to Allow all the time so an active route does not go stale.',
          image: const _WelcomeIcon(icon: Icons.location_searching_outlined),
          footer: _WelcomePermissionFooter(
            icon: Icons.location_on_outlined,
            status: _welcomeLocationStatus(permissionState),
            buttonLabel: _welcomeLocationActionLabel(permissionState),
            isComplete: permissionState.allowsBackgroundLocation,
            isBusy: isRequestingLocation,
            onPressed:
                permissionState.allowsBackgroundLocation ||
                    permissionState == LocationPermissionState.unavailable
                ? null
                : onRequestLocation,
          ),
          decoration: pageDecoration,
        ),
        PageViewModel(
          title: 'Allow notifications',
          body:
              'Android requires a visible notification for the foreground service that keeps Pebble routing alive. Mappy uses it for the active watch session.',
          image: const _WelcomeIcon(icon: Icons.notifications_active_outlined),
          footer: _WelcomePermissionFooter(
            icon: Icons.notifications_outlined,
            status: _welcomeNotificationStatus(notificationPermissionState),
            buttonLabel: _welcomeNotificationActionLabel(
              notificationPermissionState,
            ),
            isComplete: notificationPermissionState.allowsWatchNotification,
            isBusy: isRequestingNotificationPermission,
            onPressed: notificationPermissionState.canRequest
                ? onRequestNotificationPermission
                : null,
          ),
          decoration: pageDecoration,
        ),
        PageViewModel(
          title: 'Disable battery optimizations',
          body:
              'Some Android builds stop background location and Pebble delivery when battery optimization is enabled. Exempt Mappy so active routes keep updating.',
          image: const _WelcomeIcon(icon: Icons.battery_saver_outlined),
          footer: _WelcomePermissionFooter(
            icon: Icons.battery_charging_full_outlined,
            status: _welcomeBatteryOptimizationStatus(batteryOptimizationState),
            buttonLabel: _welcomeBatteryOptimizationActionLabel(
              batteryOptimizationState,
            ),
            isComplete: batteryOptimizationState.isReady,
            isBusy: isRequestingBatteryOptimization,
            onPressed: batteryOptimizationState.canRequest
                ? onRequestBatteryOptimization
                : null,
          ),
          decoration: pageDecoration,
        ),
        PageViewModel(
          title: 'Bring your Google key',
          body:
              'Setup shows the Android package and signing SHA-1. Use them with Map Tiles, Places, Geocoding, and Routes APIs.',
          image: const _WelcomeIcon(icon: Icons.key_outlined),
          decoration: pageDecoration,
        ),
        PageViewModel(
          title: 'Use Status when blocked',
          body:
              'Status shows the exact missing piece: key, provider validation, always location, notifications, battery settings, watch bridge, or foreground service.',
          image: const _WelcomeIcon(icon: Icons.check_circle_outline),
          decoration: pageDecoration,
        ),
      ],
      onDone: onDone,
      onSkip: onDone,
      showSkipButton: true,
      safeAreaList: const [true, true, true, true],
      controlsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      bodyPadding: const EdgeInsets.only(bottom: 8),
      skip: const Text('Skip'),
      next: const Icon(Icons.arrow_forward),
      done: const Text('Start', style: TextStyle(fontWeight: FontWeight.w700)),
      dotsDecorator: DotsDecorator(
        activeColor: theme.colorScheme.primary,
        activeSize: const Size(22, 10),
        activeShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}

class _WelcomePermissionFooter extends StatelessWidget {
  const _WelcomePermissionFooter({
    required this.icon,
    required this.status,
    required this.buttonLabel,
    required this.isComplete,
    required this.isBusy,
    required this.onPressed,
  });

  final IconData icon;
  final String status;
  final String buttonLabel;
  final bool isComplete;
  final bool isBusy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final backgroundColor = isComplete
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final foregroundColor = isComplete
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurfaceVariant;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(
                  isComplete ? Icons.check_circle_outline : icon,
                  color: foregroundColor,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    status,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foregroundColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: isBusy ? null : onPressed,
          icon: isBusy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(isComplete ? Icons.check : icon),
          label: Text(isBusy ? 'Opening Settings' : buttonLabel),
        ),
      ],
    );
  }
}

String _welcomeLocationStatus(LocationPermissionState state) {
  if (state.allowsBackgroundLocation) {
    return 'Always location is ready.';
  }
  if (state.allowsLocation) {
    return 'Foreground location is on. Switch Mappy to Allow all the time in Android settings.';
  }
  switch (state) {
    case LocationPermissionState.serviceDisabled:
      return 'Turn on Android location services, then allow location for Mappy.';
    case LocationPermissionState.permanentlyDenied:
      return 'Android settings must be used before Mappy can request location again.';
    case LocationPermissionState.unavailable:
      return 'Location is unavailable on this device.';
    case LocationPermissionState.unknown:
      return 'Mappy has not checked Android location permission yet.';
    case LocationPermissionState.requestAvailable:
    case LocationPermissionState.denied:
      return 'Android location permission is not granted yet.';
    case LocationPermissionState.grantedPrecise:
    case LocationPermissionState.grantedApproximate:
    case LocationPermissionState.grantedAlwaysPrecise:
    case LocationPermissionState.grantedAlwaysApproximate:
      return 'Always location is ready.';
  }
}

String _welcomeLocationActionLabel(LocationPermissionState state) {
  if (state.allowsBackgroundLocation) {
    return 'Always Location Ready';
  }
  if (state.allowsLocation) {
    return 'Open Always Location';
  }
  switch (state) {
    case LocationPermissionState.serviceDisabled:
      return 'Check Location';
    case LocationPermissionState.permanentlyDenied:
      return 'Open Location Settings';
    case LocationPermissionState.unavailable:
      return 'Location Unavailable';
    case LocationPermissionState.unknown:
    case LocationPermissionState.requestAvailable:
    case LocationPermissionState.denied:
    case LocationPermissionState.grantedPrecise:
    case LocationPermissionState.grantedApproximate:
    case LocationPermissionState.grantedAlwaysPrecise:
    case LocationPermissionState.grantedAlwaysApproximate:
      return 'Allow Location';
  }
}

String _welcomeNotificationStatus(NotificationPermissionState state) {
  if (state.allowsWatchNotification) {
    return state == NotificationPermissionState.notRequired
        ? 'This Android version does not require notification permission.'
        : 'Watch-session notifications are ready.';
  }
  switch (state) {
    case NotificationPermissionState.permanentlyDenied:
      return 'Android settings must be used before Mappy can show watch-session notifications.';
    case NotificationPermissionState.unavailable:
      return 'Notification permission status is unavailable on this device.';
    case NotificationPermissionState.unknown:
      return 'Mappy has not checked notification permission yet.';
    case NotificationPermissionState.requestAvailable:
    case NotificationPermissionState.denied:
      return 'Android notification permission is not granted yet.';
    case NotificationPermissionState.granted:
    case NotificationPermissionState.notRequired:
      return 'Watch-session notifications are ready.';
  }
}

String _welcomeNotificationActionLabel(NotificationPermissionState state) {
  if (state.allowsWatchNotification) {
    return state == NotificationPermissionState.notRequired
        ? 'Notifications Not Required'
        : 'Notifications Ready';
  }
  switch (state) {
    case NotificationPermissionState.permanentlyDenied:
      return 'Open Notification Settings';
    case NotificationPermissionState.unavailable:
      return 'Notifications Unavailable';
    case NotificationPermissionState.unknown:
    case NotificationPermissionState.requestAvailable:
    case NotificationPermissionState.denied:
    case NotificationPermissionState.granted:
    case NotificationPermissionState.notRequired:
      return 'Allow Notifications';
  }
}

String _welcomeBatteryOptimizationStatus(BatteryOptimizationState state) {
  switch (state) {
    case BatteryOptimizationState.disabled:
      return 'Battery optimizations are disabled for Mappy.';
    case BatteryOptimizationState.enabled:
      return 'Android may pause Mappy in the background unless optimizations are disabled.';
    case BatteryOptimizationState.unavailable:
      return 'Battery optimization settings are unavailable on this device.';
    case BatteryOptimizationState.unknown:
      return 'Mappy has not checked battery optimization yet.';
  }
}

String _welcomeBatteryOptimizationActionLabel(BatteryOptimizationState state) {
  switch (state) {
    case BatteryOptimizationState.disabled:
      return 'Battery Ready';
    case BatteryOptimizationState.enabled:
      return 'Disable Optimization';
    case BatteryOptimizationState.unavailable:
      return 'Battery Unavailable';
    case BatteryOptimizationState.unknown:
      return 'Check Battery Setting';
  }
}

class _WelcomeIcon extends StatelessWidget {
  const _WelcomeIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Container(
        width: 112,
        height: 112,
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 52,
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

class NavigateScreen extends StatelessWidget {
  const NavigateScreen({
    required this.providerStatus,
    required this.location,
    required this.routeResult,
    required this.shareStatus,
    required this.activeDestinationLabel,
    required this.isComputingRoute,
    required this.providerRepository,
    required this.enableEmbeddedGoogleMap,
    required this.defaultTravelMode,
    required this.onNavigateNow,
    required this.onRerouteActiveRoute,
    required this.onClearActiveRoute,
    required this.navigateShowcaseKey,
    super.key,
  });

  final ProviderStatus providerStatus;
  final LocationSnapshot? location;
  final RouteResult? routeResult;
  final ShareRoutingStatus? shareStatus;
  final String? activeDestinationLabel;
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
  final GlobalKey navigateShowcaseKey;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (shareStatus != null) ...[
          ShareRoutingPanel(status: shareStatus!),
          const SizedBox(height: 16),
        ],
        Showcase(
          key: navigateShowcaseKey,
          title: 'Navigate',
          description:
              'Search a destination, choose an origin, and send an active route to the watch.',
          targetPadding: const EdgeInsets.all(6),
          tooltipPadding: const EdgeInsets.all(14),
          toolTipMargin: 28,
          child: RouteProbePanel(
            location: location,
            providerRepository: providerRepository,
            providerStatus: providerStatus,
            routeResult: routeResult,
            activeDestinationLabel: activeDestinationLabel,
            isComputingRoute: isComputingRoute,
            enableEmbeddedGoogleMap: enableEmbeddedGoogleMap,
            defaultTravelMode: defaultTravelMode,
            onNavigateNow: onNavigateNow,
            onRerouteActiveRoute: onRerouteActiveRoute,
            onClearActiveRoute: onClearActiveRoute,
          ),
        ),
      ],
    );
  }
}

class ShareRoutingPanel extends StatelessWidget {
  const ShareRoutingPanel({required this.status, super.key});

  final ShareRoutingStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = switch (status.state) {
      'activeRoute' => StatusTone.ok,
      'unsupported' || 'noRoute' || 'error' => StatusTone.warning,
      _ => StatusTone.neutral,
    };
    final icon = switch (status.state) {
      'activeRoute' => Icons.ios_share,
      'unsupported' || 'noRoute' || 'error' => Icons.report_problem_outlined,
      'resolvingShortLink' => Icons.link,
      _ => Icons.route_outlined,
    };
    final summary = status.routeSummary;
    final destinationLabel = status.destinationLabel;
    final originLabel = status.originLabel;

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
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(status.title, style: theme.textTheme.titleMedium),
                ),
                if (!status.isTerminal)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(status.subtitle, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (status.shareType != null)
                  StatusPill(
                    icon: Icons.map_outlined,
                    label: _shareStatusLabel(status.shareType!),
                    tone: tone,
                  ),
                if (status.travelMode != null)
                  StatusPill(
                    icon: Icons.alt_route_outlined,
                    label: _shareStatusLabel(status.travelMode!),
                    tone: StatusTone.neutral,
                  ),
                if (status.safeHost != null)
                  StatusPill(
                    icon: Icons.verified_outlined,
                    label: status.safeHost!,
                    tone: StatusTone.neutral,
                  ),
                if ((status.redirectHopCount ?? 0) > 0)
                  StatusPill(
                    icon: Icons.link,
                    label: '${status.redirectHopCount} redirect',
                    tone: StatusTone.neutral,
                  ),
                if (status.explicitOrigin)
                  const StatusPill(
                    icon: Icons.trip_origin,
                    label: 'Shared origin',
                    tone: StatusTone.neutral,
                  ),
                if (status.destinationHasCoordinates)
                  const StatusPill(
                    icon: Icons.pin_drop_outlined,
                    label: 'Coordinates',
                    tone: StatusTone.neutral,
                  ),
              ],
            ),
            if (originLabel != null || destinationLabel != null) ...[
              const SizedBox(height: 12),
              if (originLabel != null)
                Text('From: $originLabel', style: theme.textTheme.bodySmall),
              if (destinationLabel != null)
                Text('To: $destinationLabel', style: theme.textTheme.bodySmall),
            ],
            if (summary != null) ...[
              const SizedBox(height: 8),
              Text(summary, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            Text(
              'Mappy recomputes Google Maps shares, so route alternatives may differ.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (status.routeWarning != null) ...[
              const SizedBox(height: 8),
              Text(status.routeWarning!, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

String _shareStatusLabel(String value) {
  return switch (value) {
    'drive' => 'Drive',
    'walk' => 'Walk',
    'bike' => 'Bike',
    'route' => 'Route',
    'location' => 'Location',
    _ => value,
  };
}

class StatusScreen extends StatelessWidget {
  const StatusScreen({
    required this.permissionState,
    required this.providerStatus,
    required this.bridgeStatus,
    required this.location,
    required this.isRefreshingLocation,
    required this.isStartingWatchApp,
    required this.isRequestingNotificationPermission,
    required this.watchSessionDetail,
    required this.onRequestLocation,
    required this.onRefreshLocation,
    required this.onValidateProvider,
    required this.onStartWatchApp,
    required this.onRequestNotificationPermission,
    required this.onOpenSetup,
    super.key,
  });

  final LocationPermissionState permissionState;
  final ProviderStatus providerStatus;
  final BridgeStatus bridgeStatus;
  final LocationSnapshot? location;
  final bool isRefreshingLocation;
  final bool isStartingWatchApp;
  final bool isRequestingNotificationPermission;
  final String? watchSessionDetail;
  final VoidCallback onRequestLocation;
  final VoidCallback onRefreshLocation;
  final VoidCallback onValidateProvider;
  final VoidCallback onStartWatchApp;
  final VoidCallback onRequestNotificationPermission;
  final VoidCallback onOpenSetup;

  @override
  Widget build(BuildContext context) {
    final locationLabel = location == null
        ? permissionState.label
        : '${location!.coordinateLabel} (${location!.freshnessLabel})';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        ReadinessPanel(
          permissionState: permissionState,
          providerStatus: providerStatus,
          bridgeStatus: bridgeStatus,
          location: location,
          isRefreshingLocation: isRefreshingLocation,
          isStartingWatchApp: isStartingWatchApp,
          isRequestingNotificationPermission:
              isRequestingNotificationPermission,
          watchSessionDetail: watchSessionDetail,
          onRequestLocation: onRequestLocation,
          onRefreshLocation: onRefreshLocation,
          onValidateProvider: onValidateProvider,
          onStartWatchApp: onStartWatchApp,
          onRequestNotificationPermission: onRequestNotificationPermission,
          onOpenSetup: onOpenSetup,
        ),
        const SizedBox(height: 16),
        _StatusPanel(
          title: 'Readiness Details',
          rows: [
            StatusRow(
              icon: Icons.watch_outlined,
              label: 'Watch bridge',
              value: bridgeStatus.watchDetailLabel,
            ),
            StatusRow(
              icon: Icons.notifications_active_outlined,
              label: 'Watch-session notification',
              value: bridgeStatus.notificationPermissionState.label,
            ),
            StatusRow(
              icon: Icons.run_circle_outlined,
              label: 'Foreground service',
              value: bridgeStatus.foregroundServiceLabel,
            ),
            StatusRow(
              icon: Icons.gps_fixed,
              label: 'Live GPS',
              value: bridgeStatus.locationStreamLabel,
            ),
            StatusRow(
              icon: Icons.my_location,
              label: 'Location',
              value: locationLabel,
            ),
            StatusRow(
              icon: Icons.cloud_outlined,
              label: 'Provider',
              value: _providerStatusDetail(providerStatus),
            ),
          ],
        ),
      ],
    );
  }
}

class ReadinessPanel extends StatelessWidget {
  const ReadinessPanel({
    required this.permissionState,
    required this.providerStatus,
    required this.bridgeStatus,
    required this.location,
    required this.isRefreshingLocation,
    required this.isStartingWatchApp,
    required this.isRequestingNotificationPermission,
    required this.watchSessionDetail,
    required this.onRequestLocation,
    required this.onRefreshLocation,
    required this.onValidateProvider,
    required this.onStartWatchApp,
    required this.onRequestNotificationPermission,
    required this.onOpenSetup,
    this.showcaseKey,
    this.watchActionShowcaseKey,
    super.key,
  });

  final LocationPermissionState permissionState;
  final ProviderStatus providerStatus;
  final BridgeStatus bridgeStatus;
  final LocationSnapshot? location;
  final bool isRefreshingLocation;
  final bool isStartingWatchApp;
  final bool isRequestingNotificationPermission;
  final String? watchSessionDetail;
  final VoidCallback onRequestLocation;
  final VoidCallback onRefreshLocation;
  final VoidCallback onValidateProvider;
  final VoidCallback onStartWatchApp;
  final VoidCallback onRequestNotificationPermission;
  final VoidCallback onOpenSetup;
  final GlobalKey? showcaseKey;
  final GlobalKey? watchActionShowcaseKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = DecoratedBox(
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
            Text('Ready to Navigate', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: _statusPills()),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: _actionButtons(context)),
            if (_fixMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _fixMessage!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (watchSessionDetail != null) ...[
              const SizedBox(height: 8),
              Text(watchSessionDetail!, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );

    final key = showcaseKey;
    if (key == null) {
      return content;
    }
    return Showcase(
      key: key,
      title: 'Readiness',
      description:
          'This area shows what needs attention before the phone can guide the watch.',
      targetPadding: const EdgeInsets.all(6),
      tooltipPadding: const EdgeInsets.all(14),
      toolTipMargin: 28,
      child: content,
    );
  }

  List<Widget> _statusPills() {
    final hasLocation = location != null;
    final watchAvailable =
        bridgeStatus.watchReady || bridgeStatus.watchConnected;
    final notificationReady =
        bridgeStatus.notificationPermissionState.allowsWatchNotification;
    return [
      StatusPill(
        icon: Icons.watch_outlined,
        label: bridgeStatus.watchLabel,
        tone: watchAvailable ? StatusTone.ok : StatusTone.neutral,
      ),
      StatusPill(
        icon: bridgeStatus.foregroundServiceActive
            ? Icons.run_circle_outlined
            : Icons.motion_photos_pause_outlined,
        label: bridgeStatus.foregroundServiceActive
            ? 'Session active'
            : 'Session waiting',
        tone: bridgeStatus.foregroundServiceActive
            ? StatusTone.ok
            : StatusTone.neutral,
      ),
      StatusPill(
        icon: notificationReady
            ? Icons.notifications_active_outlined
            : Icons.notifications_off_outlined,
        label: notificationReady ? 'Notifications ready' : 'Notifications',
        tone: notificationReady ? StatusTone.ok : StatusTone.warning,
      ),
      StatusPill(
        icon: providerStatus.configured
            ? Icons.key_outlined
            : Icons.key_off_outlined,
        label: providerStatus.configured ? 'Key stored' : 'Missing key',
        tone: _providerReady(providerStatus)
            ? StatusTone.ok
            : StatusTone.warning,
      ),
      StatusPill(
        icon: _providerReady(providerStatus)
            ? Icons.cloud_done_outlined
            : Icons.cloud_off_outlined,
        label: providerStatus.providerLabel,
        tone: _providerReady(providerStatus)
            ? StatusTone.ok
            : StatusTone.warning,
      ),
      StatusPill(
        icon: hasLocation ? Icons.gps_fixed : Icons.gps_off,
        label: hasLocation ? location!.freshnessLabel : permissionState.label,
        tone: hasLocation ? StatusTone.ok : StatusTone.warning,
      ),
    ];
  }

  List<Widget> _actionButtons(BuildContext context) {
    final locationAction = _locationAction();
    final providerAction = _providerAction();
    final notificationAction = _notificationAction();
    final watchButton = OutlinedButton.icon(
      key: const ValueKey('status-open-watch'),
      onPressed: isStartingWatchApp ? null : onStartWatchApp,
      icon: isStartingWatchApp
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.watch_outlined),
      label: Text(isStartingWatchApp ? 'Opening Watch' : 'Open Watch'),
    );
    final watchKey = watchActionShowcaseKey;
    return [
      FilledButton.icon(
        onPressed: isRefreshingLocation ? null : locationAction.onPressed,
        icon: Icon(locationAction.icon),
        label: Text(
          isRefreshingLocation ? 'Checking Location' : locationAction.label,
        ),
      ),
      OutlinedButton.icon(
        onPressed: providerAction.onPressed,
        icon: Icon(providerAction.icon),
        label: Text(providerAction.label),
      ),
      if (notificationAction != null)
        OutlinedButton.icon(
          onPressed: isRequestingNotificationPermission
              ? null
              : notificationAction.onPressed,
          icon: Icon(notificationAction.icon),
          label: Text(
            isRequestingNotificationPermission
                ? 'Requesting'
                : notificationAction.label,
          ),
        ),
      if (watchKey == null)
        watchButton
      else
        Showcase(
          key: watchKey,
          title: 'Open Watch',
          description:
              'Use this if the Pebble app is not active or the session needs to be restarted.',
          targetPadding: const EdgeInsets.all(6),
          tooltipPadding: const EdgeInsets.all(14),
          toolTipMargin: 28,
          child: watchButton,
        ),
    ];
  }

  _LocationAction _locationAction() {
    return switch (permissionState) {
      LocationPermissionState.serviceDisabled => _LocationAction(
        icon: Icons.location_disabled_outlined,
        label: 'Refresh Location',
        onPressed: onRefreshLocation,
      ),
      _
          when permissionState.allowsLocation &&
              !permissionState.allowsBackgroundLocation =>
        _LocationAction(
          icon: Icons.location_searching_outlined,
          label: 'Allow Always',
          onPressed: onRequestLocation,
        ),
      _ when permissionState.allowsLocation => _LocationAction(
        icon: Icons.my_location,
        label: 'Recenter',
        onPressed: onRefreshLocation,
      ),
      _ => _LocationAction(
        icon: Icons.location_on_outlined,
        label: 'Grant Location',
        onPressed: onRequestLocation,
      ),
    };
  }

  _LocationAction _providerAction() {
    if (!providerStatus.configured) {
      return _LocationAction(
        icon: Icons.key_outlined,
        label: 'API Key',
        onPressed: onOpenSetup,
      );
    }
    if (!_providerReady(providerStatus)) {
      return _LocationAction(
        icon: Icons.build_outlined,
        label: 'Fix Key',
        onPressed: onOpenSetup,
      );
    }
    return _LocationAction(
      icon: Icons.cloud_sync_outlined,
      label: 'Validate',
      onPressed: onValidateProvider,
    );
  }

  _LocationAction? _notificationAction() {
    final state = bridgeStatus.notificationPermissionState;
    if (!state.canRequest) {
      return null;
    }
    return _LocationAction(
      icon: Icons.notifications_outlined,
      label: 'Allow Notifications',
      onPressed: onRequestNotificationPermission,
    );
  }

  String? get _fixMessage {
    if (!_providerReady(providerStatus)) {
      return _providerFixMessage(providerStatus);
    }
    if (!permissionState.allowsLocation) {
      return _locationFixMessage(permissionState);
    }
    if (!permissionState.allowsBackgroundLocation) {
      return 'Allow all-the-time location in Android settings so the watch can keep receiving GPS when the phone app is backgrounded.';
    }
    final notificationState = bridgeStatus.notificationPermissionState;
    if (!notificationState.allowsWatchNotification) {
      return _notificationFixMessage(notificationState);
    }
    if (!bridgeStatus.registered) {
      return 'Install and connect Pebble/Rebble, then open Mappy on the watch.';
    }
    if (!bridgeStatus.watchReady && !bridgeStatus.watchConnected) {
      return 'Open Mappy on the watch to start the bridge session.';
    }
    return null;
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
    required this.activeDestinationLabel,
    required this.isComputingRoute,
    required this.enableEmbeddedGoogleMap,
    required this.defaultTravelMode,
    required this.onNavigateNow,
    required this.onRerouteActiveRoute,
    required this.onClearActiveRoute,
    super.key,
  });

  final LocationSnapshot? location;
  final ProviderRepository providerRepository;
  final ProviderStatus providerStatus;
  final RouteResult? routeResult;
  final String? activeDestinationLabel;
  final bool isComputingRoute;
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

  Future<void> _rerouteActiveRoute() async {
    setState(() {
      _localMessage = null;
      _sentDestinationLabel = null;
    });
    final message = await widget.onRerouteActiveRoute();
    if (!mounted) {
      return;
    }
    setState(() {
      _localMessage = message;
      _sentDestinationLabel = null;
    });
  }

  Future<void> _clearActiveRoute() async {
    setState(() {
      _localMessage = null;
      _sentDestinationLabel = null;
    });
    final message = await widget.onClearActiveRoute();
    if (!mounted) {
      return;
    }
    setState(() {
      _localMessage = message;
      _sentDestinationLabel = null;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _resolving || widget.isComputingRoute;
    final providerReady = _providerReady(widget.providerStatus);
    final canNavigate = providerReady && !busy;
    final hasActiveRoute = widget.routeResult?.ok == true;
    final warning = _travelMode == TravelMode.drive
        ? widget.routeResult?.routeWarning
        : 'Walk and bike routes may miss safe pedestrian or bicycling path detail.';
    final mapTarget = _destinationMapInitialTarget();
    if (_destinationMapController == null) {
      _destinationMapCenter = mapTarget;
    }

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
                  child: Text(
                    'Navigate Now',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (busy)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<WatchRouteOriginPolicy>(
              segments: const [
                ButtonSegment(
                  value: WatchRouteOriginPolicy.currentLocation,
                  icon: Icon(Icons.my_location),
                  label: Text('Current'),
                ),
                ButtonSegment(
                  value: WatchRouteOriginPolicy.explicitPlace,
                  icon: Icon(Icons.place_outlined),
                  label: Text('Place'),
                ),
              ],
              selected: {_originPolicy},
              onSelectionChanged: busy
                  ? null
                  : (selection) {
                      setState(() {
                        _originPolicy = selection.first;
                        _localMessage = null;
                      });
                    },
            ),
            if (_originPolicy == WatchRouteOriginPolicy.explicitPlace) ...[
              const SizedBox(height: 12),
              _placeField(context, _origin, labelText: 'From'),
            ],
            const SizedBox(height: 12),
            _placeField(context, _destination, labelText: 'Navigate to'),
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
            const SizedBox(height: 12),
            SegmentedButton<TravelMode>(
              segments: const [
                ButtonSegment<TravelMode>(
                  value: TravelMode.drive,
                  icon: Icon(Icons.directions_car_outlined),
                  label: Text('Drive'),
                ),
                ButtonSegment<TravelMode>(
                  value: TravelMode.walk,
                  icon: Icon(Icons.directions_walk),
                  label: Text('Walk'),
                ),
                ButtonSegment<TravelMode>(
                  value: TravelMode.bike,
                  icon: Icon(Icons.directions_bike),
                  label: Text('Bike'),
                ),
              ],
              selected: {_travelMode},
              onSelectionChanged: busy
                  ? null
                  : (selection) {
                      setState(() {
                        _travelMode = selection.first;
                      });
                    },
            ),
            if (warning != null) ...[
              const SizedBox(height: 10),
              Text(warning, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            if (!providerReady) ...[
              Text(
                _providerFixMessage(widget.providerStatus),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
            ],
            Align(
              alignment: Alignment.centerLeft,
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
                label: Text(busy ? 'Navigating' : 'Navigate Now'),
              ),
            ),
            if (widget.routeResult != null) ...[
              const SizedBox(height: 12),
              _ActiveRoutePanel(
                routeResult: widget.routeResult!,
                destinationLabel: widget.activeDestinationLabel,
              ),
            ],
            if (hasActiveRoute) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('status-reroute-active'),
                    onPressed: busy ? null : _rerouteActiveRoute,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reroute'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('status-clear-route'),
                    onPressed: busy ? null : _clearActiveRoute,
                    icon: const Icon(Icons.clear),
                    label: const Text('Clear Route'),
                  ),
                ],
              ),
            ],
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
                : null,
          ),
          textInputAction: draft.role == PlaceSearchRole.destination
              ? TextInputAction.go
              : TextInputAction.next,
          onSubmitted: draft.role == PlaceSearchRole.destination
              ? (_) => _navigateNow()
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

class _ActiveRoutePanel extends StatelessWidget {
  const _ActiveRoutePanel({
    required this.routeResult,
    required this.destinationLabel,
  });

  final RouteResult routeResult;
  final String? destinationLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final firstStep = routeResult.steps.isEmpty
        ? null
        : routeResult.steps.first;
    final title = routeResult.ok ? 'Active Route' : 'Route Problem';
    final destination = _firstNonBlankValue([
      destinationLabel,
      routeResult.formattedAddress,
      'Destination',
    ]);
    final detail = routeResult.ok
        ? routeResult.summaryLabel
        : _routeFixMessage(routeResult);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: routeResult.ok
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.32)
            : theme.colorScheme.errorContainer.withValues(alpha: 0.32),
        border: Border.all(
          color: routeResult.ok
              ? theme.colorScheme.primary.withValues(alpha: 0.28)
              : theme.colorScheme.error.withValues(alpha: 0.28),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  routeResult.ok
                      ? Icons.alt_route_outlined
                      : Icons.error_outline,
                  size: 20,
                  color: routeResult.ok
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
                const SizedBox(width: 10),
                Text(title, style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 8),
            Text(destination, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 2),
            Text(
              detail,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (firstStep != null && firstStep.instruction.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                firstStep.instruction,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
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

String _providerStatusDetail(ProviderStatus status) {
  final detail = status.validationDetail;
  if (detail == null || detail.trim().isEmpty) {
    return status.providerLabel;
  }
  return '${status.providerLabel}: ${detail.trim()}';
}

String _providerFixMessage(ProviderStatus status) {
  switch (status.validationState) {
    case ProviderValidationState.valid:
      return 'Provider setup is ready.';
    case ProviderValidationState.notConfigured:
      return 'Add a Google API key in Setup before navigation can use Google services.';
    case ProviderValidationState.notValidated:
    case ProviderValidationState.validating:
      return 'Validate the Google API key in Setup before starting navigation.';
    case ProviderValidationState.invalidKey:
      return 'Check that the value is a Google API key starting with AIza, not a URL, bearer token, or configuration document.';
    case ProviderValidationState.apiDisabled:
      return 'Enable Map Tiles, Places, Geocoding, and Routes APIs for this key in Google Cloud.';
    case ProviderValidationState.quotaOrBillingIssue:
      return 'Check Google Cloud billing, quota, and project limits for this key.';
    case ProviderValidationState.providerPermissionDenied:
      return 'Check the Android package and signing SHA-1 restrictions shown in Setup.';
    case ProviderValidationState.networkUnavailable:
      return 'Check the phone network connection, then validate the provider again.';
    case ProviderValidationState.unsupportedRestrictedKeyBehavior:
      return 'Restricted-key validation did not behave predictably. Keep Android restrictions enabled and fix the package/SHA-1 setup before release.';
    case ProviderValidationState.unknown:
      return status.validationDetail ??
          'Provider setup failed. Validate the key again from Setup.';
  }
}

String _locationFixMessage(LocationPermissionState state) {
  switch (state) {
    case LocationPermissionState.requestAvailable:
    case LocationPermissionState.denied:
      return 'Grant foreground location so the watch can receive live GPS.';
    case LocationPermissionState.permanentlyDenied:
      return 'Enable foreground location for Mappy in Android settings.';
    case LocationPermissionState.serviceDisabled:
      return 'Turn on Android location services, then refresh location.';
    case LocationPermissionState.unavailable:
      return 'This device is not reporting location availability.';
    case LocationPermissionState.unknown:
      return 'Refresh location to check whether live GPS is available.';
    case LocationPermissionState.grantedPrecise:
    case LocationPermissionState.grantedApproximate:
      return 'Allow all-the-time location in Android settings so Mappy can keep the active watch session updated.';
    case LocationPermissionState.grantedAlwaysPrecise:
    case LocationPermissionState.grantedAlwaysApproximate:
      return 'Location is ready.';
  }
}

String _notificationFixMessage(NotificationPermissionState state) {
  switch (state) {
    case NotificationPermissionState.requestAvailable:
    case NotificationPermissionState.denied:
      return 'Allow notifications so Android can show the watch-session foreground service.';
    case NotificationPermissionState.permanentlyDenied:
      return 'Enable notifications for Mappy in Android settings so the watch session remains visible.';
    case NotificationPermissionState.unavailable:
      return 'Android notification permission status is unavailable.';
    case NotificationPermissionState.unknown:
      return 'Refresh status to check watch-session notification readiness.';
    case NotificationPermissionState.granted:
    case NotificationPermissionState.notRequired:
      return 'Notifications are ready.';
  }
}

String _routeFixMessage(RouteResult routeResult) {
  final detail = routeResult.detail;
  if (detail != null && detail.trim().isNotEmpty) {
    return detail.trim();
  }
  switch (routeResult.errorCategory) {
    case 1:
      return 'Add and validate a Google API key before routing.';
    case 3:
      return 'Refresh location or choose a specific origin before routing.';
    case 6:
      return 'Fix the Google provider setup, then try navigation again.';
    case 7:
      return 'No route was found for that origin, destination, and travel mode.';
    default:
      return 'Navigation did not return a route.';
  }
}

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

String _savedLocationTimestampLabel(int? timestampMillis) {
  if (timestampMillis == null || timestampMillis <= 0) {
    return 'Not recorded';
  }
  final time = DateTime.fromMillisecondsSinceEpoch(timestampMillis).toLocal();
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${twoDigits(time.month)}-${twoDigits(time.day)} '
      '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
}

String _savedLocationGeocodeStatusLabel(String status) {
  return switch (status.trim().toLowerCase()) {
    'resolved' => 'Resolved',
    'geocoded' => 'Geocoded',
    'place_resolved' => 'Place resolved',
    'failed' => 'Failed',
    'pending' => 'Pending',
    _ => status.trim().isEmpty ? 'Resolved' : status.trim(),
  };
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
    this.detail,
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
  final Future<String> Function(WatchDestinationConfig config) onSave;
  final Future<String> Function(int slotIndex) onClear;

  @override
  State<SavedLocationsScreen> createState() => _SavedLocationsScreenState();
}

class _SavedLocationsScreenState extends State<SavedLocationsScreen> {
  final math.Random _random = math.Random();
  final TextEditingController _nameController = TextEditingController();
  late final _NavigatePlaceDraft _destination;
  late int _selectedSlot;
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
    _selectedSlot = _initialSelectedSlot();
    _loadSelectedSlot();
  }

  @override
  void didUpdateWidget(covariant SavedLocationsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
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
      ..detail = existing == null
          ? null
          : '${existing.latitude.toStringAsFixed(5)}, '
                '${existing.longitude.toStringAsFixed(5)}';
    _localMessage = null;
  }

  void _selectSlot(int slotIndex) {
    setState(() {
      _selectedSlot = slotIndex;
      _loadSelectedSlot();
    });
  }

  void _selectNewLocation() {
    final nextSlot = _nextAvailableSlot();
    if (nextSlot == null) {
      setState(() {
        _localMessage = 'Saved location limit reached.';
      });
      return;
    }
    _selectSlot(nextSlot);
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
      _destination.detail =
          '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';
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

  Future<void> _clearSelectedSlot() async {
    setState(() {
      _resolving = true;
      _localMessage = null;
    });
    final message = await widget.onClear(_selectedSlot);
    if (!mounted) {
      return;
    }
    setState(() {
      _resolving = false;
      _localMessage = message;
      _loadedSignature = _slotSignature(null);
      _updatingText = true;
      _nameController.text = savedLocationSlotTitle(_selectedSlot);
      _destination.controller.text = '';
      _updatingText = false;
      _destination
        ..debounce?.cancel()
        ..suggestions = const []
        ..selectedSuggestion = null
        ..sessionToken = _newSessionToken(_random)
        ..attribution = null
        ..detail = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _resolving || widget.isSaving || widget.isLoading;
    final savedDestinations = _enabledDestinations();
    final currentDestination = _destinationForSlot(_selectedSlot);
    final canClear = currentDestination != null && !busy;
    final canAdd = !busy && _nextAvailableSlot() != null;
    final canSave =
        widget.providerStatus.configured &&
        !busy &&
        (currentDestination != null ||
            savedDestinations.length < maxDestinationRecords);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.bookmarks_outlined,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Saved Locations',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      if (widget.isLoading)
                        const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
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
                    selected: destination.slotIndex == _selectedSlot,
                    destination: destination,
                    enabled: !busy,
                    onTap: () => _selectSlot(destination.slotIndex),
                  ),
                ListTile(
                  key: const ValueKey('saved-location-add'),
                  enabled: canAdd,
                  leading: const Icon(Icons.add_location_alt_outlined),
                  title: const Text('Add Location'),
                  subtitle: const Text('Create another watch shortcut.'),
                  selected: currentDestination == null,
                  selectedTileColor: theme.colorScheme.secondaryContainer
                      .withValues(alpha: 0.28),
                  onTap: canAdd ? _selectNewLocation : null,
                  trailing: StatusPill(
                    icon: canAdd ? Icons.add_circle_outline : Icons.block,
                    label: canAdd ? 'New' : 'Full',
                    tone: canAdd ? StatusTone.neutral : StatusTone.warning,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
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
                  enabled: !busy,
                  inputFormatters: const [_WatchDestinationLabelFormatter()],
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Display name',
                    prefixIcon: Icon(Icons.label_outline),
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                _placeField(context, busy: busy),
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
                  onSelectionChanged: busy
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
                    OutlinedButton.icon(
                      key: const ValueKey('saved-location-clear'),
                      onPressed: canClear ? _clearSelectedSlot : null,
                      icon: const Icon(Icons.clear),
                      label: const Text('Clear Location'),
                    ),
                  ],
                ),
                if (!widget.providerStatus.configured) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Provider key required before resolving destinations.',
                    style: theme.textTheme.bodySmall,
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
        ? [
            destination!.address,
            '${destination!.latitude.toStringAsFixed(5)}, '
                '${destination!.longitude.toStringAsFixed(5)}',
            '${_savedLocationGeocodeStatusLabel(destination!.geocodeStatus)}; updated '
                '${_savedLocationTimestampLabel(destination!.updatedAtMillis)}',
          ].join('\n')
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
      trailing: StatusPill(
        icon: configured ? Icons.check_circle_outline : Icons.radio_button_off,
        label: configured ? destination!.defaultTravelMode.label : 'Empty',
        tone: configured ? StatusTone.ok : StatusTone.neutral,
      ),
      selectedTileColor: theme.colorScheme.secondaryContainer.withValues(
        alpha: 0.28,
      ),
      onTap: enabled ? onTap : null,
    );
  }
}

class SetupScreen extends StatefulWidget {
  const SetupScreen({
    required this.providerStatus,
    required this.bridgeStatus,
    required this.permissionState,
    required this.location,
    required this.isValidatingProvider,
    required this.onStoreApiKey,
    required this.onValidateProvider,
    required this.onClearApiKey,
    super.key,
  });

  final ProviderStatus providerStatus;
  final BridgeStatus bridgeStatus;
  final LocationPermissionState permissionState;
  final LocationSnapshot? location;
  final bool isValidatingProvider;
  final Future<void> Function(String apiKey) onStoreApiKey;
  final Future<void> Function() onValidateProvider;
  final Future<void> Function() onClearApiKey;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final TextEditingController _apiKeyController = TextEditingController();
  String? _apiKeyMessage;

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _storeApiKey() async {
    final value = _apiKeyController.text.trim();
    String message;

    final validationError = googleApiKeyValidationError(value);
    if (validationError != null) {
      message = validationError;
    } else {
      setState(() {
        _apiKeyMessage = 'Storing key through Android secure storage.';
      });
      await widget.onStoreApiKey(value);
      _apiKeyController.clear();
      message = 'Stored. The app only shows redacted key status now.';
    }

    setState(() {
      _apiKeyMessage = message;
    });
  }

  Future<void> _copySetupValue(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label copied.')));
  }

  @override
  Widget build(BuildContext context) {
    final packageName =
        widget.providerStatus.packageName ?? 'com.leapwardkoex.mappy';
    final certSha1 = widget.providerStatus.certSha1;
    final locationLabel =
        widget.location?.coordinateLabel ?? widget.permissionState.label;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _StatusPanel(
          title: 'Google API Key',
          rows: [
            StatusRow(
              icon: widget.providerStatus.configured
                  ? Icons.key_outlined
                  : Icons.key_off_outlined,
              label: 'Stored key',
              value: widget.providerStatus.keyLabel,
            ),
            StatusRow(
              icon: Icons.cloud_outlined,
              label: 'Provider validation',
              value: widget.providerStatus.validationDetail == null
                  ? widget.providerStatus.providerLabel
                  : '${widget.providerStatus.providerLabel}: ${widget.providerStatus.validationDetail}',
            ),
            const StatusRow(
              icon: Icons.api_outlined,
              label: 'Required APIs',
              value: 'Map Tiles, Places, Geocoding, Routes',
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _apiKeyController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Google API key',
            helperText: 'Stored full keys must not be shown after submission.',
          ),
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: widget.isValidatingProvider ? null : _storeApiKey,
          icon: const Icon(Icons.check),
          label: Text(widget.isValidatingProvider ? 'Validating' : 'Save Key'),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    widget.providerStatus.configured &&
                        !widget.isValidatingProvider
                    ? widget.onValidateProvider
                    : null,
                icon: const Icon(Icons.cloud_sync_outlined),
                label: const Text('Validate Provider'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    widget.providerStatus.configured &&
                        !widget.isValidatingProvider
                    ? widget.onClearApiKey
                    : null,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Clear Key'),
              ),
            ),
          ],
        ),
        if (_apiKeyMessage != null) ...[
          const SizedBox(height: 12),
          Text(_apiKeyMessage!, style: Theme.of(context).textTheme.bodyMedium),
        ],
        if (!_providerReady(widget.providerStatus)) ...[
          const SizedBox(height: 12),
          Text(
            _providerFixMessage(widget.providerStatus),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
        const SizedBox(height: 16),
        _StatusPanel(
          title: 'App Setup',
          rows: [
            StatusRow(
              icon: Icons.android,
              label: 'Android package',
              value: packageName,
            ),
            StatusRow(
              icon: Icons.verified_user_outlined,
              label: 'Signing SHA-1',
              value: certSha1 ?? 'Waiting for Android',
            ),
            StatusRow(
              icon: Icons.watch_outlined,
              label: 'Watch bridge',
              value: widget.bridgeStatus.watchDetailLabel,
            ),
            StatusRow(
              icon: Icons.run_circle_outlined,
              label: 'Foreground service',
              value: widget.bridgeStatus.foregroundServiceLabel,
            ),
            StatusRow(
              icon: Icons.notifications_active_outlined,
              label: 'Notifications',
              value: widget.bridgeStatus.notificationPermissionState.label,
            ),
            StatusRow(
              icon: Icons.gps_fixed,
              label: 'Live GPS',
              value: widget.bridgeStatus.locationStreamLabel,
            ),
            StatusRow(
              icon: Icons.my_location,
              label: 'Location',
              value: locationLabel,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _copySetupValue('Package', packageName),
                icon: const Icon(Icons.copy),
                label: const Text('Copy Package'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: certSha1 == null
                    ? null
                    : () => _copySetupValue('SHA-1', certSha1),
                icon: const Icon(Icons.copy),
                label: const Text('Copy SHA-1'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Text(
          'Android-restricted keys need this package name and the active signing SHA-1. Provider calls must be performed by Android native code with package and certificate headers.',
        ),
      ],
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.settings,
    required this.displaySettings,
    required this.isSaving,
    required this.isSavingDisplaySettings,
    required this.onChanged,
    required this.onDisplaySettingsChanged,
    required this.onClearCache,
    this.detail,
    this.displaySettingsDetail,
    super.key,
  });

  final MapTileSettings settings;
  final WatchDisplaySettings displaySettings;
  final bool isSaving;
  final bool isSavingDisplaySettings;
  final String? detail;
  final String? displaySettingsDetail;
  final Future<void> Function(MapTileSettings settings) onChanged;
  final Future<void> Function(WatchDisplaySettings settings)
  onDisplaySettingsChanged;
  final Future<void> Function() onClearCache;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _StatusPanel(
          title: 'Display',
          rows: [
            StatusRow(
              icon: Icons.brightness_6_outlined,
              label: 'Theme',
              value: displaySettings.themeMode.label,
            ),
            StatusRow(
              icon: Icons.straighten_outlined,
              label: 'Units',
              value: displaySettings.unitsMode.label,
            ),
            StatusRow(
              icon: Icons.alt_route_outlined,
              label: 'Default travel mode',
              value: displaySettings.travelMode.label,
            ),
            StatusRow(
              icon: Icons.light_mode_outlined,
              label: 'Backlight',
              value: displaySettings.backlightMode.label,
            ),
            StatusRow(
              icon: Icons.explore_outlined,
              label: 'Map orientation',
              value: displaySettings.mapOrientation.label,
            ),
            StatusRow(
              icon: Icons.animation,
              label: 'Tile animation',
              value: displaySettings.tileAnimationMode.label,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _SegmentedSetting<WatchThemeMode>(
          title: 'Theme',
          icon: Icons.brightness_6_outlined,
          value: displaySettings.themeMode,
          enabled: !isSavingDisplaySettings,
          values: WatchThemeMode.values,
          labelFor: (value) => value.label,
          iconFor: (value) => switch (value) {
            WatchThemeMode.auto => Icons.brightness_auto_outlined,
            WatchThemeMode.day => Icons.light_mode_outlined,
            WatchThemeMode.night => Icons.dark_mode_outlined,
          },
          onChanged: (themeMode) => onDisplaySettingsChanged(
            displaySettings.copyWith(themeMode: themeMode),
          ),
        ),
        const SizedBox(height: 12),
        _SegmentedSetting<WatchUnitsMode>(
          title: 'Units',
          icon: Icons.straighten_outlined,
          value: displaySettings.unitsMode,
          enabled: !isSavingDisplaySettings,
          values: WatchUnitsMode.values,
          labelFor: (value) => value.label,
          iconFor: (value) => switch (value) {
            WatchUnitsMode.imperial => Icons.speed_outlined,
            WatchUnitsMode.metric => Icons.public_outlined,
          },
          onChanged: (unitsMode) => onDisplaySettingsChanged(
            displaySettings.copyWith(unitsMode: unitsMode),
          ),
        ),
        const SizedBox(height: 12),
        _SegmentedSetting<WatchTravelMode>(
          title: 'Default Travel Mode',
          icon: Icons.alt_route_outlined,
          value: displaySettings.travelMode,
          enabled: !isSavingDisplaySettings,
          values: const [
            WatchTravelMode.drive,
            WatchTravelMode.walk,
            WatchTravelMode.bike,
          ],
          labelFor: (value) => value.label,
          iconFor: (value) => switch (value) {
            WatchTravelMode.drive => Icons.directions_car_outlined,
            WatchTravelMode.walk => Icons.directions_walk,
            WatchTravelMode.bike => Icons.directions_bike,
          },
          onChanged: (travelMode) => onDisplaySettingsChanged(
            displaySettings.copyWith(travelMode: travelMode),
          ),
        ),
        if (displaySettings.travelMode != WatchTravelMode.drive) ...[
          const SizedBox(height: 8),
          Text(
            'Walk and bike routes may miss safe pedestrian or bicycling path detail.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 12),
        _SegmentedSetting<WatchBacklightMode>(
          title: 'Backlight',
          icon: Icons.light_mode_outlined,
          value: displaySettings.backlightMode,
          enabled: !isSavingDisplaySettings,
          values: WatchBacklightMode.values,
          labelFor: (value) => value.label,
          iconFor: (value) => switch (value) {
            WatchBacklightMode.system => Icons.settings_suggest_outlined,
            WatchBacklightMode.keepOn => Icons.highlight_outlined,
          },
          onChanged: (backlightMode) => onDisplaySettingsChanged(
            displaySettings.copyWith(backlightMode: backlightMode),
          ),
        ),
        const SizedBox(height: 12),
        _SegmentedSetting<WatchMapOrientation>(
          title: 'Map Orientation',
          icon: Icons.explore_outlined,
          value: displaySettings.mapOrientation,
          enabled: !isSavingDisplaySettings,
          values: WatchMapOrientation.values,
          labelFor: (value) => value.label,
          iconFor: (value) => switch (value) {
            WatchMapOrientation.northUp => Icons.north_outlined,
            WatchMapOrientation.forwardUp => Icons.navigation_outlined,
          },
          onChanged: (mapOrientation) => onDisplaySettingsChanged(
            displaySettings.copyWith(mapOrientation: mapOrientation),
          ),
        ),
        const SizedBox(height: 12),
        _SegmentedSetting<WatchTileAnimationMode>(
          title: 'Tile Animation',
          icon: Icons.animation,
          value: displaySettings.tileAnimationMode,
          enabled: !isSavingDisplaySettings,
          values: WatchTileAnimationMode.values,
          labelFor: (value) => value.label,
          iconFor: (value) => switch (value) {
            WatchTileAnimationMode.none => Icons.block,
            WatchTileAnimationMode.fadeIn => Icons.opacity,
            WatchTileAnimationMode.fadeZoom => Icons.zoom_out_map,
          },
          onChanged: (tileAnimationMode) => onDisplaySettingsChanged(
            displaySettings.copyWith(tileAnimationMode: tileAnimationMode),
          ),
        ),
        if (displaySettingsDetail != null) ...[
          const SizedBox(height: 12),
          Text(
            displaySettingsDetail!,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
        const SizedBox(height: 16),
        _StatusPanel(
          title: 'Map Tiles',
          rows: [
            StatusRow(
              icon: Icons.map_outlined,
              label: 'Source',
              value: settings.source.label,
            ),
            StatusRow(
              icon: Icons.grid_on_outlined,
              label: 'Rendered tile',
              value: settings.tileSize.label,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _SegmentedSetting<MapTileSource>(
          title: 'Source',
          icon: Icons.map_outlined,
          value: settings.source,
          enabled: !isSaving,
          values: MapTileSource.values,
          labelFor: (value) => value.label,
          iconFor: (value) => switch (value) {
            MapTileSource.roadmap => Icons.route_outlined,
            MapTileSource.satellite => Icons.satellite_alt_outlined,
            MapTileSource.hybrid => Icons.layers_outlined,
            MapTileSource.terrain => Icons.terrain_outlined,
          },
          onChanged: (source) => onChanged(settings.copyWith(source: source)),
        ),
        const SizedBox(height: 12),
        _SegmentedSetting<WatchTileSize>(
          title: 'Rendered Tile',
          icon: Icons.grid_on_outlined,
          value: settings.tileSize,
          enabled: !isSaving,
          values: WatchTileSize.values,
          labelFor: (value) => value.label,
          iconFor: (value) => switch (value) {
            WatchTileSize.small => Icons.grid_4x4_outlined,
            WatchTileSize.medium => Icons.grid_view_outlined,
            WatchTileSize.large => Icons.grid_on_outlined,
          },
          onChanged: (tileSize) =>
              onChanged(settings.copyWith(tileSize: tileSize)),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: isSaving ? null : onClearCache,
          icon: const Icon(Icons.delete_sweep_outlined),
          label: const Text('Clear Tile Cache'),
        ),
        if (detail != null) ...[
          const SizedBox(height: 12),
          Text(detail!, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ],
    );
  }
}

class _SegmentedSetting<T> extends StatelessWidget {
  const _SegmentedSetting({
    required this.title,
    required this.icon,
    required this.value,
    required this.values,
    required this.enabled,
    required this.labelFor,
    required this.iconFor,
    required this.onChanged,
  });

  final String title;
  final IconData icon;
  final T value;
  final List<T> values;
  final bool enabled;
  final String Function(T value) labelFor;
  final IconData Function(T value) iconFor;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Text(title, style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<T>(
                showSelectedIcon: false,
                segments: [
                  for (final option in values)
                    ButtonSegment<T>(
                      value: option,
                      icon: Icon(iconFor(option)),
                      label: Text(labelFor(option)),
                    ),
                ],
                selected: {value},
                onSelectionChanged: (selection) {
                  final selected = selection.single;
                  if (!enabled || selected == value) {
                    return;
                  }
                  onChanged(selected);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({
    required this.events,
    required this.isClearingDiagnostics,
    required this.onExportDiagnostics,
    required this.onClearDiagnostics,
    required this.isClearingTileCache,
    required this.onClearTileCache,
    required this.isClearingRouteCache,
    required this.onClearRouteCache,
    required this.isClearingProviderValidationCache,
    required this.onClearProviderValidationCache,
    super.key,
  });

  final List<String> events;
  final bool isClearingDiagnostics;
  final Future<void> Function() onExportDiagnostics;
  final Future<void> Function() onClearDiagnostics;
  final bool isClearingTileCache;
  final Future<void> Function() onClearTileCache;
  final bool isClearingRouteCache;
  final Future<void> Function() onClearRouteCache;
  final bool isClearingProviderValidationCache;
  final Future<void> Function() onClearProviderValidationCache;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _StatusPanel(
          title: 'Recent Events',
          rows: [
            StatusRow(
              icon: events.isEmpty
                  ? Icons.info_outline
                  : Icons.receipt_long_outlined,
              label: 'Log',
              value: events.isEmpty
                  ? 'No diagnostics yet'
                  : events.take(8).join('\n'),
            ),
            const StatusRow(
              icon: Icons.privacy_tip_outlined,
              label: 'Redaction',
              value: 'Credential text must be redacted on export',
            ),
          ],
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onExportDiagnostics,
          icon: const Icon(Icons.ios_share),
          label: const Text('Export Diagnostics'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: isClearingDiagnostics ? null : onClearDiagnostics,
          icon: const Icon(Icons.delete_outline),
          label: Text(
            isClearingDiagnostics
                ? 'Clearing Diagnostics'
                : 'Clear Diagnostics',
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: isClearingTileCache ? null : onClearTileCache,
          icon: const Icon(Icons.delete_sweep_outlined),
          label: Text(
            isClearingTileCache ? 'Clearing Tile Cache' : 'Clear Tile Cache',
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: isClearingRouteCache ? null : onClearRouteCache,
          icon: const Icon(Icons.route_outlined),
          label: Text(
            isClearingRouteCache ? 'Clearing Route Cache' : 'Clear Route Cache',
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: isClearingProviderValidationCache
              ? null
              : onClearProviderValidationCache,
          icon: const Icon(Icons.verified_user_outlined),
          label: Text(
            isClearingProviderValidationCache
                ? 'Clearing Provider Validation'
                : 'Clear Provider Validation',
          ),
        ),
      ],
    );
  }
}

class _LocationAction {
  const _LocationAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
}

enum StatusTone { ok, warning, neutral }

class StatusPill extends StatelessWidget {
  const StatusPill({
    required this.icon,
    required this.label,
    required this.tone,
    super.key,
  });

  final IconData icon;
  final String label;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (background, foreground) = switch (tone) {
      StatusTone.ok => (const Color(0xFFE0F1E7), const Color(0xFF135D36)),
      StatusTone.warning => (const Color(0xFFFFF0C2), const Color(0xFF715000)),
      StatusTone.neutral => (
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurfaceVariant,
      ),
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 8),
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(color: foreground),
            ),
          ],
        ),
      ),
    );
  }
}

class StatusRow {
  const StatusRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.title, required this.rows});

  final String title;
  final List<StatusRow> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(row.icon, size: 20, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(row.label, style: theme.textTheme.labelLarge),
                          const SizedBox(height: 2),
                          Text(
                            row.value,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
