import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mappy/bridge_channel.dart';
import 'package:mappy/location_bridge.dart';
import 'package:mappy/provider_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const bridgeMethodChannel = MethodChannel('app.mappy.bridge/methods');
  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(bridgeMethodChannel, null);
  });

  test('setup checklist version accepts only nonnegative integers', () async {
    Object? response = 3;
    final calls = <MethodCall>[];
    binaryMessenger.setMockMethodCallHandler(bridgeMethodChannel, (call) async {
      calls.add(call);
      return response;
    });
    const repository = NativeBridgeRepository();

    expect(await repository.getSetupChecklistVersion(), 3);
    expect(calls.single.method, 'getSetupChecklistVersion');
    expect(calls.single.arguments, isNull);

    for (final malformed in <Object?>[-1, 1.0, '1', true, null]) {
      response = malformed;
      expect(
        await repository.getSetupChecklistVersion(),
        0,
        reason: 'Rejected $malformed (${malformed.runtimeType})',
      );
    }
  });

  test('setup checklist version sends a validated version map', () async {
    final calls = <MethodCall>[];
    Object? response = true;
    binaryMessenger.setMockMethodCallHandler(bridgeMethodChannel, (call) async {
      calls.add(call);
      return response;
    });
    const repository = NativeBridgeRepository();

    expect(await repository.setSetupChecklistVersion(2), isTrue);
    expect(calls.single.method, 'setSetupChecklistVersion');
    expect(calls.single.arguments, <String, Object?>{'version': 2});

    response = 1;
    expect(await repository.setSetupChecklistVersion(0), isFalse);
    expect(calls, hasLength(2));

    expect(await repository.setSetupChecklistVersion(-1), isFalse);
    expect(calls, hasLength(2), reason: 'Negative versions stay local.');
  });

  test(
    'setup checklist version safely handles missing native methods',
    () async {
      binaryMessenger.setMockMethodCallHandler(bridgeMethodChannel, (
        call,
      ) async {
        throw MissingPluginException('Not implemented: ${call.method}');
      });
      const repository = NativeBridgeRepository();

      expect(await repository.getSetupChecklistVersion(), 0);
      expect(await repository.setSetupChecklistVersion(1), isFalse);
    },
  );

  test('setup checklist version safely handles platform failures', () async {
    binaryMessenger.setMockMethodCallHandler(bridgeMethodChannel, (call) async {
      throw PlatformException(code: 'storage_failed');
    });
    const repository = NativeBridgeRepository();

    expect(await repository.getSetupChecklistVersion(), 0);
    expect(await repository.setSetupChecklistVersion(1), isFalse);
  });

  test('BridgeStatus parses live GPS stream state', () {
    final status = BridgeStatus.fromMethodChannel({
      'registered': true,
      'watchReady': true,
      'watchConnected': true,
      'watchAppActive': true,
      'watchLaunchPending': false,
      'foregroundServiceActive': true,
      'notificationPermissionState': 'granted',
      'queueLength': 0,
      'inFlight': false,
      'setupState': 'ready',
      'permissionState': 'grantedPrecise',
      'locationAccessStatus': {
        'servicesEnabled': true,
        'foregroundState': 'precise',
        'backgroundRequired': true,
        'backgroundGranted': false,
      },
      'providerStatus': {'configured': true, 'validationState': 'valid'},
      'diagnosticCount': 3,
      'locationStream': {
        'requested': true,
        'streaming': true,
        'providers': ['gps', 'network'],
        'permissionState': 'grantedPrecise',
        'headingAvailable': true,
        'lastFixAgeMillis': 2300,
        'lastFixFresh': true,
      },
    });

    expect(status.watchReady, isTrue);
    expect(status.watchAppActive, isTrue);
    expect(status.watchLaunchPending, isFalse);
    expect(status.foregroundServiceActive, isTrue);
    expect(status.foregroundServiceLabel, 'Watch session active');
    expect(
      status.notificationPermissionState,
      NotificationPermissionState.granted,
    );
    expect(status.permissionState, LocationPermissionState.grantedPrecise);
    expect(status.locationAccessStatus.servicesEnabled, isTrue);
    expect(
      status.locationAccessStatus.foregroundState,
      ForegroundLocationState.precise,
    );
    expect(status.locationAccessStatus.backgroundReady, isFalse);
    expect(status.gpsStreamRequested, isTrue);
    expect(status.gpsStreaming, isTrue);
    expect(status.gpsStreamProviders, ['gps', 'network']);
    expect(status.diagnosticCount, 3);
    expect(status.lastGpsFixAge, const Duration(milliseconds: 2300));
    expect(status.lastGpsFixFresh, isTrue);
    expect(status.locationStreamLabel, 'Streaming (gps, network)');
  });

  test(
    'BridgeEvent parses provider, location, diagnostic, and delivery events',
    () {
      final providerEvent = BridgeEvent.fromEventChannel({
        'event': 'providerStatus',
        'providerStatus': {'configured': true, 'validationState': 'valid'},
      });
      expect(providerEvent.type, 'providerStatus');
      expect(
        providerEvent.providerStatus?.validationState,
        ProviderValidationState.valid,
      );

      final locationEvent = BridgeEvent.fromEventChannel({
        'event': 'locationStatus',
        'locationAccessStatus': {
          'servicesEnabled': false,
          'foregroundState': 'approximate',
          'backgroundRequired': true,
          'backgroundGranted': false,
        },
        'locationStream': {
          'requested': true,
          'streaming': false,
          'providers': <String>[],
          'permissionState': 'grantedApproximate',
          'headingAvailable': false,
          'lastFixFresh': false,
        },
      });
      expect(locationEvent.locationStream?.requested, isTrue);
      expect(locationEvent.locationStream?.label, 'Waiting for GPS');
      expect(
        locationEvent.locationStream?.permissionState,
        LocationPermissionState.grantedApproximate,
      );
      expect(locationEvent.locationStream?.headingAvailable, isFalse);
      expect(locationEvent.locationAccessStatus?.servicesEnabled, isFalse);
      expect(
        locationEvent.locationAccessStatus?.foregroundState,
        ForegroundLocationState.approximate,
      );

      final diagnosticEvent = BridgeEvent.fromEventChannel({
        'event': 'diagnosticEvent',
        'eventId': 'native-1',
        'severity': 'error',
        'source': 'pebble',
        'message': 'Watch delivery failed for command 10.',
        'category': 6,
        'failedCommand': 10,
        'detail': 'Watch delivery failed for command 10.',
      });
      expect(diagnosticEvent.eventId, 'native-1');
      expect(diagnosticEvent.severity, 'error');
      expect(diagnosticEvent.source, 'pebble');
      expect(diagnosticEvent.message, contains('failed'));
      expect(diagnosticEvent.category, 6);
      expect(diagnosticEvent.failedCommand, 10);
      expect(diagnosticEvent.detail, contains('failed'));

      final deliveryEvent = BridgeEvent.fromEventChannel({
        'event': 'deliveryFailure',
        'command': 10,
        'result': 'failed',
        'transactionId': 12,
        'droppable': false,
      });
      expect(deliveryEvent.command, 10);
      expect(deliveryEvent.result, 'failed');
      expect(deliveryEvent.transactionId, 12);
      expect(deliveryEvent.droppable, isFalse);

      final shareEvent = BridgeEvent.fromEventChannel({
        'event': 'shareStatus',
        'state': 'activeRoute',
        'shareType': 'route',
        'safeHost': 'www.google.com',
        'redirectHopCount': 1,
        'explicitOrigin': true,
        'destinationHasCoordinates': true,
        'travelMode': 'walk',
        'originLabel': 'Auckland Library',
        'destinationLabel': 'Auckland Museum',
        'detail': 'Navigation to Auckland Museum sent to watch.',
        'distanceMeters': 1600,
        'durationSeconds': 900,
      });
      expect(shareEvent.shareStatus?.state, 'activeRoute');
      expect(shareEvent.shareStatus?.isActiveRoute, isTrue);
      expect(shareEvent.shareStatus?.safeHost, 'www.google.com');
      expect(shareEvent.shareStatus?.explicitOrigin, isTrue);
      expect(shareEvent.shareStatus?.routeSummary, '1.6 km - 15 min');
    },
  );

  test('LocationAccessStatus keeps independent readiness dimensions', () {
    final status = LocationAccessStatus.fromMethodChannel({
      'servicesEnabled': false,
      'foregroundState': 'precise',
      'backgroundRequired': true,
      'backgroundGranted': false,
    });

    expect(status.servicesEnabled, isFalse);
    expect(status.foregroundGranted, isTrue);
    expect(status.backgroundReady, isFalse);
    expect(status.isReady, isFalse);
    expect(
      status.legacyPermissionState,
      LocationPermissionState.serviceDisabled,
    );
  });

  test(
    'LocationAccessStatus accepts approximate access as foreground ready',
    () {
      final status = LocationAccessStatus.fromMethodChannel({
        'servicesEnabled': true,
        'foregroundState': 'approximate',
        'backgroundRequired': true,
        'backgroundGranted': true,
      });

      expect(status.foregroundGranted, isTrue);
      expect(status.backgroundReady, isTrue);
      expect(status.isReady, isTrue);
      expect(
        status.legacyPermissionState,
        LocationPermissionState.grantedAlwaysApproximate,
      );
    },
  );

  test(
    'BridgeEvent distinguishes active-route updates, clears, and corruption',
    () {
      final routeEvent = BridgeEvent.fromEventChannel({
        'event': 'activeRouteChanged',
        'activeRoute': {
          'requestId': 9,
          'originPolicy': 'current_location',
          'origin': null,
          'destination': {
            'label': 'Auckland Museum',
            'address': 'The Auckland Domain, Parnell',
            'latitude': -36.8602,
            'longitude': 174.7778,
            'placeId': null,
          },
          'travelMode': 0,
          'savedSlot': null,
          'updatedAtMillis': 1770000000000,
        },
      });
      expect(routeEvent.activeRoute?.requestId, 9);
      expect(routeEvent.activeRoute?.destination.label, 'Auckland Museum');
      expect(routeEvent.activeRouteMalformed, isFalse);

      final clearEvent = BridgeEvent.fromEventChannel({
        'event': 'activeRouteChanged',
        'activeRoute': null,
      });
      expect(clearEvent.activeRoute, isNull);
      expect(clearEvent.activeRouteMalformed, isFalse);

      final malformedEvent = BridgeEvent.fromEventChannel({
        'event': 'activeRouteChanged',
        'activeRoute': {'requestId': 'not-an-integer'},
      });
      expect(malformedEvent.activeRoute, isNull);
      expect(malformedEvent.activeRouteMalformed, isTrue);

      final missingSnapshotEvent = BridgeEvent.fromEventChannel({
        'event': 'activeRouteChanged',
      });
      expect(missingSnapshotEvent.activeRoute, isNull);
      expect(missingSnapshotEvent.activeRouteMalformed, isTrue);
    },
  );

  test('share delivery outcomes are terminal instead of endless progress', () {
    for (final state in const [
      'launchFailed',
      'protocolMismatch',
      'queuedUnconfirmed',
    ]) {
      final status = ShareRoutingStatus(state: state);
      expect(status.isTerminal, isTrue, reason: state);
      expect(status.isActiveRoute, isFalse, reason: state);
    }
  });
}
