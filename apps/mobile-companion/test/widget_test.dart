import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mappy/battery_optimization_bridge.dart';
import 'package:mappy/bridge_channel.dart';
import 'package:mappy/location_bridge.dart';
import 'package:mappy/main.dart';
import 'package:mappy/provider_bridge.dart';
import 'package:mappy/watch_phone_worker.dart';
import 'package:mappy/watch_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'mappy_welcome_seen_v1': true});
  });

  testWidgets('first launch shows the welcome flow', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      const MappyApp(
        locationRepository: FakeLocationRepository(
          permissionState: LocationPermissionState.requestAvailable,
        ),
        providerRepository: FakeProviderRepository(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Navigate from the phone'), findsOneWidget);
    expect(find.text('Bring your Google key'), findsNothing);
    expect(find.text('Skip'), findsOneWidget);
  });

  testWidgets('welcome flow asks for permissions and battery exemption', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final locationRepository = RecordingLocationRepository(
      initialState: LocationPermissionState.requestAvailable,
      requestedState: LocationPermissionState.grantedPrecise,
    );
    final bridgeRepository = RecordingBridgeRepository(
      initialStatus: _bridgeStatusWithNotification(
        NotificationPermissionState.requestAvailable,
      ),
      requestedStatus: _bridgeStatusWithNotification(
        NotificationPermissionState.granted,
      ),
    );
    final batteryOptimizationRepository =
        RecordingBatteryOptimizationRepository(
          initialState: BatteryOptimizationState.enabled,
          requestedState: BatteryOptimizationState.disabled,
        );

    await tester.pumpWidget(
      MappyApp(
        locationRepository: locationRepository,
        providerRepository: const FakeProviderRepository(),
        bridgeRepository: bridgeRepository,
        batteryOptimizationRepository: batteryOptimizationRepository,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pumpAndSettle();

    expect(find.text('Allow all-the-time location'), findsOneWidget);
    expect(find.text('Allow Location'), findsOneWidget);
    await tester.tap(find.text('Allow Location'));
    await tester.pumpAndSettle();
    expect(locationRepository.requestCount, 1);
    expect(find.text('Open Always Location'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pumpAndSettle();

    expect(find.text('Allow notifications'), findsOneWidget);
    await tester.tap(find.text('Allow Notifications'));
    await tester.pumpAndSettle();
    expect(bridgeRepository.notificationRequestCount, 1);
    expect(find.text('Notifications Ready'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pumpAndSettle();

    expect(find.text('Disable battery optimizations'), findsOneWidget);
    await tester.tap(find.text('Disable Optimization'));
    await tester.pumpAndSettle();
    expect(batteryOptimizationRepository.requestCount, 1);
    expect(find.text('Battery Ready'), findsOneWidget);
  });

  testWidgets('fresh install keeps setup actions on status', (tester) async {
    await tester.pumpWidget(
      const MappyApp(
        locationRepository: FakeLocationRepository(
          permissionState: LocationPermissionState.requestAvailable,
        ),
        providerRepository: FakeProviderRepository(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Navigate'), findsWidgets);
    expect(find.text('Ready to Navigate'), findsNothing);
    expect(
      find.text(
        'Add a Google API key in Setup before navigation can use Google services.',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('status-navigate-destination-map')),
      findsOneWidget,
    );
    expect(find.text('Missing key'), findsNothing);
    expect(find.text('No watch'), findsNothing);
    expect(find.text('Grant Location'), findsNothing);

    await tester.tap(find.text('Status').last);
    await tester.pumpAndSettle();

    expect(find.text('Ready to Navigate'), findsOneWidget);
    expect(find.text('Missing key'), findsOneWidget);
    expect(find.text('No watch'), findsOneWidget);
    expect(find.text('Grant Location'), findsOneWidget);
  });

  testWidgets('setup screen renders bridge watch readiness', (tester) async {
    const providerStatus = ProviderStatus(
      configured: true,
      validationState: ProviderValidationState.valid,
    );

    await tester.pumpWidget(
      const MappyApp(
        locationRepository: FakeLocationRepository(
          permissionState: LocationPermissionState.grantedPrecise,
        ),
        providerRepository: FakeProviderRepository(status: providerStatus),
        bridgeRepository: FakeBridgeRepository(
          status: BridgeStatus(
            registered: true,
            watchReady: true,
            watchConnected: true,
            watchAppActive: true,
            foregroundServiceActive: true,
            queueLength: 0,
            inFlight: false,
            setupState: BridgeSetupState.ready,
            permissionState: LocationPermissionState.grantedPrecise,
            notificationPermissionState: NotificationPermissionState.granted,
            providerStatus: providerStatus,
            gpsStreamRequested: true,
            gpsStreaming: true,
            gpsStreamProviders: ['gps'],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Status').last);
    await tester.pumpAndSettle();

    expect(find.text('Watch ready'), findsOneWidget);
    await tester.tap(find.text('Setup').last);
    await tester.pumpAndSettle();

    expect(find.text('App Setup'), findsOneWidget);
    expect(find.text('Watch bridge'), findsOneWidget);
    expect(find.text('Live GPS'), findsOneWidget);
    expect(find.text('Streaming (gps)'), findsOneWidget);
    expect(find.text('Ready'), findsWidgets);
  });

  testWidgets('diagnostics screen exposes cache controls and redacts export', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? clipboardText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            final arguments = call.arguments as Map<Object?, Object?>;
            clipboardText = arguments['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      const MappyApp(
        locationRepository: FakeLocationRepository(
          permissionState: LocationPermissionState.grantedPrecise,
        ),
        providerRepository: FakeProviderRepository(),
        bridgeRepository: FakeBridgeRepository(
          diagnostics: {
            'schema_version': 1,
            'file_name': 'mappy-diagnostics-20260612-010203.json',
            'file_uri': 'file:///tmp/mappy-diagnostics-20260612-010203.json',
            'status': {
              'saved_location_count': 2,
              'map_orientation': 'forward_up',
              'heading_source': 'phone_course',
              'last_error_category': 4,
              'last_error_text': 'Network unavailable.',
            },
            'events': [
              {
                'source': 'android_bridge',
                'level': 'error',
                'event': 'provider_validation_finished',
                'message':
                    'Bearer abc.def Authorization: Basic still-secret, '
                    'standalone AIzaSyVerySensitiveSecretValue '
                    'https://maps.example.test/tile?key=AIzaSyAnotherSensitiveSecret&token=provider_secretcode',
              },
            ],
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Diagnostics').last);
    await tester.pumpAndSettle();

    expect(find.text('Clear Tile Cache'), findsOneWidget);
    expect(find.text('Clear Route Cache'), findsOneWidget);
    expect(find.text('Clear Provider Validation'), findsOneWidget);

    await tester.tap(find.text('Export Diagnostics'));
    await tester.pump();

    final exported = clipboardText ?? '';
    expect(exported, contains('"schema_version": 1'));
    expect(exported, isNot(contains('abc.def')));
    expect(exported, isNot(contains('still-secret')));
    expect(exported, isNot(contains('VerySensitiveSecretValue')));
    expect(exported, isNot(contains('AnotherSensitiveSecret')));
    expect(exported, isNot(contains('provider_secretcode')));
    expect(exported, contains('Bearer [redacted]'));
    expect(exported, contains('Authorization: [redacted]'));
    expect(exported, contains('AIza...[redacted]'));
    expect(exported, contains('mappy-diagnostics-20260612-010203.json'));
    expect(exported, contains('"saved_location_count": 2'));
  });

  testWidgets('Google Maps share status is visible on navigate tab', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MappyApp(
        locationRepository: const FakeLocationRepository(
          permissionState: LocationPermissionState.grantedPrecise,
        ),
        providerRepository: const FakeProviderRepository(),
        bridgeRepository: FakeBridgeRepository(
          eventStream: Stream.value(
            BridgeEvent.fromEventChannel({
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
            }),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Navigate'), findsWidgets);
    expect(find.text('Shared Route Active'), findsOneWidget);
    expect(
      find.text('Navigation to Auckland Museum sent to watch.'),
      findsOneWidget,
    );
    expect(find.text('From: Auckland Library'), findsOneWidget);
    expect(find.text('To: Auckland Museum'), findsOneWidget);
    expect(find.text('1.6 km - 15 min'), findsOneWidget);
    expect(
      find.text(
        'Mappy recomputes Google Maps shares, so route alternatives may differ.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('status and setup screens render a current location fix', (
    tester,
  ) async {
    await tester.pumpWidget(
      MappyApp(
        locationRepository: FakeLocationRepository(
          permissionState: LocationPermissionState.grantedAlwaysPrecise,
          location: LocationSnapshot(
            latitude: -36.84846,
            longitude: 174.76333,
            timestamp: DateTime.fromMillisecondsSinceEpoch(1710000000000),
            accuracyMeters: 8,
            provider: 'gps',
            isFresh: true,
          ),
        ),
        providerRepository: const FakeProviderRepository(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Status').last);
    await tester.pumpAndSettle();

    expect(find.text('Fresh fix'), findsOneWidget);
    expect(find.text('Recenter'), findsOneWidget);

    await tester.tap(find.text('Setup').last);
    await tester.pumpAndSettle();

    await tester.drag(
      find.descendant(
        of: find.byType(SetupScreen),
        matching: find.byType(ListView),
      ),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(find.text('-36.84846, 174.76333'), findsWidgets);
  });

  testWidgets('foreground-only location prompts always permission', (
    tester,
  ) async {
    await tester.pumpWidget(
      MappyApp(
        locationRepository: FakeLocationRepository(
          permissionState: LocationPermissionState.grantedPrecise,
          location: LocationSnapshot(
            latitude: -36.84846,
            longitude: 174.76333,
            timestamp: DateTime.fromMillisecondsSinceEpoch(1710000000000),
            accuracyMeters: 8,
            provider: 'gps',
            isFresh: true,
          ),
        ),
        providerRepository: const FakeProviderRepository(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Status').last);
    await tester.pumpAndSettle();

    expect(find.text('Fresh fix'), findsOneWidget);
    expect(find.text('Allow Always'), findsOneWidget);
    expect(find.text('Recenter'), findsNothing);
  });

  testWidgets('status screen surfaces disabled location services', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MappyApp(
        locationRepository: FakeLocationRepository(
          permissionState: LocationPermissionState.serviceDisabled,
        ),
        providerRepository: FakeProviderRepository(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Location service disabled'), findsNothing);
    expect(find.text('Refresh Location'), findsNothing);

    await tester.tap(find.text('Status').last);
    await tester.pumpAndSettle();

    expect(find.text('Location service disabled'), findsWidgets);
    expect(find.text('Refresh Location'), findsOneWidget);
  });

  testWidgets('API key form rejects malformed credentials locally', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MappyApp(
        locationRepository: FakeLocationRepository(
          permissionState: LocationPermissionState.requestAvailable,
        ),
        providerRepository: FakeProviderRepository(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Setup').last);
    await tester.pumpAndSettle();
    expect(find.text('Google API Key'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Bearer example-token');
    final saveButton = find.widgetWithText(FilledButton, 'Save Key');
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Enter a valid Google API key starting with AIza, without spaces or surrounding text.',
      ),
      findsOneWidget,
    );
  });

  test('Google API key validation accepts only a standalone key', () {
    expect(
      googleApiKeyValidationError('AIza0123456789abcdefghijklmnopqrstuvwxy'),
      isNull,
    );
    expect(
      googleApiKeyValidationError(
        'https://example.test/?key=AIza0123456789abcdefghijklmnopqrstuvwxy',
      ),
      isNotNull,
    );
    expect(googleApiKeyValidationError('{"apiKey":"hidden"}'), isNotNull);
  });

  testWidgets('setup screen renders redacted provider key status', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    String? clipboardText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            final arguments = call.arguments as Map<Object?, Object?>;
            clipboardText = arguments['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      const MappyApp(
        locationRepository: FakeLocationRepository(
          permissionState: LocationPermissionState.requestAvailable,
        ),
        providerRepository: FakeProviderRepository(
          status: ProviderStatus(
            configured: true,
            redactedPreview: 'KeyRed...1234 (39)',
            length: 39,
            validationState: ProviderValidationState.valid,
            validationDetail:
                'Map Tiles, Places, Geocoding, and Routes validation succeeded.',
            packageName: 'com.leapwardkoex.mappy',
            certSha1: 'ABCD',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Setup').last);
    await tester.pumpAndSettle();

    expect(find.text('KeyRed...1234 (39)'), findsWidgets);
    expect(find.text('App Setup'), findsOneWidget);
    expect(find.text('Copy Package'), findsOneWidget);
    expect(find.text('Copy SHA-1'), findsOneWidget);
    expect(
      find.text(
        'Valid: Map Tiles, Places, Geocoding, and Routes validation succeeded.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Copy Package'));
    await tester.pumpAndSettle();
    expect(clipboardText, 'com.leapwardkoex.mappy');

    await tester.tap(find.text('Copy SHA-1'));
    await tester.pumpAndSettle();
    expect(clipboardText, 'ABCD');
  });

  testWidgets('settings screen updates map tile settings', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final providerRepository = RecordingMapTileSettingsRepository(
      status: const ProviderStatus(
        configured: true,
        validationState: ProviderValidationState.valid,
      ),
    );
    final watchDispatcher = RecordingWatchMessageDispatcher();

    await tester.pumpWidget(
      MappyApp(
        locationRepository: const FakeLocationRepository(
          permissionState: LocationPermissionState.requestAvailable,
        ),
        providerRepository: providerRepository,
        watchDispatcher: watchDispatcher,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    expect(find.text('Map Tiles'), findsOneWidget);
    expect(find.text('Road'), findsWidgets);

    await tester.scrollUntilVisible(
      find.text('Satellite'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Satellite').last);
    await tester.pumpAndSettle();

    expect(providerRepository.saveCount, 1);
    expect(providerRepository.currentSettings.source, MapTileSource.satellite);
    expect(
      watchDispatcher.phoneMessages.single.command,
      WatchCommands.mapSettings,
    );
    expect(
      find.text('Map tile settings updated; tile caches were cleared.'),
      findsOneWidget,
    );
  });

  testWidgets('settings screen updates watch map orientation', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final providerRepository = RecordingMapTileSettingsRepository(
      status: const ProviderStatus(
        configured: true,
        validationState: ProviderValidationState.valid,
      ),
    );
    final watchDispatcher = RecordingWatchMessageDispatcher();

    await tester.pumpWidget(
      MappyApp(
        locationRepository: const FakeLocationRepository(
          permissionState: LocationPermissionState.requestAvailable,
        ),
        providerRepository: providerRepository,
        watchDispatcher: watchDispatcher,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    expect(find.text('Map Orientation'), findsOneWidget);

    await tester.ensureVisible(find.text('Face forward').last);
    await tester.tap(find.text('Face forward').last);
    await tester.pumpAndSettle();

    expect(watchDispatcher.displaySettingsSaveCount, 1);
    expect(watchDispatcher.mapOrientation, WatchMapOrientation.forwardUp);
    expect(
      watchDispatcher.phoneMessages.map((message) => message.command),
      contains(WatchCommands.mapOrientation),
    );
    expect(providerRepository.saveCount, 0);
  });

  testWidgets('settings screen sends updated watch display settings', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final providerRepository = RecordingMapTileSettingsRepository(
      status: const ProviderStatus(
        configured: true,
        validationState: ProviderValidationState.valid,
      ),
    );
    final watchDispatcher = RecordingWatchMessageDispatcher();

    await tester.pumpWidget(
      MappyApp(
        locationRepository: const FakeLocationRepository(
          permissionState: LocationPermissionState.requestAvailable,
        ),
        providerRepository: providerRepository,
        watchDispatcher: watchDispatcher,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    expect(find.text('Theme'), findsWidgets);
    expect(find.text('Units'), findsWidgets);
    expect(find.text('Default Travel Mode'), findsOneWidget);
    expect(find.text('Backlight'), findsWidgets);

    await tester.tap(find.text('Night').last);
    await tester.pumpAndSettle();
    expect(watchDispatcher.themeMode, WatchThemeMode.night);
    expect(
      watchDispatcher.phoneMessages.map((message) => message.command),
      containsAll([
        WatchCommands.theme,
        WatchCommands.travelMode,
        WatchCommands.units,
        WatchCommands.backlight,
        WatchCommands.mapOrientation,
        WatchCommands.tileAnimation,
      ]),
    );

    await tester.tap(find.text('Imperial').last);
    await tester.pumpAndSettle();
    expect(watchDispatcher.unitsMode, WatchUnitsMode.imperial);

    await tester.ensureVisible(find.text('Walk').last);
    await tester.tap(find.text('Walk').last);
    await tester.pumpAndSettle();
    expect(watchDispatcher.travelMode, WatchTravelMode.walk);
    expect(
      find.text(
        'Walk and bike routes may miss safe pedestrian or bicycling path detail.',
      ),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Keep on').last);
    await tester.tap(find.text('Keep on').last);
    await tester.pumpAndSettle();
    expect(watchDispatcher.backlightMode, WatchBacklightMode.keepOn);

    await tester.ensureVisible(find.text('Fade + Zoom').last);
    await tester.tap(find.text('Fade + Zoom').last);
    await tester.pumpAndSettle();
    expect(watchDispatcher.tileAnimationMode, WatchTileAnimationMode.fadeZoom);
    expect(providerRepository.saveCount, 0);
  });

  testWidgets('saved locations screen edits production destination list', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1300));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const providerStatus = ProviderStatus(
      configured: true,
      validationState: ProviderValidationState.valid,
    );
    final providerRepository = RecordingProviderRepository(
      status: providerStatus,
      suggestionsByRole: const {
        PlaceSearchRole.destination: [
          PlaceAutocompleteSuggestion(
            placeId: 'place-home',
            primaryText: 'Auckland Home',
            secondaryText: 'Ponsonby, Auckland',
            fullText: 'Auckland Home, Ponsonby, Auckland',
          ),
        ],
      },
      resolutionsByPlaceId: const {
        'place-home': PlaceResolutionResult(
          ok: true,
          status: providerStatus,
          latitude: -36.84846,
          longitude: 174.76333,
          label: 'Auckland Home',
          formattedAddress: '1 Queen Street, Auckland',
          placeId: 'place-home',
          provider: 'google_places',
        ),
      },
      routeResult: const RouteResult(ok: true, status: providerStatus),
    );
    final watchDispatcher = RecordingWatchMessageDispatcher(
      destinations: const [],
    );

    await tester.pumpWidget(
      MappyApp(
        locationRepository: const FakeLocationRepository(
          permissionState: LocationPermissionState.grantedPrecise,
        ),
        providerRepository: providerRepository,
        watchDispatcher: watchDispatcher,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Saved').last);
    await tester.pumpAndSettle();

    expect(find.text('No saved locations'), findsOneWidget);
    expect(find.text('Add Location'), findsOneWidget);
    expect(find.byKey(const ValueKey('saved-location-add')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('saved-location-name')),
      'Primary Home',
    );
    await tester.enterText(
      find.byKey(const ValueKey('saved-location-search')),
      'Auckland Home',
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('Powered by Google'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Auckland Home'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Walk').last);
    await tester.pumpAndSettle();
    final saveButton = find.byKey(const ValueKey('saved-location-save'));
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(watchDispatcher.savedDestinations, hasLength(1));
    expect(watchDispatcher.savedDestinations.single.slotIndex, 0);
    expect(watchDispatcher.savedDestinations.single.label, 'Primary Home');
    expect(
      watchDispatcher.savedDestinations.single.address,
      '1 Queen Street, Auckland',
    );
    expect(
      watchDispatcher.savedDestinations.single.defaultTravelMode,
      WatchTravelMode.walk,
    );
    expect(watchDispatcher.savedDestinations.single.placeId, 'place-home');
    expect(find.text('Primary Home saved.'), findsOneWidget);
    expect(find.text('Primary Home'), findsWidgets);
  });

  testWidgets('saved locations screen geocodes free-form entries and clears', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1300));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const providerStatus = ProviderStatus(
      configured: true,
      validationState: ProviderValidationState.valid,
    );
    const providerRepository = FakeProviderRepository(
      status: providerStatus,
      autocompleteResult: PlaceAutocompleteResult(
        ok: true,
        status: providerStatus,
        suggestions: [],
      ),
      geocodeResult: GeocodeResult(
        ok: true,
        status: providerStatus,
        latitude: -36.85157,
        longitude: 174.76514,
        formattedAddress: '44 Lorne Street, Auckland',
        placeId: 'geo-library',
        provider: 'google_geocoding',
      ),
    );
    final watchDispatcher = RecordingWatchMessageDispatcher(
      destinations: const [],
    );

    await tester.pumpWidget(
      MappyApp(
        locationRepository: const FakeLocationRepository(
          permissionState: LocationPermissionState.grantedPrecise,
        ),
        providerRepository: providerRepository,
        watchDispatcher: watchDispatcher,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Saved').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('saved-location-add')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('saved-location-name')),
      'Library',
    );
    await tester.enterText(
      find.byKey(const ValueKey('saved-location-search')),
      '44 Lorne Street',
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    final saveButton = find.byKey(const ValueKey('saved-location-save'));
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(watchDispatcher.savedDestinations, hasLength(1));
    expect(watchDispatcher.savedDestinations.single.slotIndex, 0);
    expect(watchDispatcher.savedDestinations.single.label, 'Library');
    expect(
      watchDispatcher.savedDestinations.single.address,
      '44 Lorne Street, Auckland',
    );
    expect(watchDispatcher.savedDestinations.single.placeId, 'geo-library');
    expect(find.text('Library saved.'), findsOneWidget);

    final clearButton = find.byKey(const ValueKey('saved-location-clear'));
    await tester.ensureVisible(clearButton);
    await tester.tap(clearButton);
    await tester.pumpAndSettle();

    expect(watchDispatcher.savedDestinations, isEmpty);
    expect(find.text('Library cleared.'), findsOneWidget);
    expect(find.text('Library'), findsNothing);
  });

  testWidgets('navigate screen can navigate now from current location', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const providerStatus = ProviderStatus(
      configured: true,
      redactedPreview: 'KeyRed...1234 (39)',
      validationState: ProviderValidationState.valid,
      packageName: 'com.leapwardkoex.mappy',
      certSha1: 'ABCD',
    );
    final locationRepository = FakeLocationRepository(
      permissionState: LocationPermissionState.grantedPrecise,
      location: LocationSnapshot(
        latitude: 37.41973,
        longitude: -122.08278,
        timestamp: DateTime.now(),
        isFresh: true,
      ),
    );
    const providerRepository = FakeProviderRepository(
      status: providerStatus,
      autocompleteResult: PlaceAutocompleteResult(
        ok: true,
        status: providerStatus,
        suggestions: [
          PlaceAutocompleteSuggestion(
            placeId: 'place-googleplex',
            primaryText: 'Googleplex',
            secondaryText: 'Mountain View, CA',
            fullText: 'Googleplex, Mountain View, CA',
          ),
        ],
      ),
      placeResolutionResult: PlaceResolutionResult(
        ok: true,
        status: providerStatus,
        latitude: 37.42228,
        longitude: -122.08434,
        label: 'Googleplex',
        formattedAddress: '1600 Amphitheatre Pkwy',
        placeId: 'place-googleplex',
        provider: 'google_places',
      ),
      routeResult: RouteResult(
        ok: true,
        status: providerStatus,
        travelMode: TravelMode.drive,
        distanceMeters: 1200,
        durationSeconds: 420,
        routePoints: [
          RoutePoint(
            latitude: 37.41973,
            longitude: -122.08278,
            worldX: 10789231,
            worldY: 25912231,
          ),
          RoutePoint(
            latitude: 37.42228,
            longitude: -122.08434,
            worldX: 10789158,
            worldY: 25912081,
          ),
        ],
        steps: [
          RouteStep(
            index: 0,
            startLatitude: 37.41973,
            startLongitude: -122.08278,
            startWorldX: 10789231,
            startWorldY: 25912231,
            instruction: 'Head north',
            distanceMeters: 1200,
            durationSeconds: 420,
            remainingMeters: 1200,
            remainingSeconds: 420,
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      MappyApp(
        locationRepository: locationRepository,
        providerRepository: providerRepository,
        watchDispatcher: WatchPhoneWorker(
          locationRepository: locationRepository,
          providerRepository: providerRepository,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final destinationField = find.byKey(
      const ValueKey('status-navigate-destination-search'),
    );
    await tester.ensureVisible(destinationField);
    await tester.enterText(destinationField, '1600 Amphitheatre Parkway');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('Googleplex'), findsOneWidget);
    await tester.tap(find.text('Googleplex'));
    await tester.pumpAndSettle();

    final routeButton = find.byKey(const ValueKey('status-navigate-now'));
    await tester.ensureVisible(routeButton);
    await tester.tap(routeButton);
    await tester.pumpAndSettle();
    expect(find.text('Navigation to Googleplex sent to watch'), findsOneWidget);
    expect(find.text('Active Route'), findsOneWidget);
    expect(find.textContaining('1.2 km, 7 min'), findsOneWidget);
    expect(find.text('Head north'), findsOneWidget);

    final rerouteButton = find.byKey(const ValueKey('status-reroute-active'));
    await tester.ensureVisible(rerouteButton);
    await tester.tap(rerouteButton);
    await tester.pumpAndSettle();
    expect(find.text('Route refreshed and confirmed on watch.'), findsOneWidget);

    final clearButton = find.byKey(const ValueKey('status-clear-route'));
    await tester.ensureVisible(clearButton);
    await tester.tap(clearButton);
    await tester.pumpAndSettle();
    expect(find.text('Route clear queued.'), findsOneWidget);
    expect(find.byKey(const ValueKey('status-reroute-active')), findsNothing);
  });

  testWidgets('navigate screen can navigate now from an explicit origin', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1300));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const providerStatus = ProviderStatus(
      configured: true,
      validationState: ProviderValidationState.valid,
    );
    final providerRepository = RecordingProviderRepository(
      status: providerStatus,
      suggestionsByRole: const {
        PlaceSearchRole.origin: [
          PlaceAutocompleteSuggestion(
            placeId: 'place-library',
            primaryText: 'Auckland Library',
            secondaryText: 'Lorne Street, Auckland',
            fullText: 'Auckland Library, Lorne Street, Auckland',
          ),
        ],
        PlaceSearchRole.destination: [
          PlaceAutocompleteSuggestion(
            placeId: 'place-museum',
            primaryText: 'Auckland Museum',
            secondaryText: 'Auckland Domain, Parnell',
            fullText: 'Auckland Museum, Auckland Domain, Parnell',
          ),
        ],
      },
      resolutionsByPlaceId: const {
        'place-library': PlaceResolutionResult(
          ok: true,
          status: providerStatus,
          latitude: -36.85157,
          longitude: 174.76514,
          label: 'Auckland Library',
          formattedAddress: '44 Lorne Street, Auckland',
          placeId: 'place-library',
          provider: 'google_places',
        ),
        'place-museum': PlaceResolutionResult(
          ok: true,
          status: providerStatus,
          latitude: -36.86097,
          longitude: 174.77774,
          label: 'Auckland Museum',
          formattedAddress: 'Auckland Domain, Parnell',
          placeId: 'place-museum',
          provider: 'google_places',
        ),
      },
      routeResult: const RouteResult(
        ok: true,
        status: providerStatus,
        travelMode: TravelMode.walk,
        distanceMeters: 1600,
        durationSeconds: 900,
        routePoints: [
          RoutePoint(
            latitude: -36.85157,
            longitude: 174.76514,
            worldX: 16535522,
            worldY: 10756054,
          ),
          RoutePoint(
            latitude: -36.86097,
            longitude: 174.77774,
            worldX: 16536110,
            worldY: 10756598,
          ),
        ],
      ),
    );

    final locationRepository = const FakeLocationRepository(
      permissionState: LocationPermissionState.grantedPrecise,
    );
    await tester.pumpWidget(
      MappyApp(
        locationRepository: locationRepository,
        providerRepository: providerRepository,
        watchDispatcher: WatchPhoneWorker(
          locationRepository: locationRepository,
          providerRepository: providerRepository,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Place'));
    await tester.pumpAndSettle();

    final originField = find.byKey(
      const ValueKey('status-navigate-origin-search'),
    );
    await tester.ensureVisible(originField);
    await tester.enterText(originField, 'library');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auckland Library'));
    await tester.pumpAndSettle();

    final destinationField = find.byKey(
      const ValueKey('status-navigate-destination-search'),
    );
    await tester.ensureVisible(destinationField);
    await tester.enterText(destinationField, 'museum');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auckland Museum'));
    await tester.pumpAndSettle();

    final routeButton = find.byKey(const ValueKey('status-navigate-now'));
    await tester.ensureVisible(routeButton);
    await tester.tap(routeButton);
    await tester.pumpAndSettle();

    expect(providerRepository.routeRequests, 1);
    expect(providerRepository.lastOriginLatitude, -36.85157);
    expect(providerRepository.lastOriginLongitude, 174.76514);
    expect(providerRepository.lastDestinationLatitude, -36.86097);
    expect(providerRepository.lastDestinationLongitude, 174.77774);
    expect(
      find.text('Navigation to Auckland Museum sent to watch'),
      findsOneWidget,
    );
  });

  testWidgets('navigate screen can pick a dropped pin from the map', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const providerStatus = ProviderStatus(
      configured: true,
      validationState: ProviderValidationState.valid,
    );
    final providerRepository = RecordingProviderRepository(
      status: providerStatus,
      suggestionsByRole: const {},
      resolutionsByPlaceId: const {},
      routeResult: const RouteResult(
        ok: true,
        status: providerStatus,
        travelMode: TravelMode.drive,
        distanceMeters: 500,
        durationSeconds: 180,
        routePoints: [
          RoutePoint(
            latitude: 37.41973,
            longitude: -122.08278,
            worldX: 10789231,
            worldY: 25912231,
          ),
          RoutePoint(
            latitude: 37.42033,
            longitude: -122.08344,
            worldX: 10789202,
            worldY: 25912196,
          ),
        ],
      ),
    );
    final locationRepository = FakeLocationRepository(
      permissionState: LocationPermissionState.grantedPrecise,
      location: LocationSnapshot(
        latitude: 37.41973,
        longitude: -122.08278,
        timestamp: DateTime.now(),
        isFresh: true,
      ),
    );

    await tester.pumpWidget(
      MappyApp(
        locationRepository: locationRepository,
        providerRepository: providerRepository,
        watchDispatcher: WatchPhoneWorker(
          locationRepository: locationRepository,
          providerRepository: providerRepository,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('status-navigate-destination-map')),
          )
          .height,
      320,
    );

    final useCenterButton = find.byKey(const ValueKey('status-map-use-center'));
    await tester.ensureVisible(useCenterButton);
    await tester.tap(useCenterButton);
    await tester.pumpAndSettle();

    final routeButton = find.byKey(const ValueKey('status-navigate-now'));
    await tester.ensureVisible(routeButton);
    await tester.tap(routeButton);
    await tester.pumpAndSettle();

    expect(providerRepository.routeRequests, 1);
    expect(providerRepository.lastDestinationLatitude, 37.41973);
    expect(providerRepository.lastDestinationLongitude, -122.08278);
    expect(
      find.text('Navigation to Dropped Pin sent to watch'),
      findsOneWidget,
    );
  });

  testWidgets('navigate map recenters when current location arrives later', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const providerStatus = ProviderStatus(
      configured: true,
      validationState: ProviderValidationState.valid,
    );
    final providerRepository = RecordingProviderRepository(
      status: providerStatus,
      suggestionsByRole: const {},
      resolutionsByPlaceId: const {},
      routeResult: const RouteResult(
        ok: true,
        status: providerStatus,
        travelMode: TravelMode.drive,
        routePoints: [
          RoutePoint(
            latitude: -36.84846,
            longitude: 174.76333,
            worldX: 16535608,
            worldY: 10755874,
          ),
          RoutePoint(
            latitude: -36.84922,
            longitude: 174.76421,
            worldX: 16535649,
            worldY: 10755918,
          ),
        ],
      ),
    );
    final locationRepository = MutableLocationRepository(
      permissionState: LocationPermissionState.grantedPrecise,
    );

    await tester.pumpWidget(
      MappyApp(
        locationRepository: locationRepository,
        providerRepository: providerRepository,
        watchDispatcher: WatchPhoneWorker(
          locationRepository: locationRepository,
          providerRepository: providerRepository,
        ),
      ),
    );
    await tester.pumpAndSettle();

    locationRepository.location = LocationSnapshot(
      latitude: -36.84846,
      longitude: 174.76333,
      timestamp: DateTime.now(),
      isFresh: true,
    );
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();

    final useCenterButton = find.byKey(const ValueKey('status-map-use-center'));
    await tester.ensureVisible(useCenterButton);
    await tester.tap(useCenterButton);
    await tester.pumpAndSettle();

    final routeButton = find.byKey(const ValueKey('status-navigate-now'));
    await tester.ensureVisible(routeButton);
    await tester.tap(routeButton);
    await tester.pumpAndSettle();

    expect(providerRepository.routeRequests, 1);
    expect(providerRepository.lastDestinationLatitude, -36.84846);
    expect(providerRepository.lastDestinationLongitude, 174.76333);
  });

  testWidgets('navigate autocomplete sends available location as bias', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const providerStatus = ProviderStatus(
      configured: true,
      validationState: ProviderValidationState.valid,
    );
    final providerRepository = RecordingProviderRepository(
      status: providerStatus,
      suggestionsByRole: const {
        PlaceSearchRole.destination: [
          PlaceAutocompleteSuggestion(
            placeId: 'place-nearby',
            primaryText: 'Nearby Library',
            secondaryText: 'Central city',
            fullText: 'Nearby Library, Central city',
          ),
        ],
      },
      resolutionsByPlaceId: const {},
      routeResult: null,
    );
    final locationRepository = FakeLocationRepository(
      permissionState: LocationPermissionState.grantedPrecise,
      location: LocationSnapshot(
        latitude: -36.84846,
        longitude: 174.76333,
        timestamp: DateTime.now(),
      ),
    );

    await tester.pumpWidget(
      MappyApp(
        locationRepository: locationRepository,
        providerRepository: providerRepository,
        watchDispatcher: WatchPhoneWorker(
          locationRepository: locationRepository,
          providerRepository: providerRepository,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final destinationField = find.byKey(
      const ValueKey('status-navigate-destination-search'),
    );
    await tester.ensureVisible(destinationField);
    await tester.enterText(destinationField, 'library');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(providerRepository.searchRequests, 1);
    expect(providerRepository.lastSearchOriginLatitude, -36.84846);
    expect(providerRepository.lastSearchOriginLongitude, 174.76333);
    expect(find.text('Nearby Library'), findsOneWidget);
  });
}

BridgeStatus _bridgeStatusWithNotification(NotificationPermissionState state) {
  return BridgeStatus(
    registered: true,
    watchReady: false,
    watchConnected: false,
    watchAppActive: false,
    foregroundServiceActive: false,
    queueLength: 0,
    inFlight: false,
    setupState: BridgeSetupState.locationRequired,
    permissionState: LocationPermissionState.requestAvailable,
    notificationPermissionState: state,
    providerStatus: const ProviderStatus.notConfigured(),
  );
}

class RecordingLocationRepository implements LocationRepository {
  RecordingLocationRepository({
    required this.initialState,
    required this.requestedState,
    this.location,
  });

  final LocationPermissionState initialState;
  final LocationPermissionState requestedState;
  final LocationSnapshot? location;
  int requestCount = 0;
  late LocationPermissionState _currentState = initialState;

  @override
  Future<LocationSnapshot?> getCurrentLocation({Duration? timeout}) async =>
      location;

  @override
  Future<LocationPermissionState> getPermissionState() async => _currentState;

  @override
  Future<LocationPermissionState> requestLocationPermission() async {
    requestCount += 1;
    _currentState = requestedState;
    return _currentState;
  }
}

class RecordingBridgeRepository implements BridgeRepository {
  RecordingBridgeRepository({
    required this.initialStatus,
    required this.requestedStatus,
  });

  final BridgeStatus initialStatus;
  final BridgeStatus requestedStatus;
  int notificationRequestCount = 0;
  late BridgeStatus _currentStatus = initialStatus;

  @override
  Stream<BridgeEvent> get events => const Stream<BridgeEvent>.empty();

  @override
  Future<void> clearDiagnostics() async {}

  @override
  Future<Map<String, Object?>> exportDiagnostics() async {
    return const <String, Object?>{'schema_version': 1, 'events': <Object?>[]};
  }

  @override
  Future<BridgeStatus> getBridgeStatus() async => _currentStatus;

  @override
  Future<BridgeStatus> requestNotificationPermission() async {
    notificationRequestCount += 1;
    _currentStatus = requestedStatus;
    return _currentStatus;
  }

  @override
  Future<BridgeStatus> startWatchApp() async => _currentStatus;
}

class RecordingBatteryOptimizationRepository
    implements BatteryOptimizationRepository {
  RecordingBatteryOptimizationRepository({
    required this.initialState,
    required this.requestedState,
  });

  final BatteryOptimizationState initialState;
  final BatteryOptimizationState requestedState;
  int requestCount = 0;
  late BatteryOptimizationState _currentState = initialState;

  @override
  Future<BatteryOptimizationState> getBatteryOptimizationState() async =>
      _currentState;

  @override
  Future<BatteryOptimizationState> requestDisableBatteryOptimization() async {
    requestCount += 1;
    _currentState = requestedState;
    return _currentState;
  }
}

class FakeLocationRepository implements LocationRepository {
  const FakeLocationRepository({required this.permissionState, this.location});

  final LocationPermissionState permissionState;
  final LocationSnapshot? location;

  @override
  Future<LocationSnapshot?> getCurrentLocation({Duration? timeout}) async =>
      location;

  @override
  Future<LocationPermissionState> getPermissionState() async => permissionState;

  @override
  Future<LocationPermissionState> requestLocationPermission() async =>
      permissionState;
}

class MutableLocationRepository implements LocationRepository {
  MutableLocationRepository({required this.permissionState, this.location});

  LocationPermissionState permissionState;
  LocationSnapshot? location;

  @override
  Future<LocationSnapshot?> getCurrentLocation({Duration? timeout}) async =>
      location;

  @override
  Future<LocationPermissionState> getPermissionState() async => permissionState;

  @override
  Future<LocationPermissionState> requestLocationPermission() async =>
      permissionState;
}

class FakeBridgeRepository implements BridgeRepository {
  const FakeBridgeRepository({
    this.status = const BridgeStatus.unavailable(),
    this.eventStream = const Stream<BridgeEvent>.empty(),
    this.diagnostics = const <String, Object?>{
      'schema_version': 1,
      'events': <Object?>[],
    },
  });

  final BridgeStatus status;
  final Stream<BridgeEvent> eventStream;
  final Map<String, Object?> diagnostics;

  @override
  Stream<BridgeEvent> get events => eventStream;

  @override
  Future<BridgeStatus> getBridgeStatus() async => status;

  @override
  Future<BridgeStatus> startWatchApp() async => status;

  @override
  Future<BridgeStatus> requestNotificationPermission() async => status;

  @override
  Future<Map<String, Object?>> exportDiagnostics() async => diagnostics;

  @override
  Future<void> clearDiagnostics() async {}
}

class FakeProviderRepository implements ProviderRepository {
  const FakeProviderRepository({
    this.status = const ProviderStatus.notConfigured(),
    this.mapTileSettings = MapTileSettings.defaults,
    this.previewTileResult,
    this.geocodeResult,
    this.autocompleteResult,
    this.placeResolutionResult,
    this.routeResult,
    this.watchTileResult,
  });

  final ProviderStatus status;
  final MapTileSettings mapTileSettings;
  final PreviewTileResult? previewTileResult;
  final GeocodeResult? geocodeResult;
  final PlaceAutocompleteResult? autocompleteResult;
  final PlaceResolutionResult? placeResolutionResult;
  final RouteResult? routeResult;
  final WatchTileResult? watchTileResult;

  @override
  Future<ProviderStatus> clearApiKey() async =>
      const ProviderStatus.notConfigured();

  @override
  Future<PreviewTileResult> getPreviewTile({
    required double latitude,
    required double longitude,
    int zoom = 16,
  }) async => previewTileResult ?? PreviewTileResult(status: status);

  @override
  Future<ProviderStatus> getProviderStatus() async => status;

  @override
  Future<MapTileSettingsResult> getMapTileSettings() async =>
      MapTileSettingsResult(
        ok: true,
        status: status,
        settings: mapTileSettings,
      );

  @override
  Future<MapTileSettingsResult> setMapTileSettings(
    MapTileSettings settings,
  ) async => MapTileSettingsResult(
    ok: true,
    status: status,
    settings: settings,
    changed: settings != mapTileSettings,
    detail: 'Map tile settings updated; tile caches were cleared.',
    watchMessage: WatchMessage.command(WatchCommands.mapSettings, {
      WatchKeys.buttonId: settings.source != mapTileSettings.source ? 1 : 2,
      WatchKeys.totalBytes: 1,
    }),
  );

  @override
  Future<MapTileSettingsResult> clearMapTileCache() async =>
      MapTileSettingsResult(
        ok: true,
        status: status,
        settings: mapTileSettings,
        changed: true,
        detail: 'Map tile caches were cleared.',
        watchMessage: WatchMessage.command(WatchCommands.mapSettings, {
          WatchKeys.buttonId: 0,
          WatchKeys.totalBytes: 1,
        }),
      );

  @override
  Future<ProviderStatus> clearProviderValidationCache() async => status;

  @override
  Future<WatchTileResult> getWatchTile({
    required int worldX,
    required int worldY,
    required int zoom,
    int themeMode = 0,
  }) async =>
      watchTileResult ?? _fakeWatchTileResult(worldX, worldY, zoom, status);

  @override
  Future<GeocodeResult> geocodeDestination({
    required String addressText,
    String language = 'en-US',
    String region = 'US',
  }) async => geocodeResult ?? GeocodeResult(ok: false, status: status);

  @override
  Future<PlaceAutocompleteResult> autocompleteDestination({
    required String input,
    double? originLatitude,
    double? originLongitude,
    String? sessionToken,
    String language = 'en-US',
    String region = 'US',
  }) async =>
      autocompleteResult ??
      PlaceAutocompleteResult(ok: true, status: status, suggestions: const []);

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
  }) async =>
      placeResolutionResult ??
      PlaceResolutionResult(ok: false, status: status, placeId: placeId);

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
  }) async => routeResult ?? RouteResult(ok: false, status: status);

  @override
  Future<ProviderStatus> storeApiKey(String apiKey) async => status;

  @override
  Future<ProviderStatus> validateProviderSetup() async => status;
}

class RecordingProviderRepository extends FakeProviderRepository {
  RecordingProviderRepository({
    required super.status,
    required this.suggestionsByRole,
    required this.resolutionsByPlaceId,
    required super.routeResult,
  });

  final Map<PlaceSearchRole, List<PlaceAutocompleteSuggestion>>
  suggestionsByRole;
  final Map<String, PlaceResolutionResult> resolutionsByPlaceId;
  int routeRequests = 0;
  int searchRequests = 0;
  double? lastSearchOriginLatitude;
  double? lastSearchOriginLongitude;
  double? lastOriginLatitude;
  double? lastOriginLongitude;
  double? lastDestinationLatitude;
  double? lastDestinationLongitude;

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
    searchRequests++;
    lastSearchOriginLatitude = originLatitude;
    lastSearchOriginLongitude = originLongitude;
    return PlaceAutocompleteResult(
      ok: true,
      status: status,
      suggestions: suggestionsByRole[role] ?? const [],
    );
  }

  @override
  Future<PlaceResolutionResult> resolvePlace({
    required String placeId,
    String? sessionToken,
    String language = 'en-US',
    String region = 'US',
  }) async =>
      resolutionsByPlaceId[placeId] ??
      PlaceResolutionResult(
        ok: false,
        status: status,
        placeId: placeId,
        detail: 'Place not found.',
      );

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
    lastDestinationLatitude = destinationLatitude;
    lastDestinationLongitude = destinationLongitude;
    return routeResult ?? RouteResult(ok: false, status: status);
  }
}

class RecordingMapTileSettingsRepository extends FakeProviderRepository {
  RecordingMapTileSettingsRepository({required super.status});

  MapTileSettings currentSettings = MapTileSettings.defaults;
  int saveCount = 0;

  @override
  Future<MapTileSettingsResult> getMapTileSettings() async =>
      MapTileSettingsResult(
        ok: true,
        status: status,
        settings: currentSettings,
      );

  @override
  Future<MapTileSettingsResult> setMapTileSettings(
    MapTileSettings settings,
  ) async {
    saveCount += 1;
    currentSettings = settings;
    return MapTileSettingsResult(
      ok: true,
      status: status,
      settings: currentSettings,
      changed: true,
      detail: 'Map tile settings updated; tile caches were cleared.',
      watchMessage: WatchMessage.command(WatchCommands.mapSettings, {
        WatchKeys.buttonId: settings.source == MapTileSource.satellite ? 1 : 0,
        WatchKeys.totalBytes: saveCount,
      }),
    );
  }
}

class RecordingWatchMessageDispatcher implements WatchMessageDispatcher {
  RecordingWatchMessageDispatcher({List<WatchDestinationConfig>? destinations})
    : savedDestinations = List<WatchDestinationConfig>.from(
        destinations ?? const <WatchDestinationConfig>[],
      );

  final List<WatchMessage> phoneMessages = [];
  final List<WatchDestinationConfig> savedDestinations;
  WatchThemeMode themeMode = WatchThemeMode.auto;
  WatchTravelMode travelMode = WatchTravelMode.drive;
  WatchUnitsMode unitsMode = WatchUnitsMode.metric;
  WatchBacklightMode backlightMode = WatchBacklightMode.system;
  WatchMapOrientation mapOrientation = WatchMapOrientation.northUp;
  WatchTileAnimationMode tileAnimationMode = WatchTileAnimationMode.fadeIn;
  int orientationSaveCount = 0;
  int displaySettingsSaveCount = 0;
  int routeStarts = 0;
  int reroutes = 0;
  int clears = 0;

  @override
  ProviderStatus get lastProviderStatus => const ProviderStatus(
    configured: true,
    validationState: ProviderValidationState.valid,
  );

  @override
  Future<List<WatchMessage>> handleWatchMessage(WatchMessage message) async =>
      const [];

  @override
  Future<WatchMapOrientation> getMapOrientation() async => mapOrientation;

  @override
  Future<List<WatchDestinationConfig>> getDestinations() async =>
      List<WatchDestinationConfig>.unmodifiable(savedDestinations);

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
  Future<List<WatchMessage>> replaceDestination(
    WatchDestinationConfig config,
  ) async {
    savedDestinations.removeWhere(
      (destination) => destination.slotIndex == config.slotIndex,
    );
    if (config.enabled) {
      savedDestinations.add(config);
      savedDestinations.sort((a, b) => a.slotIndex.compareTo(b.slotIndex));
    }
    return [
      WatchMessage.command(WatchCommands.destinations, const {
        WatchKeys.totalBytes: 0,
      }),
    ];
  }

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
    displaySettingsSaveCount += 1;
    final messages = settings.toMessages();
    phoneMessages.addAll(messages);
    return messages;
  }

  @override
  Future<void> sendPhoneMessage(WatchMessage message) async {
    phoneMessages.add(message);
  }

  @override
  Future<WatchMessage> setMapOrientation(
    WatchMapOrientation orientation,
  ) async {
    mapOrientation = orientation;
    orientationSaveCount += 1;
    final message = WatchMessage.command(WatchCommands.mapOrientation, {
      WatchKeys.buttonId: orientation.protocolValue,
    });
    phoneMessages.add(message);
    return message;
  }

  @override
  Future<WatchNavigationDispatchResult> startNavigation(
    WatchNavigationRequest request,
  ) async {
    routeStarts += 1;
    return WatchNavigationDispatchResult(
      responses: _routeMessages(),
      deliveryState: WatchNavigationDeliveryState.applied,
    );
  }

  @override
  Future<WatchNavigationDispatchResult> rerouteActiveRoute() async {
    reroutes += 1;
    return WatchNavigationDispatchResult(
      responses: _routeMessages(),
      deliveryState: WatchNavigationDeliveryState.applied,
    );
  }

  @override
  Future<WatchNavigationDispatchResult> clearActiveRoute() async {
    clears += 1;
    return WatchNavigationDispatchResult(
      responses: [WatchMessage.command(WatchCommands.routeClear)],
      deliveryState: WatchNavigationDeliveryState.applied,
    );
  }

  List<WatchMessage> _routeMessages() {
    return [
      WatchMessage.command(WatchCommands.routePoints, {
        WatchKeys.buttonId: 1,
        WatchKeys.chunkData: encodeRoutePoints(const [
          WorldPoint(worldX: 2693898, worldY: 6485365),
          WorldPoint(worldX: 2693920, worldY: 6485320),
        ]),
      }),
      WatchMessage.command(WatchCommands.navSteps, {
        WatchKeys.chunkData: encodeNavSteps(const [
          WatchNavStep(
            globalIndex: 0,
            startWorldX: 2693898,
            startWorldY: 6485365,
            remainingMeters: 1200,
            remainingSeconds: 420,
            instruction: 'Head north',
          ),
          WatchNavStep(
            globalIndex: 1,
            startWorldX: 2693920,
            startWorldY: 6485320,
            remainingMeters: 900,
            remainingSeconds: 300,
            instruction: 'Turn right',
          ),
        ], 0),
      }),
    ];
  }
}

WatchTileResult _fakeWatchTileResult(
  int worldX,
  int worldY,
  int zoom, [
  ProviderStatus status = const ProviderStatus(
    configured: true,
    validationState: ProviderValidationState.valid,
  ),
]) {
  final pixels = List<int>.generate(watchTilePixels, (index) {
    final x = index % watchTileWidth;
    final y = index ~/ watchTileWidth;
    return ((x ~/ 9) + (y ~/ 9)) % 16;
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
