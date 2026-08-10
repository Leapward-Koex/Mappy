import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mappy/location_bridge.dart';
import 'package:mappy/provider_bridge.dart';
import 'package:mappy/watch_phone_worker.dart';
import 'package:mappy/watch_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('watch protocol payloads', () {
    test('assigns a unique positive id to every command', () {
      const commandIds = {
        WatchCommands.init,
        WatchCommands.tile,
        WatchCommands.button,
        WatchCommands.gps,
        WatchCommands.theme,
        WatchCommands.tileRequest,
        WatchCommands.destinations,
        WatchCommands.routeRequest,
        WatchCommands.routePoints,
        WatchCommands.routeClear,
        WatchCommands.travelMode,
        WatchCommands.navSteps,
        WatchCommands.units,
        WatchCommands.logEvent,
        WatchCommands.mapSettings,
        WatchCommands.backlight,
        WatchCommands.declination,
        WatchCommands.errorState,
        WatchCommands.mapOrientation,
        WatchCommands.tileAnimation,
        WatchCommands.routeWindowRequest,
        WatchCommands.routeWindowPoints,
        WatchCommands.debugCompass,
        WatchCommands.debugTile,
        WatchCommands.debugRouteProgress,
      };

      expect(commandIds, hasLength(25));
      expect(commandIds, everyElement(isPositive));
    });

    test('encodes watch-originated command dictionaries exactly', () {
      expect(
        WatchMessage.command(WatchCommands.init, const {
          WatchKeys.tileZoom: 0,
          WatchKeys.buttonId: 2,
          WatchKeys.totalBytes: 0,
        }).fields,
        equals(const {
          WatchKeys.tileZoom: 0,
          WatchKeys.buttonId: 2,
          WatchKeys.totalBytes: 0,
          WatchKeys.cmd: WatchCommands.init,
        }),
      );
      expect(
        WatchMessage.command(WatchCommands.tileRequest, const {
          WatchKeys.worldX: 123,
          WatchKeys.worldY: 456,
          WatchKeys.tileZoom: 16,
          WatchKeys.isColor: 1,
        }).fields,
        equals(const {
          WatchKeys.worldX: 123,
          WatchKeys.worldY: 456,
          WatchKeys.tileZoom: 16,
          WatchKeys.isColor: 1,
          WatchKeys.cmd: WatchCommands.tileRequest,
        }),
      );
      expect(
        WatchMessage.command(WatchCommands.routeRequest, const {
          WatchKeys.buttonId: 1,
          WatchKeys.isColor: 0,
        }).fields,
        equals(const {
          WatchKeys.buttonId: 1,
          WatchKeys.isColor: 0,
          WatchKeys.cmd: WatchCommands.routeRequest,
        }),
      );
      expect(
        WatchMessage.command(WatchCommands.navSteps, const {
          WatchKeys.buttonId: 3,
        }).fields,
        equals(const {
          WatchKeys.buttonId: 3,
          WatchKeys.cmd: WatchCommands.navSteps,
        }),
      );
      expect(
        WatchMessage.command(WatchCommands.routeClear).fields,
        equals(const {WatchKeys.cmd: WatchCommands.routeClear}),
      );
      expect(
        WatchMessage.command(WatchCommands.mapOrientation, const {
          WatchKeys.buttonId: 1,
        }).fields,
        equals(const {
          WatchKeys.buttonId: 1,
          WatchKeys.cmd: WatchCommands.mapOrientation,
        }),
      );
      expect(
        watchCommandName(WatchCommands.mapOrientation),
        'CMD_MAP_ORIENTATION',
      );
      expect(
        WatchMessage.command(WatchCommands.tileAnimation, const {
          WatchKeys.buttonId: 2,
        }).fields,
        equals(const {
          WatchKeys.buttonId: 2,
          WatchKeys.cmd: WatchCommands.tileAnimation,
        }),
      );
      expect(
        watchCommandName(WatchCommands.tileAnimation),
        'CMD_TILE_ANIMATION',
      );
      expect(
        watchCommandName(WatchCommands.debugRouteProgress),
        'CMD_DEBUG_ROUTE_PROGRESS',
      );
    });

    test('tile animation modes normalize protocol values', () {
      expect(
        WatchTileAnimationMode.fromProtocol(0),
        WatchTileAnimationMode.none,
      );
      expect(
        WatchTileAnimationMode.fromProtocol(1),
        WatchTileAnimationMode.fadeIn,
      );
      expect(
        WatchTileAnimationMode.fromProtocol(2),
        WatchTileAnimationMode.fadeZoom,
      );
      expect(
        WatchTileAnimationMode.fromProtocol(99),
        WatchTileAnimationMode.none,
      );
      expect(
        WatchTileAnimationMode.fromProtocol(null),
        WatchTileAnimationMode.none,
      );
      expect(
        WatchDisplaySettings.fromChannelMap(const {}).tileAnimationMode,
        WatchTileAnimationMode.fadeIn,
      );
    });

    test('decodes golden tile, destinations, route, and nav steps', () {
      final pixels = List<int>.generate(
        watchTilePixels,
        (index) => (index ~/ watchTileWidth) % 16,
      );
      final tilePayload = encodeRlePaletteIndexes(pixels);
      final tile = decodeWatchTile(
        WatchMessage.command(WatchCommands.tile, {
          WatchKeys.worldX: 100,
          WatchKeys.worldY: 200,
          WatchKeys.tileZoom: 16,
          WatchKeys.totalBytes: tilePayload.length,
          WatchKeys.chunkData: tilePayload,
        }),
      );
      expect(tile.paletteIndexes, hasLength(watchTilePixels));
      expect(tile.decodedNibbles, hasLength(watchDecodedTileBytes));

      final destinationPayload = encodeDestinations(const [
        WatchDestinationRecord(
          slotIndex: 0,
          kind: 0,
          defaultTravelMode: WatchTravelMode.drive,
          latitude: 37.42228,
          longitude: -122.08434,
          label: 'Home',
        ),
      ]);
      final destinations = decodeDestinations(destinationPayload);
      expect(destinations.single.label, 'Home');
      expect(destinations.single.slotIndex, 0);

      final routePayload = encodeRoutePoints(const [
        WorldPoint(worldX: 10, worldY: 20),
        WorldPoint(worldX: 30, worldY: 40),
      ]);
      final route = decodeRoutePoints(routePayload);
      expect(route.points, hasLength(2));
      expect(route.clearsRoute, isFalse);

      final navPayload = encodeNavSteps(const [
        WatchNavStep(
          globalIndex: 0,
          startWorldX: 10,
          startWorldY: 20,
          remainingMeters: 1200,
          remainingSeconds: 420,
          instruction: 'Head north',
        ),
      ], 0);
      final nav = decodeNavSteps(navPayload);
      expect(nav.steps.single.instruction, 'Head north');
    });

    test('destination payload supports more than seven saved locations', () {
      final payload = encodeDestinations(
        List<WatchDestinationRecord>.generate(
          8,
          (index) => WatchDestinationRecord(
            slotIndex: index,
            kind: 2,
            defaultTravelMode: WatchTravelMode.drive,
            latitude: 37 + index / 100,
            longitude: -122 - index / 100,
            label: 'Place $index',
          ),
        ),
      );

      final destinations = decodeDestinations(payload);

      expect(destinations, hasLength(8));
      expect(destinations.last.slotIndex, 7);
      expect(destinations.last.label, 'Place 7');
    });

    test('rejects malformed tile and route payloads', () {
      expect(
        () => decodeRlePaletteIndexes(Uint8List.fromList([0x00])),
        throwsA(isA<WatchProtocolException>()),
      );
      expect(
        () =>
            decodeRlePaletteIndexes(Uint8List.fromList(List.filled(213, 0xf0))),
        throwsA(isA<WatchProtocolException>()),
      );
      expect(
        () => decodeRlePaletteIndexes(Uint8List(watchTilePixels + 1)),
        throwsA(isA<WatchProtocolException>()),
      );
      expect(
        () => decodeRoutePoints(_onePointRoutePayload()),
        throwsA(isA<WatchProtocolException>()),
      );
      expect(
        () => decodeRoutePoints(Uint8List.fromList(const [0, 0, 15])),
        throwsA(isA<WatchProtocolException>()),
      );
      expect(
        () => decodeRoutePoints(
          Uint8List.fromList(const [2, 0, routeWorldZoom, 1]),
        ),
        throwsA(isA<WatchProtocolException>()),
      );
      expect(
        () => decodeDestinations(
          Uint8List.fromList(const [
            0x81,
            254,
            0,
            2,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
          ]),
        ),
        throwsA(isA<WatchProtocolException>()),
      );
    });

    test('redacts credential-like protocol values', () {
      final redacted = redactedDictionary({
        WatchKeys.cmd: WatchCommands.logEvent,
        WatchKeys.instruction:
            'key AIzaSyA123456789012345678901234567890 session=abc123',
      });
      expect(redacted, contains('[redacted-google-key]'));
      expect(redacted, contains('session=[redacted]'));
      expect(
        redacted,
        isNot(contains('AIzaSyA123456789012345678901234567890')),
      );
    });
  });

  group('watch phone worker', () {
    test('GPS messages can carry ordering metadata', () {
      final worker = WatchPhoneWorker(
        locationRepository: const FakeLocationRepository(),
        providerRepository: CountingProviderRepository(),
      );

      final message = worker.gpsMessageFromWorld(
        const WorldPoint(worldX: 10, worldY: 20),
        headingDegrees: 90,
        sequence: 123,
        elapsedMs: 456,
        accuracyCm: 700,
        provider: 'gps',
      );

      expect(
        message.fields,
        equals(const {
          WatchKeys.worldX: 10,
          WatchKeys.worldY: 20,
          WatchKeys.tileZoom: routeWorldZoom,
          WatchKeys.buttonId: 90,
          WatchKeys.gpsSequence: 123,
          WatchKeys.gpsElapsedMs: 456,
          WatchKeys.gpsAccuracyCm: 700,
          WatchKeys.gpsProvider: 'gps',
          WatchKeys.cmd: WatchCommands.gps,
        }),
      );
    });

    test('phone-started route points carry active travel mode', () async {
      final provider = CountingProviderRepository();
      final worker = WatchPhoneWorker(
        locationRepository: const FakeLocationRepository(),
        providerRepository: provider,
      );

      final responses = await worker.startNavigation(
        const WatchNavigationRequest(
          destination: WatchRouteEndpoint(
            label: 'Auckland Museum',
            address: 'Auckland Domain, Parnell, Auckland',
            latitude: -36.86097,
            longitude: 174.77774,
          ),
          travelMode: WatchTravelMode.walk,
        ),
      );

      final routeResponse = responses.firstWhere(
        (message) => message.command == WatchCommands.routePoints,
      );
      expect(routeResponse.fields[WatchKeys.isColor], 0);

      final initResponses = await worker.handleWatchMessage(
        WatchMessage.command(WatchCommands.init),
      );
      final replayedRoute = initResponses.firstWhere(
        (message) => message.command == WatchCommands.routePoints,
      );
      expect(replayedRoute.fields[WatchKeys.isColor], 0);
    });

    test(
      'watch reroutes a phone-started explicit Navigate Now route',
      () async {
        final provider = CountingProviderRepository();
        final worker = WatchPhoneWorker(
          locationRepository: const FakeLocationRepository(),
          providerRepository: provider,
        );

        await worker.startNavigation(
          const WatchNavigationRequest(
            originPolicy: WatchRouteOriginPolicy.explicitPlace,
            origin: WatchRouteEndpoint(
              label: 'Auckland Library',
              address: '44 Lorne Street, Auckland',
              latitude: -36.85157,
              longitude: 174.76514,
            ),
            destination: WatchRouteEndpoint(
              label: 'Auckland Museum',
              address: 'Auckland Domain, Parnell, Auckland',
              latitude: -36.86097,
              longitude: 174.77774,
            ),
            travelMode: WatchTravelMode.walk,
          ),
        );

        final responses = await worker.handleWatchMessage(
          WatchMessage.command(WatchCommands.routeRequest, const {
            WatchKeys.isColor: 0,
          }),
        );

        expect(provider.routeRequests, 2);
        expect(provider.lastOriginLatitude, -36.85157);
        expect(provider.lastOriginLongitude, 174.76514);
        expect(worker.activeRouteSlot, isNull);
        expect(worker.activeRouteTarget?.label, 'Auckland Museum');
        expect(
          responses.map((message) => message.command),
          containsAll([WatchCommands.routePoints, WatchCommands.navSteps]),
        );
      },
    );

    test(
      'init replays and clear removes the active Navigate Now route',
      () async {
        final provider = CountingProviderRepository();
        final worker = WatchPhoneWorker(
          locationRepository: const FakeLocationRepository(),
          providerRepository: provider,
        );

        await worker.startNavigation(
          const WatchNavigationRequest(
            destination: WatchRouteEndpoint(
              label: 'Auckland Museum',
              address: 'Auckland Domain, Parnell, Auckland',
              latitude: -36.86097,
              longitude: 174.77774,
            ),
            travelMode: WatchTravelMode.drive,
          ),
        );

        final initResponses = await worker.handleWatchMessage(
          WatchMessage.command(WatchCommands.init),
        );
        expect(
          initResponses.map((message) => message.command),
          containsAll([WatchCommands.routePoints, WatchCommands.navSteps]),
        );

        await worker.handleWatchMessage(
          WatchMessage.command(WatchCommands.routeClear),
        );
        expect(worker.activeRouteTarget, isNull);

        final navResponses = await worker.handleWatchMessage(
          WatchMessage.command(WatchCommands.navSteps),
        );
        expect(navResponses.single.command, WatchCommands.errorState);
        expect(navResponses.single.fields[WatchKeys.buttonId], 6);
      },
    );

    test('current-location navigation rejects stale route origins', () async {
      final provider = CountingProviderRepository();
      final worker = WatchPhoneWorker(
        locationRepository: StaleLocationRepository(),
        providerRepository: provider,
      );

      final responses = await worker.startNavigation(
        const WatchNavigationRequest(
          destination: WatchRouteEndpoint(
            label: 'Googleplex',
            address: '1600 Amphitheatre Parkway',
            latitude: 37.42228,
            longitude: -122.08434,
          ),
          travelMode: WatchTravelMode.drive,
        ),
      );

      expect(provider.routeRequests, 0);
      expect(responses.single.command, WatchCommands.errorState);
      expect(responses.single.fields[WatchKeys.buttonId], 3);
    });

    test('watch route request accepts dynamic saved-location id', () async {
      final provider = CountingProviderRepository();
      final worker = WatchPhoneWorker(
        locationRepository: const FakeLocationRepository(),
        providerRepository: provider,
        destinations: const [
          WatchDestinationConfig(
            slotIndex: 42,
            label: 'Library',
            address: '100 Library St',
            latitude: 37.43,
            longitude: -122.09,
            kind: 2,
            defaultTravelMode: WatchTravelMode.drive,
          ),
        ],
      );

      final responses = await worker.handleWatchMessage(
        WatchMessage.command(WatchCommands.routeRequest, const {
          WatchKeys.buttonId: 42,
          WatchKeys.isColor: 2,
        }),
      );

      expect(provider.routeRequests, 1);
      expect(worker.activeRouteSlot, 42);
      expect(
        responses.map((message) => message.command),
        containsAll([WatchCommands.routePoints, WatchCommands.navSteps]),
      );
    });

    test('destination edits feed the destination payload decoder', () async {
      final worker = WatchPhoneWorker(
        locationRepository: const FakeLocationRepository(),
        providerRepository: CountingProviderRepository(),
        destinations: const [],
      );

      final responses = await worker.replaceDestination(
        const WatchDestinationConfig(
          slotIndex: 42,
          label: 'Library',
          address: '100 Library St',
          latitude: 37.43,
          longitude: -122.09,
          kind: 2,
          defaultTravelMode: WatchTravelMode.walk,
        ),
      );

      final payload = responses.single.fields[WatchKeys.chunkData] as Uint8List;
      final destinations = decodeDestinations(payload);

      expect(destinations.map((item) => item.slotIndex), contains(42));
      expect(
        destinations.firstWhere((item) => item.slotIndex == 42).label,
        'Library',
      );
    });
  });
}

Uint8List _onePointRoutePayload() {
  final data = ByteData(11)
    ..setUint16(0, 1, Endian.little)
    ..setUint8(2, routeWorldZoom)
    ..setInt32(3, 10, Endian.little)
    ..setInt32(7, 20, Endian.little);
  return data.buffer.asUint8List();
}

class FakeLocationRepository implements LocationRepository {
  const FakeLocationRepository({
    this.location,
    this.hasLocation = true,
    this.permissionState = LocationPermissionState.grantedPrecise,
  });

  final LocationSnapshot? location;
  final bool hasLocation;
  final LocationPermissionState permissionState;

  @override
  Future<LocationSnapshot?> getCurrentLocation({Duration? timeout}) async =>
      hasLocation
      ? location ??
            LocationSnapshot(
              latitude: 37.42228,
              longitude: -122.08434,
              timestamp: DateTime.now(),
              isFresh: true,
            )
      : null;

  @override
  Future<LocationPermissionState> getPermissionState() async => permissionState;

  @override
  Future<LocationPermissionState> requestLocationPermission() async =>
      permissionState;
}

class StaleLocationRepository implements LocationRepository {
  @override
  Future<LocationSnapshot?> getCurrentLocation({Duration? timeout}) async =>
      LocationSnapshot(
        latitude: 37.42228,
        longitude: -122.08434,
        timestamp: DateTime.now().subtract(const Duration(minutes: 2)),
        isFresh: true,
      );

  @override
  Future<LocationPermissionState> getPermissionState() async =>
      LocationPermissionState.grantedPrecise;

  @override
  Future<LocationPermissionState> requestLocationPermission() async =>
      LocationPermissionState.grantedPrecise;
}

class CountingProviderRepository implements ProviderRepository {
  final List<WorldPoint> watchTileRequests = [];
  int routeRequests = 0;
  double? lastOriginLatitude;
  double? lastOriginLongitude;
  TravelMode? lastTravelMode;

  static const status = ProviderStatus(
    configured: true,
    validationState: ProviderValidationState.valid,
  );

  @override
  Future<ProviderStatus> clearApiKey() async => status;

  @override
  Future<ProviderStatus> clearProviderValidationCache() async => status;

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
    routeRequests++;
    lastOriginLatitude = originLatitude;
    lastOriginLongitude = originLongitude;
    lastTravelMode = travelMode;
    return const RouteResult(
      ok: true,
      status: status,
      travelMode: TravelMode.drive,
      distanceMeters: 1200,
      durationSeconds: 420,
      routePoints: [
        RoutePoint(
          latitude: 37.42228,
          longitude: -122.08434,
          worldX: 2693898,
          worldY: 6485365,
        ),
        RoutePoint(
          latitude: 37.423,
          longitude: -122.084,
          worldX: 2693920,
          worldY: 6485320,
        ),
      ],
      fullRoutePoints: [
        RoutePoint(
          latitude: 37.42228,
          longitude: -122.08434,
          worldX: 2693898,
          worldY: 6485365,
        ),
        RoutePoint(
          latitude: 37.42242,
          longitude: -122.08428,
          worldX: 2693902,
          worldY: 6485356,
        ),
        RoutePoint(
          latitude: 37.42256,
          longitude: -122.0842,
          worldX: 2693907,
          worldY: 6485347,
        ),
        RoutePoint(
          latitude: 37.42272,
          longitude: -122.08413,
          worldX: 2693912,
          worldY: 6485338,
        ),
        RoutePoint(
          latitude: 37.42286,
          longitude: -122.08406,
          worldX: 2693916,
          worldY: 6485329,
        ),
        RoutePoint(
          latitude: 37.423,
          longitude: -122.084,
          worldX: 2693920,
          worldY: 6485320,
        ),
      ],
      steps: [
        RouteStep(
          index: 0,
          startLatitude: 37.42228,
          startLongitude: -122.08434,
          startWorldX: 2693898,
          startWorldY: 6485365,
          instruction: 'Head north',
          distanceMeters: 300,
          durationSeconds: 120,
          remainingMeters: 1200,
          remainingSeconds: 420,
        ),
        RouteStep(
          index: 1,
          startLatitude: 37.4225,
          startLongitude: -122.0842,
          startWorldX: 2693904,
          startWorldY: 6485350,
          instruction: 'Turn right',
          distanceMeters: 300,
          durationSeconds: 100,
          remainingMeters: 900,
          remainingSeconds: 300,
        ),
        RouteStep(
          index: 2,
          startLatitude: 37.4227,
          startLongitude: -122.0841,
          startWorldX: 2693910,
          startWorldY: 6485338,
          instruction: 'Continue',
          distanceMeters: 300,
          durationSeconds: 100,
          remainingMeters: 600,
          remainingSeconds: 200,
        ),
        RouteStep(
          index: 3,
          startLatitude: 37.423,
          startLongitude: -122.084,
          startWorldX: 2693920,
          startWorldY: 6485320,
          instruction: 'Arrive',
          distanceMeters: 300,
          durationSeconds: 100,
          remainingMeters: 300,
          remainingSeconds: 100,
        ),
      ],
    );
  }

  @override
  Future<GeocodeResult> geocodeDestination({
    required String addressText,
    String language = 'en-US',
    String region = 'US',
  }) async => const GeocodeResult(ok: true, status: status);

  @override
  Future<PlaceAutocompleteResult> autocompleteDestination({
    required String input,
    double? originLatitude,
    double? originLongitude,
    String? sessionToken,
    String language = 'en-US',
    String region = 'US',
  }) async => const PlaceAutocompleteResult(
    ok: true,
    status: status,
    suggestions: [
      PlaceAutocompleteSuggestion(
        placeId: 'place-1',
        primaryText: 'Googleplex',
        secondaryText: 'Mountain View, CA',
        fullText: 'Googleplex, Mountain View, CA',
      ),
    ],
  );

  @override
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

  @override
  Future<PlaceResolutionResult> resolvePlace({
    required String placeId,
    String? sessionToken,
    String language = 'en-US',
    String region = 'US',
  }) async => PlaceResolutionResult(
    ok: true,
    status: status,
    latitude: 37.42228,
    longitude: -122.08434,
    label: 'Googleplex',
    formattedAddress: '1600 Amphitheatre Parkway, Mountain View, CA',
    placeId: placeId,
    provider: 'google_places',
  );

  @override
  Future<PreviewTileResult> getPreviewTile({
    required double latitude,
    required double longitude,
    int zoom = 16,
  }) async => const PreviewTileResult(status: status);

  @override
  Future<ProviderStatus> getProviderStatus() async => status;

  @override
  Future<MapTileSettingsResult> getMapTileSettings() async =>
      const MapTileSettingsResult(
        ok: true,
        status: status,
        settings: MapTileSettings.defaults,
      );

  @override
  Future<MapTileSettingsResult> setMapTileSettings(
    MapTileSettings settings,
  ) async => MapTileSettingsResult(
    ok: true,
    status: status,
    settings: settings,
    changed: true,
  );

  @override
  Future<MapTileSettingsResult> clearMapTileCache() async =>
      const MapTileSettingsResult(
        ok: true,
        status: status,
        settings: MapTileSettings.defaults,
        changed: true,
      );

  @override
  Future<WatchTileResult> getWatchTile({
    required int worldX,
    required int worldY,
    required int zoom,
    int themeMode = 0,
  }) async {
    watchTileRequests.add(WorldPoint(worldX: worldX, worldY: worldY));
    final pixels = List<int>.generate(watchTilePixels, (index) {
      final x = index % watchTileWidth;
      final y = index ~/ watchTileWidth;
      return ((x ~/ 9) + (y ~/ 9) + watchTileRequests.length) % 16;
    });
    final payload = encodeRlePaletteIndexes(pixels);
    return WatchTileResult(
      ok: true,
      status: status,
      worldX: worldX,
      worldY: worldY,
      zoom: zoom,
      totalBytes: payload.length,
      chunkData: payload,
    );
  }

  @override
  Future<ProviderStatus> storeApiKey(String apiKey) async => status;

  @override
  Future<ProviderStatus> validateProviderSetup() async => status;
}

class FailableProviderRepository extends CountingProviderRepository {
  bool failRoutes = false;

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
    if (failRoutes) {
      routeRequests++;
      lastOriginLatitude = originLatitude;
      lastOriginLongitude = originLongitude;
      lastTravelMode = travelMode;
      return const RouteResult(
        ok: false,
        status: CountingProviderRepository.status,
        detail: 'Route provider failed.',
        errorCategory: 6,
      );
    }
    return super.computeRoute(
      originLatitude: originLatitude,
      originLongitude: originLongitude,
      destinationAddress: destinationAddress,
      destinationLatitude: destinationLatitude,
      destinationLongitude: destinationLongitude,
      travelMode: travelMode,
      language: language,
      region: region,
    );
  }
}

class MissingKeyProviderRepository extends CountingProviderRepository {
  static const missingStatus = ProviderStatus.notConfigured();

  @override
  Future<ProviderStatus> getProviderStatus() async => missingStatus;

  @override
  Future<ProviderStatus> validateProviderSetup() async => missingStatus;

  @override
  Future<WatchTileResult> getWatchTile({
    required int worldX,
    required int worldY,
    required int zoom,
    int themeMode = 0,
  }) async {
    watchTileRequests.add(WorldPoint(worldX: worldX, worldY: worldY));
    return const WatchTileResult(
      ok: false,
      status: missingStatus,
      detail: 'No Google API key is stored.',
      errorCategory: 1,
    );
  }
}

class RouteFailureProviderRepository extends CountingProviderRepository {
  RouteFailureProviderRepository({
    required this.category,
    required this.detail,
  });

  final int category;
  final String detail;

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
    routeRequests++;
    lastOriginLatitude = originLatitude;
    lastOriginLongitude = originLongitude;
    lastTravelMode = travelMode;
    return RouteResult(
      ok: false,
      status: CountingProviderRepository.status,
      detail: detail,
      errorCategory: category,
    );
  }
}

class NetworkFailureProviderRepository extends CountingProviderRepository {
  static const networkStatus = ProviderStatus(
    configured: true,
    validationState: ProviderValidationState.networkUnavailable,
  );

  @override
  Future<ProviderStatus> getProviderStatus() async => networkStatus;

  @override
  Future<WatchTileResult> getWatchTile({
    required int worldX,
    required int worldY,
    required int zoom,
    int themeMode = 0,
  }) async {
    watchTileRequests.add(WorldPoint(worldX: worldX, worldY: worldY));
    return const WatchTileResult(
      ok: false,
      status: networkStatus,
      detail: 'Network unavailable.',
      errorCategory: 4,
    );
  }
}
