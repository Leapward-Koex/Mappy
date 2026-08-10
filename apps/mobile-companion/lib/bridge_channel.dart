import 'dart:async';

import 'package:flutter/services.dart';

import 'location_bridge.dart';
import 'provider_bridge.dart';

enum BridgeSetupState { ready, providerRequired, locationRequired, unavailable }

enum NotificationPermissionState {
  unknown,
  granted,
  requestAvailable,
  denied,
  permanentlyDenied,
  notRequired,
  unavailable,
}

extension NotificationPermissionStateDisplay on NotificationPermissionState {
  bool get allowsWatchNotification =>
      this == NotificationPermissionState.granted ||
      this == NotificationPermissionState.notRequired;

  bool get canRequest =>
      this == NotificationPermissionState.requestAvailable ||
      this == NotificationPermissionState.denied;

  String get label {
    switch (this) {
      case NotificationPermissionState.unknown:
        return 'Unknown';
      case NotificationPermissionState.granted:
        return 'Granted';
      case NotificationPermissionState.requestAvailable:
        return 'Request available';
      case NotificationPermissionState.denied:
        return 'Denied';
      case NotificationPermissionState.permanentlyDenied:
        return 'System settings required';
      case NotificationPermissionState.notRequired:
        return 'Not required';
      case NotificationPermissionState.unavailable:
        return 'Unavailable';
    }
  }
}

class BridgeLocationStreamStatus {
  const BridgeLocationStreamStatus({
    required this.requested,
    required this.streaming,
    required this.providers,
    required this.permissionState,
    required this.headingAvailable,
    this.lastFixAge,
    required this.lastFixFresh,
  });

  const BridgeLocationStreamStatus.unavailable()
    : requested = false,
      streaming = false,
      providers = const [],
      permissionState = LocationPermissionState.unavailable,
      headingAvailable = false,
      lastFixAge = null,
      lastFixFresh = false;

  final bool requested;
  final bool streaming;
  final List<String> providers;
  final LocationPermissionState permissionState;
  final bool headingAvailable;
  final Duration? lastFixAge;
  final bool lastFixFresh;

  String get label {
    if (streaming) {
      final providerLabel = providers.isEmpty
          ? ''
          : ' (${providers.join(', ')})';
      return 'Streaming$providerLabel';
    }
    if (requested) {
      return 'Waiting for GPS';
    }
    return 'Not started';
  }

  static BridgeLocationStreamStatus fromMethodChannel(Object? raw) {
    if (raw is! Map) {
      return const BridgeLocationStreamStatus.unavailable();
    }
    final data = Map<Object?, Object?>.from(raw);
    final lastFixAgeMillis = _asInt(data['lastFixAgeMillis']);
    return BridgeLocationStreamStatus(
      requested: _asBool(data['requested']) ?? false,
      streaming: _asBool(data['streaming']) ?? false,
      providers: _stringList(data['providers']),
      permissionState: BridgeStatus._permissionStateFromName(
        data['permissionState'] as String?,
      ),
      headingAvailable: _asBool(data['headingAvailable']) ?? false,
      lastFixAge: lastFixAgeMillis == null
          ? null
          : Duration(milliseconds: lastFixAgeMillis),
      lastFixFresh: _asBool(data['lastFixFresh']) ?? false,
    );
  }

  static bool? _asBool(Object? value) {
    if (value is bool) {
      return value;
    }
    if (value is int) {
      return value != 0;
    }
    return null;
  }

  static int? _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is double && value.isFinite) {
      return value.toInt();
    }
    return null;
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) {
      return const [];
    }
    return value.map((item) => item.toString()).toList(growable: false);
  }
}

class ShareRoutingStatus {
  const ShareRoutingStatus({
    required this.state,
    this.shareType,
    this.safeHost,
    this.redirectHopCount,
    this.explicitOrigin = false,
    this.destinationHasCoordinates = false,
    this.travelMode,
    this.originLabel,
    this.destinationLabel,
    this.detail,
    this.errorCategory,
    this.distanceMeters,
    this.durationSeconds,
    this.routeWarning,
    this.timestamp,
  });

  final String state;
  final String? shareType;
  final String? safeHost;
  final int? redirectHopCount;
  final bool explicitOrigin;
  final bool destinationHasCoordinates;
  final String? travelMode;
  final String? originLabel;
  final String? destinationLabel;
  final String? detail;
  final int? errorCategory;
  final int? distanceMeters;
  final int? durationSeconds;
  final String? routeWarning;
  final DateTime? timestamp;

  bool get isActiveRoute => state == 'activeRoute';

  bool get isTerminal =>
      state == 'activeRoute' ||
      state == 'unsupported' ||
      state == 'noRoute' ||
      state == 'error';

  String get title {
    switch (state) {
      case 'parsing':
        return 'Parsing Share';
      case 'resolvingShortLink':
        return 'Resolving Link';
      case 'resolvingEndpoint':
        return 'Resolving Shared Place';
      case 'routeLoading':
        return 'Starting Shared Route';
      case 'activeRoute':
        return shareType == 'route'
            ? 'Shared Route Active'
            : 'Shared Location Active';
      case 'noRoute':
        return 'No Shared Route';
      case 'unsupported':
        return 'Unsupported Share';
      case 'error':
        return 'Share Route Problem';
      default:
        return 'Google Maps Share';
    }
  }

  String get subtitle =>
      detail ??
      switch (state) {
        'activeRoute' => 'Shared route sent to the watch.',
        'unsupported' => 'This share is not supported.',
        'noRoute' => 'No route was found.',
        'error' => 'The shared route could not be started.',
        _ => 'Working on the shared Google Maps item.',
      };

  String? get routeSummary {
    final meters = distanceMeters;
    final seconds = durationSeconds;
    if (meters == null && seconds == null) {
      return null;
    }
    final distance = meters == null ? null : _formatDistance(meters);
    final duration = seconds == null ? null : _formatDuration(seconds);
    return [distance, duration].nonNulls.join(' - ');
  }

  static ShareRoutingStatus? fromEventChannel(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final data = Map<Object?, Object?>.from(raw);
    final state = data['state'] as String?;
    if (state == null || state.isEmpty) {
      return null;
    }
    final timestampMillis = BridgeStatus._asInt(data['timestampMillis']);
    return ShareRoutingStatus(
      state: state,
      shareType: data['shareType'] as String?,
      safeHost: data['safeHost'] as String?,
      redirectHopCount: BridgeStatus._asInt(data['redirectHopCount']),
      explicitOrigin: BridgeStatus._asBool(data['explicitOrigin']) ?? false,
      destinationHasCoordinates:
          BridgeStatus._asBool(data['destinationHasCoordinates']) ?? false,
      travelMode: data['travelMode'] as String?,
      originLabel: data['originLabel'] as String?,
      destinationLabel: data['destinationLabel'] as String?,
      detail: data['detail'] as String?,
      errorCategory: BridgeStatus._asInt(data['errorCategory']),
      distanceMeters: BridgeStatus._asInt(data['distanceMeters']),
      durationSeconds: BridgeStatus._asInt(data['durationSeconds']),
      routeWarning: data['routeWarning'] as String?,
      timestamp: timestampMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(timestampMillis),
    );
  }

  static String _formatDistance(int meters) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }
    return '$meters m';
  }

  static String _formatDuration(int seconds) {
    final minutes = (seconds / 60).round();
    if (minutes < 60) {
      return '$minutes min';
    }
    final hours = minutes ~/ 60;
    final remainder = minutes % 60;
    return remainder == 0 ? '$hours hr' : '$hours hr $remainder min';
  }
}

extension BridgeSetupStateDisplay on BridgeSetupState {
  String get label {
    switch (this) {
      case BridgeSetupState.ready:
        return 'Ready';
      case BridgeSetupState.providerRequired:
        return 'Provider required';
      case BridgeSetupState.locationRequired:
        return 'Location required';
      case BridgeSetupState.unavailable:
        return 'Unavailable';
    }
  }
}

class BridgeStatus {
  const BridgeStatus({
    required this.registered,
    required this.watchReady,
    required this.watchConnected,
    required this.watchAppActive,
    required this.foregroundServiceActive,
    required this.queueLength,
    required this.inFlight,
    required this.setupState,
    required this.permissionState,
    required this.notificationPermissionState,
    required this.providerStatus,
    this.diagnosticCount = 0,
    this.foregroundServiceLastError,
    this.gpsStreamRequested = false,
    this.gpsStreaming = false,
    this.gpsStreamProviders = const [],
    this.lastGpsFixAge,
    this.lastGpsFixFresh = false,
  });

  const BridgeStatus.unavailable()
    : registered = false,
      watchReady = false,
      watchConnected = false,
      watchAppActive = false,
      foregroundServiceActive = false,
      queueLength = 0,
      inFlight = false,
      setupState = BridgeSetupState.unavailable,
      permissionState = LocationPermissionState.unavailable,
      notificationPermissionState = NotificationPermissionState.unavailable,
      providerStatus = const ProviderStatus.notConfigured(),
      diagnosticCount = 0,
      foregroundServiceLastError = null,
      gpsStreamRequested = false,
      gpsStreaming = false,
      gpsStreamProviders = const [],
      lastGpsFixAge = null,
      lastGpsFixFresh = false;

  final bool registered;
  final bool watchReady;
  final bool watchConnected;
  final bool watchAppActive;
  final bool foregroundServiceActive;
  final int queueLength;
  final bool inFlight;
  final BridgeSetupState setupState;
  final LocationPermissionState permissionState;
  final NotificationPermissionState notificationPermissionState;
  final ProviderStatus providerStatus;
  final int diagnosticCount;
  final String? foregroundServiceLastError;
  final bool gpsStreamRequested;
  final bool gpsStreaming;
  final List<String> gpsStreamProviders;
  final Duration? lastGpsFixAge;
  final bool lastGpsFixFresh;

  String get watchLabel {
    if (watchReady) {
      return 'Watch ready';
    }
    if (watchConnected) {
      return 'Watch connected';
    }
    return 'No watch';
  }

  String get watchDetailLabel {
    if (!registered) {
      return 'Bridge unavailable';
    }
    if (watchReady) {
      return inFlight ? 'Ready, sending' : 'Ready';
    }
    if (watchConnected) {
      return 'Connected, waiting for app';
    }
    return 'No Pebble connection';
  }

  String get foregroundServiceLabel {
    final lastError = foregroundServiceLastError;
    if (foregroundServiceActive) {
      return 'Watch session active';
    }
    if (lastError != null && lastError.trim().isNotEmpty) {
      return lastError.trim();
    }
    return watchAppActive ? 'Starting watch session' : 'Waiting for watch';
  }

  String get locationStreamLabel {
    if (gpsStreaming) {
      final providerLabel = gpsStreamProviders.isEmpty
          ? ''
          : ' (${gpsStreamProviders.join(', ')})';
      return 'Streaming$providerLabel';
    }
    if (gpsStreamRequested) {
      return 'Waiting for GPS';
    }
    return 'Not started';
  }

  BridgeStatus copyWith({
    bool? registered,
    bool? watchReady,
    bool? watchConnected,
    bool? watchAppActive,
    bool? foregroundServiceActive,
    int? queueLength,
    bool? inFlight,
    BridgeSetupState? setupState,
    LocationPermissionState? permissionState,
    NotificationPermissionState? notificationPermissionState,
    ProviderStatus? providerStatus,
    int? diagnosticCount,
    String? foregroundServiceLastError,
    BridgeLocationStreamStatus? locationStream,
  }) {
    return BridgeStatus(
      registered: registered ?? this.registered,
      watchReady: watchReady ?? this.watchReady,
      watchConnected: watchConnected ?? this.watchConnected,
      watchAppActive: watchAppActive ?? this.watchAppActive,
      foregroundServiceActive:
          foregroundServiceActive ?? this.foregroundServiceActive,
      queueLength: queueLength ?? this.queueLength,
      inFlight: inFlight ?? this.inFlight,
      setupState: setupState ?? this.setupState,
      permissionState:
          permissionState ??
          locationStream?.permissionState ??
          this.permissionState,
      notificationPermissionState:
          notificationPermissionState ?? this.notificationPermissionState,
      providerStatus: providerStatus ?? this.providerStatus,
      diagnosticCount: diagnosticCount ?? this.diagnosticCount,
      foregroundServiceLastError:
          foregroundServiceLastError ?? this.foregroundServiceLastError,
      gpsStreamRequested: locationStream?.requested ?? gpsStreamRequested,
      gpsStreaming: locationStream?.streaming ?? gpsStreaming,
      gpsStreamProviders: locationStream?.providers ?? gpsStreamProviders,
      lastGpsFixAge: locationStream?.lastFixAge ?? lastGpsFixAge,
      lastGpsFixFresh: locationStream?.lastFixFresh ?? lastGpsFixFresh,
    );
  }

  static BridgeStatus fromMethodChannel(Object? raw) {
    if (raw is! Map) {
      return const BridgeStatus.unavailable();
    }

    final data = Map<Object?, Object?>.from(raw);
    final watch = data['watch'] is Map
        ? Map<Object?, Object?>.from(data['watch'] as Map)
        : const <Object?, Object?>{};
    final locationStream = data['locationStream'] is Map
        ? Map<Object?, Object?>.from(data['locationStream'] as Map)
        : const <Object?, Object?>{};
    final lastFixAgeMillis = _asInt(locationStream['lastFixAgeMillis']);

    return BridgeStatus(
      registered:
          _asBool(data['registered']) ?? _asBool(watch['registered']) ?? false,
      watchReady:
          _asBool(data['watchReady']) ?? _asBool(watch['watchReady']) ?? false,
      watchConnected:
          _asBool(data['watchConnected']) ??
          _asBool(watch['watchConnected']) ??
          false,
      watchAppActive:
          _asBool(data['watchAppActive']) ??
          _asBool(watch['watchAppActive']) ??
          false,
      foregroundServiceActive:
          _asBool(data['foregroundServiceActive']) ?? false,
      queueLength:
          _asInt(data['queueLength']) ?? _asInt(watch['queueLength']) ?? 0,
      inFlight:
          _asBool(data['inFlight']) ?? _asBool(watch['inFlight']) ?? false,
      setupState: _setupStateFromName(data['setupState'] as String?),
      permissionState: _permissionStateFromName(
        data['permissionState'] as String?,
      ),
      notificationPermissionState: _notificationPermissionStateFromName(
        data['notificationPermissionState'] as String?,
      ),
      providerStatus: ProviderStatus.fromMethodChannel(data['providerStatus']),
      diagnosticCount: _asInt(data['diagnosticCount']) ?? 0,
      foregroundServiceLastError: data['foregroundServiceLastError'] as String?,
      gpsStreamRequested: _asBool(locationStream['requested']) ?? false,
      gpsStreaming: _asBool(locationStream['streaming']) ?? false,
      gpsStreamProviders: _stringList(locationStream['providers']),
      lastGpsFixAge: lastFixAgeMillis == null
          ? null
          : Duration(milliseconds: lastFixAgeMillis),
      lastGpsFixFresh: _asBool(locationStream['lastFixFresh']) ?? false,
    );
  }

  static bool? _asBool(Object? value) {
    if (value is bool) {
      return value;
    }
    if (value is int) {
      return value != 0;
    }
    return null;
  }

  static int? _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is double && value.isFinite) {
      return value.toInt();
    }
    return null;
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) {
      return const [];
    }
    return value.map((item) => item.toString()).toList(growable: false);
  }

  static BridgeSetupState _setupStateFromName(String? name) {
    switch (name) {
      case 'ready':
        return BridgeSetupState.ready;
      case 'providerRequired':
        return BridgeSetupState.providerRequired;
      case 'locationRequired':
        return BridgeSetupState.locationRequired;
      case 'unavailable':
        return BridgeSetupState.unavailable;
      default:
        return BridgeSetupState.unavailable;
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

  static NotificationPermissionState _notificationPermissionStateFromName(
    String? name,
  ) {
    switch (name) {
      case 'granted':
        return NotificationPermissionState.granted;
      case 'requestAvailable':
        return NotificationPermissionState.requestAvailable;
      case 'denied':
        return NotificationPermissionState.denied;
      case 'permanentlyDenied':
        return NotificationPermissionState.permanentlyDenied;
      case 'notRequired':
        return NotificationPermissionState.notRequired;
      case 'unavailable':
        return NotificationPermissionState.unavailable;
      default:
        return NotificationPermissionState.unknown;
    }
  }
}

class BridgeEvent {
  const BridgeEvent({
    required this.type,
    this.status,
    this.providerStatus,
    this.locationStream,
    this.shareStatus,
    this.command,
    this.result,
    this.transactionId,
    this.reason,
    this.eventId,
    this.severity,
    this.source,
    this.message,
    this.category,
    this.failedCommand,
    this.detail,
    this.droppable,
    this.timestamp,
  });

  final String type;
  final BridgeStatus? status;
  final ProviderStatus? providerStatus;
  final BridgeLocationStreamStatus? locationStream;
  final ShareRoutingStatus? shareStatus;
  final int? command;
  final String? result;
  final int? transactionId;
  final String? reason;
  final String? eventId;
  final String? severity;
  final String? source;
  final String? message;
  final int? category;
  final int? failedCommand;
  final String? detail;
  final bool? droppable;
  final DateTime? timestamp;

  static BridgeEvent fromEventChannel(Object? raw) {
    if (raw is! Map) {
      return const BridgeEvent(type: 'unknown');
    }

    final data = Map<Object?, Object?>.from(raw);
    final type = data['event'] as String? ?? 'unknown';
    final timestampMillis = BridgeStatus._asInt(data['timestampMillis']);

    return BridgeEvent(
      type: type,
      status: type == 'bridgeStatus'
          ? BridgeStatus.fromMethodChannel(data)
          : null,
      providerStatus: data.containsKey('providerStatus')
          ? ProviderStatus.fromMethodChannel(data['providerStatus'])
          : null,
      locationStream: data.containsKey('locationStream')
          ? BridgeLocationStreamStatus.fromMethodChannel(data['locationStream'])
          : null,
      shareStatus: type == 'shareStatus'
          ? ShareRoutingStatus.fromEventChannel(data)
          : null,
      command: BridgeStatus._asInt(data['command']),
      result: data['result'] as String?,
      transactionId: BridgeStatus._asInt(data['transactionId']),
      reason: data['reason'] as String?,
      eventId: data['eventId'] as String?,
      severity: data['severity'] as String?,
      source: data['source'] as String?,
      message: data['message'] as String?,
      category: BridgeStatus._asInt(data['category']),
      failedCommand: BridgeStatus._asInt(data['failedCommand']),
      detail: data['detail'] as String?,
      droppable: BridgeStatus._asBool(data['droppable']),
      timestamp: timestampMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(timestampMillis),
    );
  }
}

abstract class BridgeRepository {
  Future<BridgeStatus> getBridgeStatus();

  Future<BridgeStatus> startWatchApp();

  Future<BridgeStatus> requestNotificationPermission();

  Future<Map<String, Object?>> exportDiagnostics();

  Future<void> clearDiagnostics();

  Stream<BridgeEvent> get events;
}

class NativeBridgeRepository implements BridgeRepository {
  const NativeBridgeRepository();

  static const MethodChannel _methodChannel = MethodChannel(
    'app.mappy.bridge/methods',
  );
  static const EventChannel _eventChannel = EventChannel(
    'app.mappy.bridge/events',
  );

  @override
  Future<BridgeStatus> getBridgeStatus() async {
    try {
      final result = await _methodChannel.invokeMethod<Object?>(
        'getBridgeStatus',
      );
      return BridgeStatus.fromMethodChannel(result);
    } on MissingPluginException {
      return const BridgeStatus.unavailable();
    } on PlatformException {
      return const BridgeStatus.unavailable();
    }
  }

  @override
  Future<BridgeStatus> startWatchApp() async {
    try {
      final result = await _methodChannel.invokeMethod<Object?>(
        'startWatchApp',
      );
      return BridgeStatus.fromMethodChannel(result);
    } on MissingPluginException {
      return const BridgeStatus.unavailable();
    } on PlatformException {
      return const BridgeStatus.unavailable();
    }
  }

  @override
  Future<BridgeStatus> requestNotificationPermission() async {
    try {
      final result = await _methodChannel.invokeMethod<Object?>(
        'requestNotificationPermission',
      );
      return BridgeStatus.fromMethodChannel(result);
    } on MissingPluginException {
      return const BridgeStatus.unavailable();
    } on PlatformException {
      return const BridgeStatus.unavailable();
    }
  }

  @override
  Future<Map<String, Object?>> exportDiagnostics() async {
    try {
      final result = await _methodChannel.invokeMethod<Object?>(
        'exportDiagnostics',
      );
      return _diagnosticExportFromMethodChannel(result);
    } on MissingPluginException {
      return _emptyDiagnosticExport();
    } on PlatformException {
      return _emptyDiagnosticExport();
    }
  }

  @override
  Future<void> clearDiagnostics() async {
    try {
      await _methodChannel.invokeMethod<Object?>('clearDiagnostics');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  @override
  Stream<BridgeEvent> get events =>
      _eventChannel.receiveBroadcastStream().map(BridgeEvent.fromEventChannel);

  static Map<String, Object?> _diagnosticExportFromMethodChannel(
    Object? result,
  ) {
    final normalized = _jsonSafe(result);
    if (normalized is Map<String, Object?>) {
      return normalized;
    }
    if (normalized is List<Object?>) {
      return _diagnosticExportEnvelope(normalized);
    }
    return _emptyDiagnosticExport();
  }

  static Map<String, Object?> _emptyDiagnosticExport() =>
      _diagnosticExportEnvelope(const []);

  static Map<String, Object?> _diagnosticExportEnvelope(List<Object?> events) {
    return {
      'schema_version': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'app_package': 'com.leapwardkoex.mappy',
      'app_version': 'unknown',
      'watch_uuid': '18b376dc-40ef-464f-abfb-b1612ea94f7d',
      'redaction': {'full_keys': 'redacted', 'location': 'default'},
      'status': <String, Object?>{},
      'events': events,
    };
  }

  static Object? _jsonSafe(Object? value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _jsonSafe(entry.value),
      };
    }
    if (value is Iterable) {
      return value.map(_jsonSafe).toList(growable: false);
    }
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    return value.toString();
  }
}
