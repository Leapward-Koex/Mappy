import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mappy/provider_bridge.dart';
import 'package:mappy/watch_phone_worker.dart';
import 'package:mappy/watch_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WatchActiveRoute channel codec', () {
    test('decodes and round-trips a current-location route', () {
      final route = WatchActiveRoute.fromChannelMap(<String, Object?>{
        'requestId': 42,
        'originPolicy': 'current_location',
        'origin': null,
        'destination': <String, Object?>{
          'label': 'Auckland Museum',
          'address': 'The Auckland Domain, Parnell',
          'latitude': -36.8602,
          'longitude': 174.7778,
          'placeId': 'museum-place',
        },
        'travelMode': WatchTravelMode.walk.protocolValue,
        'savedSlot': 3,
        'updatedAtMillis': 1770000000000,
      });

      expect(route.requestId, 42);
      expect(route.originPolicy, WatchRouteOriginPolicy.currentLocation);
      expect(route.origin, isNull);
      expect(route.destination.label, 'Auckland Museum');
      expect(route.destination.placeId, 'museum-place');
      expect(route.travelMode, WatchTravelMode.walk);
      expect(route.savedSlot, 3);
      expect(route.updatedAt.millisecondsSinceEpoch, 1770000000000);
      expect(
        WatchActiveRoute.fromChannelMap(route.toChannelMap()).toChannelMap(),
        route.toChannelMap(),
      );
    });

    test('requires an endpoint for an explicit origin', () {
      expect(
        () => WatchActiveRoute.fromChannelMap(<String, Object?>{
          'requestId': 7,
          'originPolicy': 'explicit_place',
          'origin': null,
          'destination': _endpoint,
          'travelMode': WatchTravelMode.drive.protocolValue,
          'savedSlot': null,
          'updatedAtMillis': 1770000000000,
        }),
        throwsFormatException,
      );
    });

    test('decodes an explicit origin without losing endpoint metadata', () {
      final route = WatchActiveRoute.fromChannelMap(<String, Object?>{
        'requestId': 8,
        'originPolicy': 'explicit_place',
        'origin': <String, Object?>{
          'label': 'Britomart',
          'address': '8-10 Queen Street, Auckland',
          'latitude': -36.8441,
          'longitude': 174.7678,
          'placeId': 'origin-place',
        },
        'destination': _endpoint,
        'travelMode': WatchTravelMode.bike.protocolValue,
        'savedSlot': null,
        'updatedAtMillis': 1770000000000,
      });

      expect(route.origin?.label, 'Britomart');
      expect(route.origin?.placeId, 'origin-place');
      expect(route.travelMode, WatchTravelMode.bike);
    });

    test('rejects malformed metadata and coordinates', () {
      for (final payload in <Map<String, Object?>>[
        <String, Object?>{
          'requestId': 0,
          'originPolicy': 'current_location',
          'destination': _endpoint,
          'travelMode': 2,
          'updatedAtMillis': 1770000000000,
        },
        <String, Object?>{
          'requestId': 1,
          'originPolicy': 'unknown',
          'destination': _endpoint,
          'travelMode': 2,
          'updatedAtMillis': 1770000000000,
        },
        <String, Object?>{
          'requestId': 1,
          'originPolicy': 'current_location',
          'destination': <String, Object?>{..._endpoint, 'latitude': 91.0},
          'travelMode': 2,
          'updatedAtMillis': 1770000000000,
        },
      ]) {
        expect(
          () => WatchActiveRoute.fromChannelMap(payload),
          throwsFormatException,
        );
      }
    });
  });

  test(
    'NativeWatchMessageDispatcher reads the authoritative route channel',
    () async {
      const channel = MethodChannel('com.leapwardkoex.mappy/watch');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return <String, Object?>{
              'requestId': 42,
              'originPolicy': 'current_location',
              'origin': null,
              'destination': _endpoint,
              'travelMode': WatchTravelMode.drive.protocolValue,
              'savedSlot': null,
              'updatedAtMillis': 1770000000000,
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final dispatcher = NativeWatchMessageDispatcher(
        providerRepository: const NativeProviderRepository(),
      );
      final route = await dispatcher.getActiveRoute();

      expect(calls, hasLength(1));
      expect(calls.single.method, 'getActiveRoute');
      expect(calls.single.arguments, isNull);
      expect(route?.requestId, 42);
      expect(route?.destination.label, 'Mount Eden');
    },
  );
}

const Map<String, Object?> _endpoint = <String, Object?>{
  'label': 'Mount Eden',
  'address': 'Mount Eden, Auckland',
  'latitude': -36.8772,
  'longitude': 174.7644,
  'placeId': null,
};
