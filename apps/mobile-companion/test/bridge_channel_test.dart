import 'package:flutter_test/flutter_test.dart';
import 'package:mappy/bridge_channel.dart';
import 'package:mappy/location_bridge.dart';
import 'package:mappy/provider_bridge.dart';

void main() {
  test('BridgeStatus parses live GPS stream state', () {
    final status = BridgeStatus.fromMethodChannel({
      'registered': true,
      'watchReady': true,
      'watchConnected': true,
      'watchAppActive': true,
      'foregroundServiceActive': true,
      'notificationPermissionState': 'granted',
      'queueLength': 0,
      'inFlight': false,
      'setupState': 'ready',
      'permissionState': 'grantedPrecise',
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
    expect(status.foregroundServiceActive, isTrue);
    expect(status.foregroundServiceLabel, 'Watch session active');
    expect(
      status.notificationPermissionState,
      NotificationPermissionState.granted,
    );
    expect(status.permissionState, LocationPermissionState.grantedPrecise);
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
}
