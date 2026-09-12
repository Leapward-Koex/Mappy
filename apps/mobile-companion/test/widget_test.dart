import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mappy/battery_optimization_bridge.dart';
import 'package:mappy/bridge_channel.dart';
import 'package:mappy/first_run_setup_checklist.dart';
import 'package:mappy/location_bridge.dart';
import 'package:mappy/main.dart';
import 'package:mappy/provider_bridge.dart';
import 'package:mappy/watch_phone_worker.dart';
import 'package:mappy/watch_protocol.dart';

const _readyProvider = ProviderStatus(
  configured: true,
  redactedPreview: 'AIza...1234 (39)',
  validationState: ProviderValidationState.valid,
  validationDetail:
      'Map Tiles, Places, Geocoding, and Routes validation succeeded.',
  packageName: 'com.leapwardkoex.mappy',
  certSha1: 'AA:BB:CC:DD',
);

const _readyLocationAccess = LocationAccessStatus(
  servicesEnabled: true,
  foregroundState: ForegroundLocationState.precise,
  backgroundRequired: true,
  backgroundGranted: true,
);

void main() {
  testWidgets(
    'stored checklist version opens normal Navigate with three tabs',
    (tester) async {
      final provider = TestProviderRepository();
      final location = TestLocationRepository(
        accessStatus: LocationAccessStatus.fromLegacy(
          LocationPermissionState.requestAvailable,
        ),
      );

      await _pumpMappy(
        tester,
        provider: provider,
        location: location,
        bridge: TestBridgeRepository(
          status: _bridgeStatus(
            providerStatus: provider.status,
            locationAccess: location.accessStatus,
            notification: NotificationPermissionState.requestAvailable,
          ),
        ),
        battery: TestBatteryOptimizationRepository(
          state: BatteryOptimizationState.enabled,
        ),
      );

      expect(find.byType(NavigationDestination), findsNWidgets(3));
      expect(_navigationLabel('Navigate'), findsOneWidget);
      expect(_navigationLabel('Saved'), findsOneWidget);
      expect(_navigationLabel('Settings'), findsOneWidget);
      expect(find.text('Status'), findsNothing);
      expect(find.text('Set up Mappy'), findsNothing);
      expect(
        find.byKey(const ValueKey('status-navigate-destination-map')),
        findsOneWidget,
      );
      expect(find.text('Set up Google Maps to navigate'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('status-navigate-destination-search')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('open-google-setup')));
      await tester.pumpAndSettle();

      expect(find.text('Google Maps setup'), findsOneWidget);
      expect(find.text('Setup required'), findsOneWidget);
      expect(find.text('Save and validate'), findsOneWidget);
    },
  );

  testWidgets('first eligible launch shows and records the setup checklist', (
    tester,
  ) async {
    final provider = TestProviderRepository();
    final location = TestLocationRepository(
      accessStatus: const LocationAccessStatus(
        servicesEnabled: true,
        foregroundState: ForegroundLocationState.requestAvailable,
        backgroundRequired: true,
        backgroundGranted: false,
      ),
    );
    final bridge = TestBridgeRepository(
      status: _bridgeStatus(
        providerStatus: provider.status,
        locationAccess: location.accessStatus,
        notification: NotificationPermissionState.requestAvailable,
      ),
      setupChecklistVersion: 0,
    );

    await _pumpMappy(
      tester,
      provider: provider,
      location: location,
      bridge: bridge,
      battery: TestBatteryOptimizationRepository(
        state: BatteryOptimizationState.enabled,
      ),
    );

    expect(find.byType(NavigationDestination), findsNWidgets(3));
    expect(find.text('Set up Mappy'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('setup-checklist-google')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('setup-checklist-location')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('setup-checklist-reliability')),
      findsOneWidget,
    );
    expect(find.text('Finish required setup'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('setup-checklist-primary-action')),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('Do this later'), findsOneWidget);
    expect(bridge.setupChecklistWriteCount, 1);
    expect(bridge.setupChecklistVersion, setupChecklistCurrentVersion);

    await tester.tap(find.text('Do this later'));
    await tester.pumpAndSettle();
    expect(find.text('Set up Mappy'), findsNothing);
    expect(find.text('Set up Google Maps to navigate'), findsOneWidget);
  });

  testWidgets('startup shows a compact check while first-run state loads', (
    tester,
  ) async {
    final provider = TestProviderRepository();
    final location = TestLocationRepository(
      accessStatus: const LocationAccessStatus.unavailable(),
    );
    final bridge = DeferredChecklistVersionBridgeRepository(
      status: _bridgeStatus(
        providerStatus: provider.status,
        locationAccess: location.accessStatus,
        notification: NotificationPermissionState.unavailable,
      ),
    );

    await tester.pumpWidget(
      MappyApp(
        providerRepository: provider,
        locationRepository: location,
        bridgeRepository: bridge,
        batteryOptimizationRepository: TestBatteryOptimizationRepository(
          state: BatteryOptimizationState.unknown,
        ),
        watchDispatcher: TestWatchDispatcher(providerStatus: provider.status),
      ),
    );
    await tester.pump();

    expect(find.text('Checking setup…'), findsOneWidget);
    expect(find.text('Set up Google Maps to navigate'), findsNothing);
    expect(find.text('Set up Mappy'), findsNothing);

    bridge.version.complete(0);
    await tester.pumpAndSettle();
    expect(find.text('Set up Mappy'), findsOneWidget);
    expect(bridge.setupChecklistWriteCount, 1);
  });

  testWidgets('recommended reliability setup does not block continuing', (
    tester,
  ) async {
    final provider = TestProviderRepository(status: _readyProvider);
    final location = TestLocationRepository(
      accessStatus: _readyLocationAccess,
      location: _freshLocation(),
    );
    final bridge = TestBridgeRepository(
      status: _bridgeStatus(
        providerStatus: provider.status,
        locationAccess: location.accessStatus,
        notification: NotificationPermissionState.permanentlyDenied,
      ),
      setupChecklistVersion: 0,
    );

    await _pumpMappy(
      tester,
      provider: provider,
      location: location,
      bridge: bridge,
      battery: TestBatteryOptimizationRepository(
        state: BatteryOptimizationState.unavailable,
      ),
    );

    expect(find.text('Continue for now'), findsOneWidget);
    expect(find.text('Do this later'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('setup-checklist-primary-action')),
          )
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.text('Continue for now'));
    await tester.pumpAndSettle();
    expect(find.text('New route'), findsOneWidget);
    expect(find.text('Background reliability needs attention'), findsOneWidget);
  });

  testWidgets('Google checklist row becomes ready only after validation', (
    tester,
  ) async {
    final provider = TestProviderRepository();
    final location = TestLocationRepository(
      accessStatus: _readyLocationAccess,
      location: _freshLocation(),
    );
    final bridge = TestBridgeRepository(
      status: _bridgeStatus(
        providerStatus: provider.status,
        locationAccess: location.accessStatus,
        notification: NotificationPermissionState.granted,
      ),
      setupChecklistVersion: 0,
    );
    await _pumpMappy(
      tester,
      provider: provider,
      location: location,
      bridge: bridge,
      battery: TestBatteryOptimizationRepository(
        state: BatteryOptimizationState.disabled,
      ),
    );

    final googleRow = find.byKey(const ValueKey('setup-checklist-google'));
    expect(
      find.descendant(of: googleRow, matching: find.text('Needs attention')),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(of: googleRow, matching: find.text('Set up')),
    );
    await tester.pumpAndSettle();

    provider.status = _readyProvider;
    await tester.enterText(
      find.byKey(const ValueKey('google-api-key-input')),
      'AIza0123456789abcdefghijklmnopqrstuvwxy',
    );
    await tester.tap(find.byKey(const ValueKey('save-and-validate-key')));
    await tester.pumpAndSettle();
    expect(find.text('Google services ready'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: googleRow, matching: find.text('Ready')),
      findsOneWidget,
    );
    expect(find.text('Start using Mappy'), findsOneWidget);
  });

  testWidgets('failed checklist persistence retries on the next launch', (
    tester,
  ) async {
    final provider = TestProviderRepository();
    final location = TestLocationRepository(
      accessStatus: const LocationAccessStatus.unavailable(),
    );
    final bridge = TestBridgeRepository(
      status: _bridgeStatus(
        providerStatus: provider.status,
        locationAccess: location.accessStatus,
        notification: NotificationPermissionState.unavailable,
      ),
      setupChecklistVersion: 0,
      setupChecklistWriteSucceeds: false,
    );

    await _pumpMappy(
      tester,
      provider: provider,
      location: location,
      bridge: bridge,
    );
    expect(find.text('Set up Mappy'), findsOneWidget);
    expect(bridge.setupChecklistWriteCount, 1);
    expect(bridge.setupChecklistVersion, 0);

    await tester.tap(find.text('Do this later'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await _pumpMappy(
      tester,
      provider: provider,
      location: location,
      bridge: bridge,
    );

    expect(find.text('Set up Mappy'), findsOneWidget);
    expect(bridge.setupChecklistWriteCount, 2);
  });

  testWidgets(
    'provider status event wins over a delayed read without polling again',
    (tester) async {
      final provider = DeferredFirstProviderRepository(status: _readyProvider);
      final location = TestLocationRepository(
        accessStatus: _readyLocationAccess,
        location: _freshLocation(),
      );
      final events = StreamController<BridgeEvent>.broadcast(sync: true);
      addTearDown(events.close);
      final bridge = TestBridgeRepository(
        status: _bridgeStatus(
          providerStatus: _readyProvider,
          locationAccess: _readyLocationAccess,
          notification: NotificationPermissionState.granted,
        ),
        eventStream: events.stream,
      );

      await tester.pumpWidget(
        MappyApp(
          providerRepository: provider,
          locationRepository: location,
          bridgeRepository: bridge,
          batteryOptimizationRepository: TestBatteryOptimizationRepository(
            state: BatteryOptimizationState.disabled,
          ),
          watchDispatcher: TestWatchDispatcher(providerStatus: _readyProvider),
        ),
      );
      expect(find.text('Checking setup…'), findsOneWidget);

      const pushedLocationStream = BridgeLocationStreamStatus(
        requested: true,
        streaming: true,
        providers: ['gps'],
        permissionState: LocationPermissionState.grantedAlwaysPrecise,
        locationAccessStatus: _readyLocationAccess,
        headingAvailable: true,
        lastFixAge: Duration(seconds: 1),
        lastFixFresh: true,
      );
      events.add(
        const BridgeEvent(
          type: 'providerStatus',
          providerStatus: _readyProvider,
        ),
      );
      events.add(
        const BridgeEvent(
          type: 'locationStatus',
          locationStream: pushedLocationStream,
        ),
      );
      for (var i = 0; i < 5; i += 1) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(provider.statusRequestCount, 1);

      provider.firstStatus.complete(const ProviderStatus.notConfigured());
      await tester.pumpAndSettle();
      expect(provider.statusRequestCount, 1);
      expect(find.text('New route'), findsOneWidget);
      expect(find.text('Set up Google Maps to navigate'), findsNothing);
      await _openSettingsPage(tester, 'Watch connection');
      expect(find.text('Streaming (gps)'), findsOneWidget);
    },
  );

  testWidgets('transport echo does not schedule a redundant rebuild', (
    tester,
  ) async {
    final events = StreamController<BridgeEvent>.broadcast(sync: true);
    addTearDown(events.close);
    final bridge = TestBridgeRepository(
      status: _bridgeStatus(
        providerStatus: _readyProvider,
        locationAccess: _readyLocationAccess,
        notification: NotificationPermissionState.granted,
      ),
      eventStream: events.stream,
    );

    await _pumpReadyMappy(tester, bridge: bridge);
    expect(tester.binding.hasScheduledFrame, isFalse);

    events.add(
      const BridgeEvent(type: 'transportChanged', reason: 'queue_updated'),
    );

    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets(
    'a route arriving before first paint prevents checklist storage',
    (tester) async {
      final events = StreamController<BridgeEvent>.broadcast(sync: true);
      addTearDown(events.close);
      final provider = TestProviderRepository();
      final location = TestLocationRepository(
        accessStatus: const LocationAccessStatus.unavailable(),
      );
      final bridge = TestBridgeRepository(
        status: _bridgeStatus(
          providerStatus: provider.status,
          locationAccess: location.accessStatus,
          notification: NotificationPermissionState.unavailable,
        ),
        eventStream: events.stream,
        setupChecklistVersion: 0,
      );
      final activeRoute = _activeRoute();

      await tester.pumpWidget(
        MappyApp(
          providerRepository: provider,
          locationRepository: location,
          bridgeRepository: bridge,
          batteryOptimizationRepository: TestBatteryOptimizationRepository(
            state: BatteryOptimizationState.enabled,
          ),
          watchDispatcher: TestWatchDispatcher(providerStatus: provider.status),
        ),
      );
      events.add(
        BridgeEvent(type: 'activeRouteChanged', activeRoute: activeRoute),
      );
      await tester.pumpAndSettle();

      expect(find.text('Active navigation'), findsOneWidget);
      expect(find.text('Set up Mappy'), findsNothing);
      expect(bridge.setupChecklistWriteCount, 0);
      expect(bridge.setupChecklistVersion, 0);
    },
  );

  testWidgets('settings and required rows show readiness warning dots', (
    tester,
  ) async {
    final provider = TestProviderRepository();
    final location = TestLocationRepository(
      accessStatus: const LocationAccessStatus(
        servicesEnabled: false,
        foregroundState: ForegroundLocationState.precise,
        backgroundRequired: true,
        backgroundGranted: false,
      ),
    );

    await _pumpMappy(
      tester,
      provider: provider,
      location: location,
      bridge: TestBridgeRepository(
        status: _bridgeStatus(
          providerStatus: provider.status,
          locationAccess: location.accessStatus,
          notification: NotificationPermissionState.permanentlyDenied,
        ),
      ),
      battery: TestBatteryOptimizationRepository(
        state: BatteryOptimizationState.enabled,
      ),
    );

    final navigationBadges = tester.widgetList<Badge>(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byType(Badge),
      ),
    );
    expect(navigationBadges.any((badge) => badge.isLabelVisible), isTrue);

    await _selectTab(tester, 'Settings');

    expect(
      _warningBadge(tester, const ValueKey('settings-setup-checklist')),
      true,
    );
    expect(_warningBadge(tester, const ValueKey('settings-google-maps')), true);
    expect(_warningBadge(tester, const ValueKey('settings-permissions')), true);
    expect(find.text('Required setup incomplete'), findsOneWidget);
    expect(find.text('Needs setup'), findsOneWidget);
    expect(find.text('Needs attention'), findsOneWidget);
  });

  testWidgets('readiness warning dots hide when required setup is complete', (
    tester,
  ) async {
    await _pumpReadyMappy(tester);

    expect(
      tester
          .widgetList<Badge>(
            find.descendant(
              of: find.byType(NavigationBar),
              matching: find.byType(Badge),
            ),
          )
          .every((badge) => !badge.isLabelVisible),
      isTrue,
    );

    await _selectTab(tester, 'Settings');
    expect(
      _warningBadge(tester, const ValueKey('settings-setup-checklist')),
      false,
    );
    expect(
      _warningBadge(tester, const ValueKey('settings-google-maps')),
      false,
    );
    expect(
      _warningBadge(tester, const ValueKey('settings-permissions')),
      false,
    );
  });

  testWidgets('Settings can reopen the setup checklist manually', (
    tester,
  ) async {
    final bridge = TestBridgeRepository(
      status: _bridgeStatus(
        providerStatus: _readyProvider,
        locationAccess: _readyLocationAccess,
        notification: NotificationPermissionState.granted,
      ),
    );
    await _pumpReadyMappy(tester, bridge: bridge);
    await _selectTab(tester, 'Settings');

    final setupTile = find.byKey(const ValueKey('settings-setup-checklist'));
    expect(setupTile, findsOneWidget);
    await tester.tap(setupTile);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Setup checklist'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('setup-checklist-google')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('setup-checklist-location')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('setup-checklist-reliability')),
      findsOneWidget,
    );
    expect(find.text('Done'), findsOneWidget);
    expect(bridge.setupChecklistWriteCount, 0);
  });

  testWidgets('permissions keep service, app, and background state separate', (
    tester,
  ) async {
    const access = LocationAccessStatus(
      servicesEnabled: false,
      foregroundState: ForegroundLocationState.precise,
      backgroundRequired: true,
      backgroundGranted: true,
    );
    final location = TestLocationRepository(accessStatus: access);
    final bridge = TestBridgeRepository(
      status: _bridgeStatus(
        providerStatus: _readyProvider,
        locationAccess: access,
        notification: NotificationPermissionState.permanentlyDenied,
      ),
    );
    final battery = TestBatteryOptimizationRepository(
      state: BatteryOptimizationState.enabled,
      requestedState: BatteryOptimizationState.disabled,
    );

    await _pumpMappy(
      tester,
      provider: TestProviderRepository(status: _readyProvider),
      location: location,
      bridge: bridge,
      battery: battery,
    );
    await _openSettingsPage(tester, 'Permissions');

    expect(find.text('Device location services'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('App location access'), findsOneWidget);
    expect(find.text('Precise'), findsOneWidget);
    expect(find.text('Background location'), findsOneWidget);
    expect(find.text('Allowed'), findsOneWidget);
    expect(find.text('Not allowed'), findsOneWidget);
    expect(find.text('Optimized'), findsOneWidget);

    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(location.openLocationServicesCount, 1);

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(bridge.openNotificationSettingsCount, 1);

    await tester.tap(find.text('Change setting'));
    await tester.pumpAndSettle();
    expect(battery.requestCount, 1);
    expect(find.text('Unrestricted'), findsOneWidget);

    final phoneSettings = find.text('Phone battery settings');
    await tester.ensureVisible(phoneSettings);
    await tester.tap(phoneSettings);
    await tester.pumpAndSettle();
    expect(battery.openSettingsCount, 1);
    expect(find.text('Unrestricted'), findsOneWidget);

    battery.settingsOpened = false;
    await tester.tap(phoneSettings);
    await tester.pumpAndSettle();
    expect(
      find.text('Phone battery settings could not be opened.'),
      findsOneWidget,
    );
  });

  testWidgets('foreground permission updates without waiting for a GPS fix', (
    tester,
  ) async {
    const initialAccess = LocationAccessStatus(
      servicesEnabled: true,
      foregroundState: ForegroundLocationState.requestAvailable,
      backgroundRequired: false,
      backgroundGranted: false,
    );
    final location = TestLocationRepository(accessStatus: initialAccess)
      ..requestedAccessStatus = const LocationAccessStatus(
        servicesEnabled: true,
        foregroundState: ForegroundLocationState.approximate,
        backgroundRequired: false,
        backgroundGranted: false,
      );
    final bridge = TestBridgeRepository(
      status: _bridgeStatus(
        providerStatus: _readyProvider,
        locationAccess: initialAccess,
        notification: NotificationPermissionState.granted,
      ),
    );

    await _pumpMappy(
      tester,
      provider: TestProviderRepository(status: _readyProvider),
      location: location,
      bridge: bridge,
      battery: TestBatteryOptimizationRepository(
        state: BatteryOptimizationState.disabled,
      ),
    );
    await _openSettingsPage(tester, 'Permissions');

    await tester.tap(find.widgetWithText(TextButton, 'Allow'));
    await tester.pumpAndSettle();

    expect(location.foregroundRequestCount, 1);
    expect(find.text('Approximate'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('Google API setup rejects non-key credentials locally', (
    tester,
  ) async {
    await _pumpMappy(
      tester,
      provider: TestProviderRepository(),
      location: TestLocationRepository(accessStatus: _readyLocationAccess),
    );

    await tester.tap(find.byKey(const ValueKey('open-google-setup')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('google-api-key-input')),
      'Bearer example-token',
    );
    await tester.tap(find.byKey(const ValueKey('save-and-validate-key')));
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

  testWidgets(
    'Google API setup clears plaintext after secure storage before validation',
    (tester) async {
      const apiKey = 'AIza0123456789abcdefghijklmnopqrstuvwxy';
      const storedStatus = ProviderStatus(
        configured: true,
        redactedPreview: 'AIza...wxy',
        validationState: ProviderValidationState.notValidated,
      );
      final storeResult = Completer<ProviderStatus>();
      final validationResult = Completer<ProviderStatus>();
      TextEditingController? apiKeyController;
      var validationCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: GoogleMapsSetupScreen(
            initialStatus: const ProviderStatus.notConfigured(),
            onStoreApiKey: (value) {
              expect(value, apiKey);
              return storeResult.future;
            },
            onValidateProviderSetup: () {
              validationCalls++;
              expect(apiKeyController?.text, isEmpty);
              return validationResult.future;
            },
            onRemoveKey: () async => const ProviderStatus.notConfigured(),
          ),
        ),
      );

      final input = find.byKey(const ValueKey('google-api-key-input'));
      final textField = tester.widget<TextField>(input);
      apiKeyController = textField.controller;
      expect(textField.enableIMEPersonalizedLearning, isFalse);

      await tester.enterText(input, apiKey);
      await tester.tap(find.byKey(const ValueKey('save-and-validate-key')));
      await tester.pump();

      expect(apiKeyController?.text, apiKey);
      expect(validationCalls, 0);

      storeResult.complete(storedStatus);
      await tester.pump();

      expect(apiKeyController?.text, isEmpty);
      expect(validationCalls, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      validationResult.complete(_readyProvider);
      await tester.pumpAndSettle();

      expect(find.text('Google services ready'), findsOneWidget);
    },
  );

  testWidgets('Google API setup clears plaintext when secure storage fails', (
    tester,
  ) async {
    var validationCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: GoogleMapsSetupScreen(
          initialStatus: const ProviderStatus.notConfigured(),
          onStoreApiKey: (_) async => throw StateError('storage unavailable'),
          onValidateProviderSetup: () async {
            validationCalls++;
            return _readyProvider;
          },
          onRemoveKey: () async => const ProviderStatus.notConfigured(),
        ),
      ),
    );

    final input = find.byKey(const ValueKey('google-api-key-input'));
    final controller = tester.widget<TextField>(input).controller;
    await tester.enterText(input, 'AIza0123456789abcdefghijklmnopqrstuvwxy');
    await tester.tap(find.byKey(const ValueKey('save-and-validate-key')));
    await tester.pumpAndSettle();

    expect(controller?.text, isEmpty);
    expect(validationCalls, 0);
    expect(
      find.text('Could not save the API key securely. Try again.'),
      findsOneWidget,
    );
  });

  testWidgets('Google API setup clears plaintext when disposed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GoogleMapsSetupScreen(
          initialStatus: const ProviderStatus.notConfigured(),
          onStoreApiKey: (_) async => const ProviderStatus.notConfigured(),
          onValidateProviderSetup: () async =>
              const ProviderStatus.notConfigured(),
          onRemoveKey: () async => const ProviderStatus.notConfigured(),
        ),
      ),
    );

    final input = find.byKey(const ValueKey('google-api-key-input'));
    final controller = tester.widget<TextField>(input).controller;
    await tester.enterText(input, 'AIza0123456789abcdefghijklmnopqrstuvwxy');

    await tester.pumpWidget(const SizedBox.shrink());

    expect(controller?.text, isEmpty);
  });

  testWidgets('Google API retry clears unsaved plaintext before validation', (
    tester,
  ) async {
    const storedStatus = ProviderStatus(
      configured: true,
      redactedPreview: 'AIza...1234',
      validationState: ProviderValidationState.notValidated,
    );
    final validationResult = Completer<ProviderStatus>();
    TextEditingController? apiKeyController;

    await tester.pumpWidget(
      MaterialApp(
        home: GoogleMapsSetupScreen(
          initialStatus: storedStatus,
          onStoreApiKey: (_) async => storedStatus,
          onValidateProviderSetup: () {
            expect(apiKeyController?.text, isEmpty);
            return validationResult.future;
          },
          onRemoveKey: () async => const ProviderStatus.notConfigured(),
        ),
      ),
    );

    final input = find.byKey(const ValueKey('google-api-key-input'));
    apiKeyController = tester.widget<TextField>(input).controller;
    await tester.enterText(input, 'AIza0123456789abcdefghijklmnopqrstuvwxy');
    final retryButton = find.widgetWithText(OutlinedButton, 'Retry validation');
    tester.widget<OutlinedButton>(retryButton).onPressed?.call();
    await tester.pump();

    expect(apiKeyController?.text, isEmpty);

    validationResult.complete(_readyProvider);
    await tester.pumpAndSettle();
  });

  testWidgets('Google setup shows a redacted key and copyable restrictions', (
    tester,
  ) async {
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

    await _pumpReadyMappy(tester);
    await _openSettingsPage(tester, 'Google Maps setup');

    expect(find.text('Google services ready'), findsOneWidget);
    expect(find.textContaining('Stored key: AIza...1234 (39)'), findsOneWidget);
    expect(find.text('Android package'), findsOneWidget);
    expect(find.text('Signing SHA-1'), findsOneWidget);
    expect(
      find.text(
        'Map Tiles API, Places API (New), Geocoding API, and Routes API',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Copy package'));
    await tester.pump();
    expect(clipboardText, 'com.leapwardkoex.mappy');

    await tester.tap(find.byTooltip('Copy SHA-1'));
    await tester.pump();
    expect(clipboardText, 'AA:BB:CC:DD');

    await tester.tap(find.byTooltip('Copy required APIs'));
    await tester.pump();
    expect(
      clipboardText,
      'Map Tiles API, Places API (New), Geocoding API, and Routes API',
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('google-api-key-guide')),
      180,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('google-maps-setup-list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.byKey(const ValueKey('google-api-key-guide')));
    await tester.pumpAndSettle();
    expect(find.text('Enable the four APIs'), findsOneWidget);
    expect(find.text('Restrict it to this Android app'), findsOneWidget);
    expect(find.text('Restrict the key to Mappy APIs'), findsOneWidget);
    expect(find.text('Copy, save, and validate'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('open-google-cloud-console')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Google Cloud Application restrictions screen with Android apps highlighted',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Google Cloud API restrictions dropdown with four APIs highlighted',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Google Cloud Select a project dialog with New project circled',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Google Cloud New Project screen with project name and Create highlighted',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Google Cloud navigation with APIs and Services then Enabled APIs and services highlighted',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Google Cloud navigation with APIs and Services then Credentials highlighted',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Google Cloud Credentials screen with Create credentials and API key highlighted',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Google Cloud credentials list showing a completed Mappy API key',
      ),
      findsOneWidget,
    );
  });

  testWidgets('watch readiness lives under Settings', (tester) async {
    final provider = TestProviderRepository(status: _readyProvider);
    final location = TestLocationRepository(
      accessStatus: _readyLocationAccess,
      location: _freshLocation(),
    );
    final bridge = TestBridgeRepository(
      status: _bridgeStatus(
        providerStatus: provider.status,
        locationAccess: location.accessStatus,
        notification: NotificationPermissionState.granted,
        watchReady: true,
        gpsStreaming: true,
      ),
    );

    await _pumpMappy(
      tester,
      provider: provider,
      location: location,
      bridge: bridge,
      battery: TestBatteryOptimizationRepository(
        state: BatteryOptimizationState.disabled,
      ),
    );
    await _openSettingsPage(tester, 'Watch connection');

    expect(find.text('Watch ready'), findsOneWidget);
    expect(find.text('Watch session'), findsOneWidget);
    expect(find.text('Live GPS'), findsOneWidget);
    expect(find.text('Streaming (gps)'), findsOneWidget);
    expect(find.text('Open watch'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
  });

  testWidgets('diagnostics copy is redacted and maintenance is collapsed', (
    tester,
  ) async {
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

    final bridge = TestBridgeRepository(
      status: _bridgeStatus(
        providerStatus: _readyProvider,
        locationAccess: _readyLocationAccess,
        notification: NotificationPermissionState.granted,
      ),
      diagnostics: const {
        'schema_version': 1,
        'file_name': 'mappy-diagnostics.json',
        'events': [
          {
            'message':
                'Bearer abc.def Authorization: Basic still-secret '
                'AIzaSyVerySensitiveSecretValue '
                'https://maps.test/tile?token=provider_secretcode',
          },
        ],
      },
    );

    await _pumpMappy(
      tester,
      provider: TestProviderRepository(status: _readyProvider),
      location: TestLocationRepository(accessStatus: _readyLocationAccess),
      bridge: bridge,
      battery: TestBatteryOptimizationRepository(
        state: BatteryOptimizationState.disabled,
      ),
    );
    await _openSettingsPage(tester, 'Help & diagnostics');

    expect(find.text('Copy diagnostics'), findsOneWidget);
    expect(find.text('Recent events'), findsOneWidget);
    expect(find.text('Maintenance'), findsOneWidget);
    expect(find.text('Clear tile cache'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('copy-diagnostics')));
    await tester.pump();

    final copied = clipboardText ?? '';
    expect(copied, contains('"schema_version": 1'));
    expect(copied, isNot(contains('abc.def')));
    expect(copied, isNot(contains('still-secret')));
    expect(copied, isNot(contains('VerySensitiveSecretValue')));
    expect(copied, isNot(contains('provider_secretcode')));
    expect(copied, contains('Bearer [redacted]'));
    expect(copied, contains('Authorization: [redacted]'));

    await tester.tap(find.text('Maintenance'));
    await tester.pumpAndSettle();
    expect(find.text('Clear diagnostics'), findsOneWidget);
    expect(find.text('Clear tile cache'), findsOneWidget);
    expect(find.text('Clear active route'), findsOneWidget);
    expect(find.text('Clear provider validation cache'), findsOneWidget);
  });

  testWidgets('preference detail screens update watch and map settings', (
    tester,
  ) async {
    final provider = TestProviderRepository(status: _readyProvider);
    final dispatcher = TestWatchDispatcher(providerStatus: _readyProvider);

    await _pumpReadyMappy(tester, provider: provider, dispatcher: dispatcher);
    await _selectTab(tester, 'Settings');

    await tester.tap(find.widgetWithText(ListTile, 'Navigation'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Units'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Imperial'));
    await tester.pumpAndSettle();
    expect(dispatcher.unitsMode, WatchUnitsMode.imperial);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Appearance'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Theme'), findsNothing);
    expect(find.text('Auto'), findsNothing);
    expect(find.text('Day'), findsNothing);
    expect(find.text('Night'), findsNothing);
    await tester.tap(find.widgetWithText(ListTile, 'Backlight'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Keep on'));
    await tester.pumpAndSettle();
    expect(dispatcher.backlightMode, WatchBacklightMode.keepOn);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Watch map'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Orientation'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Face forward'));
    await tester.pumpAndSettle();
    expect(dispatcher.mapOrientation, WatchMapOrientation.forwardUp);

    await tester.tap(find.widgetWithText(ListTile, 'Tile source'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Satellite'));
    await tester.pumpAndSettle();
    expect(provider.currentMapSettings.source, MapTileSource.satellite);
    expect(provider.mapSettingsSaveCount, 1);
    expect(dispatcher.displaySettingsSaveCount, 3);
  });

  testWidgets('saved locations use add, editor, and confirmed delete flows', (
    tester,
  ) async {
    final provider = TestProviderRepository(
      status: _readyProvider,
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
          status: _readyProvider,
          latitude: -36.84846,
          longitude: 174.76333,
          label: 'Auckland Home',
          formattedAddress: '1 Queen Street, Auckland',
          placeId: 'place-home',
        ),
      },
    );
    final dispatcher = TestWatchDispatcher(providerStatus: _readyProvider);

    await _pumpReadyMappy(tester, provider: provider, dispatcher: dispatcher);
    await _selectTab(tester, 'Saved');

    expect(find.text('No saved locations'), findsOneWidget);
    expect(find.byKey(const ValueKey('saved-location-name')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('saved-location-add')));
    await tester.pumpAndSettle();

    expect(find.text('Add saved location'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('saved-location-name')),
      'Primary Home',
    );
    await tester.enterText(
      find.byKey(const ValueKey('saved-location-search')),
      'Auckland Home',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Auckland Home'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Walk'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('saved-location-save')));
    await tester.pumpAndSettle();

    expect(dispatcher.savedDestinations, hasLength(1));
    expect(dispatcher.savedDestinations.single.slotIndex, 0);
    expect(dispatcher.savedDestinations.single.label, 'Primary Home');
    expect(
      dispatcher.savedDestinations.single.address,
      '1 Queen Street, Auckland',
    );
    expect(
      dispatcher.savedDestinations.single.defaultTravelMode,
      WatchTravelMode.walk,
    );
    expect(find.text('Primary Home saved.'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    final savedTileFinder = find.byKey(const ValueKey('saved-location-slot-0'));
    expect(savedTileFinder, findsOneWidget);
    expect(find.text('Primary Home'), findsOneWidget);
    final savedTile = tester.widget<ListTile>(savedTileFinder);
    expect(
      (savedTile.subtitle! as Text).data,
      contains('1 Queen Street, Auckland'),
    );

    await tester.tap(savedTileFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(dispatcher.savedDestinations, isEmpty);
    expect(find.text('No saved locations'), findsOneWidget);
  });

  testWidgets('failed saved-location delete keeps the editor open', (
    tester,
  ) async {
    final dispatcher = TestWatchDispatcher(
      providerStatus: _readyProvider,
      destinations: const [
        WatchDestinationConfig(
          slotIndex: 0,
          label: 'Primary Home',
          address: '1 Queen Street, Auckland',
          latitude: -36.84846,
          longitude: 174.76333,
          kind: 0,
          defaultTravelMode: WatchTravelMode.walk,
        ),
      ],
      replaceDestinationFailure: 'Watch rejected deletion.',
    );

    await _pumpReadyMappy(tester, dispatcher: dispatcher);
    await _selectTab(tester, 'Saved');
    await tester.tap(find.byKey(const ValueKey('saved-location-slot-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(dispatcher.savedDestinations, hasLength(1));
    expect(find.text('Watch rejected deletion.'), findsOneWidget);
    expect(find.byTooltip('More actions'), findsOneWidget);
  });

  testWidgets('Saved editor unlocks after completing Google setup in context', (
    tester,
  ) async {
    final provider = TestProviderRepository();
    await _pumpMappy(
      tester,
      provider: provider,
      location: TestLocationRepository(accessStatus: _readyLocationAccess),
    );
    await _selectTab(tester, 'Saved');
    await tester.tap(find.byKey(const ValueKey('saved-location-add')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('saved-location-name')))
          .enabled,
      isFalse,
    );
    await tester.tap(find.text('Set up Google Maps'));
    await tester.pumpAndSettle();

    provider.status = _readyProvider;
    await tester.enterText(
      find.byKey(const ValueKey('google-api-key-input')),
      'AIza0123456789abcdefghijklmnopqrstuvwxy',
    );
    await tester.tap(find.byKey(const ValueKey('save-and-validate-key')));
    await tester.pumpAndSettle();
    expect(find.text('Google services ready'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('saved-location-name')))
          .enabled,
      isTrue,
    );
    expect(find.text('Set up Google Maps'), findsNothing);
  });

  for (final firstResponseArrivesEarly in [true, false]) {
    final order = firstResponseArrivesEarly ? 'before' : 'after';
    testWidgets(
      'late GPS refreshes autocomplete when original results arrive $order nearby results',
      (tester) async {
        final provider = ControlledAutocompleteProvider();
        final location = DeferredSearchLocationRepository();
        await _pumpReadyMappy(tester, provider: provider, location: location);
        final field = find.byKey(
          const ValueKey('status-navigate-destination-search'),
        );

        await tester.enterText(field, 'Cafe');
        await tester.pump(const Duration(milliseconds: 400));
        expect(location.requests, [
          const Duration(milliseconds: 1200),
          const Duration(seconds: 8),
        ]);
        expect(provider.requests, hasLength(1));
        expect(provider.requests.first.latitude, isNull);
        expect(provider.requests.first.longitude, isNull);
        if (firstResponseArrivesEarly) {
          provider.requests.first.complete('Distant cafe');
          await tester.pumpAndSettle();
          expect(find.text('Distant cafe'), findsOneWidget);
        }

        location.lateFix.complete(_freshLocation());
        await tester.pump();
        await tester.pump();
        expect(provider.requests, hasLength(2));
        final nearby = provider.requests.last;
        expect(nearby.input, 'Cafe');
        expect(nearby.latitude, 37.41973);
        expect(nearby.longitude, -122.08278);
        expect(nearby.sessionToken, provider.requests.first.sessionToken);
        expect(nearby.role, PlaceSearchRole.destination);
        nearby.complete('Nearby cafe');
        await tester.pumpAndSettle();
        if (!firstResponseArrivesEarly) {
          provider.requests.first.complete('Distant cafe');
          await tester.pumpAndSettle();
        }
        expect(find.text('Nearby cafe'), findsOneWidget);
        expect(find.text('Distant cafe'), findsNothing);
        expect(tester.widget<TextField>(field).controller!.text, 'Cafe');
        expect(location.foregroundRequestCount, 0);
        expect(provider.requests, hasLength(2));
      },
    );
  }

  testWidgets('GPS arriving during debounce uses one biased search', (
    tester,
  ) async {
    final provider = ControlledAutocompleteProvider();
    final location = DeferredSearchLocationRepository();
    await _pumpReadyMappy(tester, provider: provider, location: location);

    await tester.enterText(
      find.byKey(const ValueKey('status-navigate-destination-search')),
      'Cafe',
    );
    location.lateFix.complete(_freshLocation());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(provider.requests, hasLength(1));
    expect(provider.requests.single.latitude, 37.41973);
    expect(provider.requests.single.longitude, -122.08278);
    provider.requests.single.complete('Nearby cafe');
    await tester.pumpAndSettle();
    expect(find.text('Nearby cafe'), findsOneWidget);
  });

  for (final chooseMapPin in [false, true]) {
    final selection = chooseMapPin ? 'a dropped pin' : 'cleared input';
    testWidgets('late GPS and search responses respect $selection', (
      tester,
    ) async {
      final provider = ControlledAutocompleteProvider();
      final location = DeferredSearchLocationRepository();
      await _pumpReadyMappy(tester, provider: provider, location: location);
      final field = find.byKey(
        const ValueKey('status-navigate-destination-search'),
      );
      await tester.enterText(field, 'Cafe');
      await tester.pump(const Duration(milliseconds: 400));
      if (chooseMapPin) {
        await tester.tapAt(
          tester.getCenter(
            find.byKey(const ValueKey('status-navigate-destination-map')),
          ),
        );
      } else {
        await tester.enterText(field, '');
      }
      await tester.pump();
      final selectedText = tester.widget<TextField>(field).controller!.text;

      location.lateFix.complete(_freshLocation());
      provider.requests.single.complete('Distant cafe');
      await tester.pumpAndSettle();
      expect(provider.requests, hasLength(1));
      expect(find.text('Distant cafe'), findsNothing);
      expect(tester.widget<TextField>(field).controller!.text, selectedText);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      if (chooseMapPin) expect(find.text('Dropped Pin'), findsOneWidget);
    });
  }

  testWidgets(
    'missing GPS does not delay search and keystrokes share a location request',
    (tester) async {
      final provider = ControlledAutocompleteProvider();
      final location = DeferredSearchLocationRepository();
      await _pumpReadyMappy(tester, provider: provider, location: location);
      final field = find.byKey(
        const ValueKey('status-navigate-destination-search'),
      );
      await tester.enterText(field, 'Cafe');
      await tester.enterText(field, 'Cafe near me');
      await tester.pump(const Duration(milliseconds: 400));
      expect(location.requests, hasLength(2));
      expect(provider.requests.single.input, 'Cafe near me');
      provider.requests.single.complete('Cafe result');
      await tester.pumpAndSettle();
      expect(find.text('Cafe result'), findsOneWidget);

      location.lateFix.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('Cafe result'), findsOneWidget);
      expect(provider.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an old startup fix is refreshed during autocomplete', (
    tester,
  ) async {
    final provider = ControlledAutocompleteProvider();
    final location = DeferredSearchLocationRepository(
      location: LocationSnapshot(
        latitude: -36.85,
        longitude: 174.76,
        timestamp: DateTime.now().subtract(const Duration(minutes: 2)),
        isFresh: true,
      ),
    );
    await _pumpReadyMappy(tester, provider: provider, location: location);
    await tester.enterText(
      find.byKey(const ValueKey('status-navigate-destination-search')),
      'Cafe',
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(location.requests, hasLength(2));
    expect(provider.requests.single.latitude, -36.85);
    provider.requests.single.complete('Previous area');
    await tester.pumpAndSettle();

    location.lateFix.complete(_freshLocation());
    await tester.pump();
    await tester.pump();
    expect(provider.requests.last.latitude, 37.41973);
    provider.requests.last.complete('Current area');
    await tester.pumpAndSettle();
    expect(find.text('Current area'), findsOneWidget);
    expect(find.text('Previous area'), findsNothing);
  });
  testWidgets('a map tap selects a destination before any search', (
    tester,
  ) async {
    final provider = TestProviderRepository(status: _readyProvider);
    final dispatcher = TestWatchDispatcher(providerStatus: _readyProvider);
    await _pumpReadyMappy(tester, provider: provider, dispatcher: dispatcher);

    final map = find.byKey(const ValueKey('status-navigate-destination-map'));
    final destination = find.byKey(
      const ValueKey('status-navigate-destination-search'),
    );
    final start = find.byKey(const ValueKey('status-navigate-now'));
    final mapElement = tester.element(map);
    expect(
      tester.getBottomLeft(map).dy,
      lessThan(tester.getTopLeft(destination).dy),
    );
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    expect(find.text('Tap the map to choose a destination'), findsOneWidget);

    await tester.tapAt(tester.getCenter(map));
    await tester.pumpAndSettle();
    expect(find.text('Dropped Pin'), findsOneWidget);
    expect(
      tester.widget<TextField>(destination).controller!.text,
      '37.41973, -122.08278',
    );
    expect(tester.widget<FilledButton>(start).onPressed, isNotNull);
    expect(provider.searchRequests, 0);

    await _selectTab(tester, 'Saved');
    await _selectTab(tester, 'Navigate');
    expect(find.text('Dropped Pin'), findsOneWidget);
    expect(tester.element(map), same(mapElement));

    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pumpAndSettle();
    final request = dispatcher.lastNavigationRequest!;
    expect(request.destination.label, 'Dropped Pin');
    expect(request.destination.latitude, 37.41973);
    expect(request.destination.longitude, -122.08278);
    expect(request.destination.placeId, isNull);
    expect(dispatcher.routeStarts, 1);
    expect(tester.element(map), same(mapElement));

    await tester.tapAt(tester.getCenter(map));
    await tester.pumpAndSettle();
    expect(find.text('Active navigation'), findsOneWidget);
    expect(find.byKey(const ValueKey('status-map-use-center')), findsNothing);
    expect(dispatcher.routeStarts, 1);

    await tester.tap(find.byKey(const ValueKey('end-navigation')));
    await tester.pumpAndSettle();
    expect(tester.element(map), same(mapElement));
    expect(tester.widget<TextField>(destination).controller!.text, isEmpty);
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    expect(find.text('Tap the map to choose a destination'), findsOneWidget);
  });

  testWidgets('a map tap cancels pending destination autocomplete', (
    tester,
  ) async {
    final provider = _routingProvider();
    await _pumpReadyMappy(tester, provider: provider);
    final destination = find.byKey(
      const ValueKey('status-navigate-destination-search'),
    );
    await tester.enterText(destination, 'Googleplex');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(
      tester.getCenter(
        find.byKey(const ValueKey('status-navigate-destination-map')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));

    expect(provider.searchRequests, 0);
    expect(
      tester.widget<TextField>(destination).controller!.text,
      '37.41973, -122.08278',
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.widgetWithText(ListTile, 'Googleplex'), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets(
    'destination map stays visible while controls scroll and keyboard opens',
    (tester) async {
      await _pumpReadyMappy(
        tester,
        surfaceSize: const Size(320, 720),
        textScaleFactor: 2,
      );
      final map = find.byKey(const ValueKey('status-navigate-destination-map'));
      final originalBounds = tester.getRect(map);
      await tester.tapAt(originalBounds.center);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('status-navigate-now')),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(map), originalBounds);
      expect(tester.takeException(), isNull);

      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.getRect(map).height, greaterThan(0));
      expect(tester.getRect(map).top, originalBounds.top);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Navigate starts, reroutes, and ends an active route', (
    tester,
  ) async {
    final provider = _routingProvider();
    final dispatcher = TestWatchDispatcher(providerStatus: _readyProvider);

    await _pumpReadyMappy(
      tester,
      provider: provider,
      dispatcher: dispatcher,
      location: TestLocationRepository(
        accessStatus: _readyLocationAccess,
        location: _freshLocation(),
      ),
    );

    final destinationField = find.byKey(
      const ValueKey('status-navigate-destination-search'),
    );
    await tester.enterText(destinationField, 'Googleplex');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(provider.lastSearchOriginLatitude, 37.41973);
    expect(provider.lastSearchOriginLongitude, -122.08278);
    await tester.tap(find.widgetWithText(ListTile, 'Googleplex'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('status-navigate-destination-map')),
      findsOneWidget,
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey('status-navigate-now')),
    );
    await tester.tap(find.byKey(const ValueKey('status-navigate-now')));
    await tester.pumpAndSettle();

    expect(dispatcher.routeStarts, 1);
    expect(find.text('Active navigation'), findsOneWidget);
    expect(find.text('Googleplex'), findsOneWidget);
    expect(find.text('1600 Amphitheatre Pkwy'), findsOneWidget);
    expect(find.text('1.2 km, 7 min'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reroute-active')));
    await tester.pumpAndSettle();
    expect(dispatcher.reroutes, 1);
    expect(
      find.text('Route refreshed and confirmed on watch.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('end-navigation')));
    await tester.pumpAndSettle();
    expect(dispatcher.clears, 1);
    expect(find.text('Active navigation'), findsNothing);
    expect(find.text('New route'), findsOneWidget);
  });

  testWidgets('Navigate supports an explicit origin selected from a sheet', (
    tester,
  ) async {
    final provider = TestProviderRepository(
      status: _readyProvider,
      suggestionsByRole: const {
        PlaceSearchRole.origin: [
          PlaceAutocompleteSuggestion(
            placeId: 'library',
            primaryText: 'Auckland Library',
            secondaryText: 'Lorne Street',
            fullText: 'Auckland Library, Lorne Street',
          ),
        ],
        PlaceSearchRole.destination: [
          PlaceAutocompleteSuggestion(
            placeId: 'museum',
            primaryText: 'Auckland Museum',
            secondaryText: 'Auckland Domain',
            fullText: 'Auckland Museum, Auckland Domain',
          ),
        ],
      },
      resolutionsByPlaceId: const {
        'library': PlaceResolutionResult(
          ok: true,
          status: _readyProvider,
          latitude: -36.85157,
          longitude: 174.76514,
          label: 'Auckland Library',
          formattedAddress: '44 Lorne Street, Auckland',
          placeId: 'library',
        ),
        'museum': PlaceResolutionResult(
          ok: true,
          status: _readyProvider,
          latitude: -36.86097,
          longitude: 174.77774,
          label: 'Auckland Museum',
          formattedAddress: 'Auckland Domain, Parnell',
          placeId: 'museum',
        ),
      },
    );
    final dispatcher = TestWatchDispatcher(providerStatus: _readyProvider);

    await _pumpReadyMappy(tester, provider: provider, dispatcher: dispatcher);

    await tester.tap(find.text('From current'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a place'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('status-navigate-origin-search')),
      'library',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Auckland Library'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('status-navigate-destination-search')),
      'museum',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Auckland Museum'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey('status-navigate-now')),
    );
    await tester.tap(find.byKey(const ValueKey('status-navigate-now')));
    await tester.pumpAndSettle();

    final request = dispatcher.lastNavigationRequest;
    expect(request?.originPolicy, WatchRouteOriginPolicy.explicitPlace);
    expect(request?.origin?.latitude, -36.85157);
    expect(request?.origin?.longitude, 174.76514);
    expect(request?.destination.latitude, -36.86097);
    expect(request?.destination.longitude, 174.77774);
  });

  testWidgets('restored route shows metadata without invented route metrics', (
    tester,
  ) async {
    final activeRoute = WatchActiveRoute(
      requestId: 42,
      originPolicy: WatchRouteOriginPolicy.currentLocation,
      destination: const WatchRouteEndpoint(
        label: 'Auckland Museum',
        address: 'Auckland Domain, Parnell',
        latitude: -36.86097,
        longitude: 174.77774,
        placeId: 'museum',
      ),
      travelMode: WatchTravelMode.walk,
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    final dispatcher = TestWatchDispatcher(
      providerStatus: _readyProvider,
      activeRoute: activeRoute,
    );
    final bridge = TestBridgeRepository(
      status: _bridgeStatus(
        providerStatus: _readyProvider,
        locationAccess: _readyLocationAccess,
        notification: NotificationPermissionState.granted,
      ),
      setupChecklistVersion: 0,
    );

    await _pumpReadyMappy(tester, bridge: bridge, dispatcher: dispatcher);

    expect(find.text('Active navigation'), findsOneWidget);
    expect(find.text('Set up Mappy'), findsNothing);
    expect(bridge.setupChecklistWriteCount, 0);
    expect(find.text('Auckland Museum'), findsOneWidget);
    expect(find.text('Auckland Domain, Parnell'), findsOneWidget);
    expect(find.text('Walk'), findsOneWidget);
    expect(find.text('1.2 km, 7 min'), findsNothing);
    expect(find.byKey(const ValueKey('reroute-active')), findsOneWidget);
    expect(find.byKey(const ValueKey('end-navigation')), findsOneWidget);
  });

  testWidgets(
    'malformed route events and shares do not displace active route',
    (tester) async {
      final events = StreamController<BridgeEvent>.broadcast(sync: true);
      addTearDown(events.close);
      final bridge = TestBridgeRepository(
        status: _bridgeStatus(
          providerStatus: _readyProvider,
          locationAccess: _readyLocationAccess,
          notification: NotificationPermissionState.granted,
        ),
        eventStream: events.stream,
        setupChecklistVersion: 0,
      );
      final dispatcher = TestWatchDispatcher(
        providerStatus: _readyProvider,
        activeRoute: _activeRoute(),
      );
      await _pumpReadyMappy(tester, bridge: bridge, dispatcher: dispatcher);

      events.add(BridgeEvent.fromEventChannel({'event': 'activeRouteChanged'}));
      events.add(
        const BridgeEvent(
          type: 'shareStatus',
          shareStatus: ShareRoutingStatus(
            state: 'parsing',
            detail: 'Reading a new share.',
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Active navigation'), findsOneWidget);
      expect(find.text('Parsing Share'), findsNothing);
      expect(find.byKey(const ValueKey('end-navigation')), findsOneWidget);
      expect(bridge.setupChecklistWriteCount, 0);
    },
  );

  testWidgets('incoming share processing takes priority over first-run setup', (
    tester,
  ) async {
    final bridge = TestBridgeRepository(
      status: _bridgeStatus(
        providerStatus: _readyProvider,
        locationAccess: _readyLocationAccess,
        notification: NotificationPermissionState.granted,
      ),
      setupChecklistVersion: 0,
      eventStream: Stream.value(
        BridgeEvent.fromEventChannel({
          'event': 'shareStatus',
          'state': 'parsing',
          'detail': 'Reading the shared Google Maps item.',
        }),
      ),
    );

    await _pumpReadyMappy(tester, bridge: bridge, settle: false);

    expect(find.text('Parsing Share'), findsOneWidget);
    expect(find.text('Reading the shared Google Maps item.'), findsOneWidget);
    expect(find.text('Set up Mappy'), findsNothing);
    expect(bridge.setupChecklistWriteCount, 0);
  });

  testWidgets('share failures are compact and dismissible', (tester) async {
    final bridge = TestBridgeRepository(
      status: _bridgeStatus(
        providerStatus: _readyProvider,
        locationAccess: _readyLocationAccess,
        notification: NotificationPermissionState.granted,
      ),
      eventStream: Stream.value(
        BridgeEvent.fromEventChannel({
          'event': 'shareStatus',
          'state': 'error',
          'detail': 'The shared link could not be resolved.',
        }),
      ),
    );

    await _pumpReadyMappy(tester, bridge: bridge);

    expect(find.text('Share Route Problem'), findsOneWidget);
    expect(find.text('The shared link could not be resolved.'), findsOneWidget);
    expect(find.byTooltip('Dismiss'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('Share Route Problem'), findsNothing);
  });

  testWidgets('unconfirmed share timeout is terminal and dismissible', (
    tester,
  ) async {
    final bridge = TestBridgeRepository(
      status: _bridgeStatus(
        providerStatus: _readyProvider,
        locationAccess: _readyLocationAccess,
        notification: NotificationPermissionState.granted,
      ),
      eventStream: Stream.value(
        BridgeEvent.fromEventChannel({
          'event': 'shareStatus',
          'state': 'queuedUnconfirmed',
          'detail': 'The route was queued, but the watch did not confirm it.',
        }),
      ),
    );

    await _pumpReadyMappy(tester, bridge: bridge);

    expect(find.text('Route Queued'), findsOneWidget);
    expect(find.byTooltip('Dismiss'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('Route Queued'), findsNothing);
  });

  testWidgets('Navigate remains usable on a narrow screen with large text', (
    tester,
  ) async {
    await _pumpReadyMappy(
      tester,
      surfaceSize: const Size(320, 720),
      textScaleFactor: 2,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('New route'), findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(OutlinedButton, 'Drive'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final originCenter = tester.getCenter(
      find.widgetWithText(OutlinedButton, 'From current'),
    );
    final modeCenter = tester.getCenter(
      find.widgetWithText(OutlinedButton, 'Drive'),
    );
    expect(originCenter.dx, closeTo(modeCenter.dx, 1));
    expect(originCenter.dy, lessThan(modeCenter.dy));
  });
}

Finder _navigationLabel(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

Future<void> _selectTab(WidgetTester tester, String label) async {
  await tester.tap(_navigationLabel(label));
  await tester.pumpAndSettle();
}

Future<void> _openSettingsPage(WidgetTester tester, String title) async {
  await _selectTab(tester, 'Settings');
  final tile = find.widgetWithText(ListTile, title);
  await tester.ensureVisible(tile);
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

bool _warningBadge(WidgetTester tester, Key rowKey) {
  final finder = find.descendant(
    of: find.byKey(rowKey),
    matching: find.byType(Badge),
  );
  return tester.widget<Badge>(finder).isLabelVisible;
}

Future<void> _pumpReadyMappy(
  WidgetTester tester, {
  TestProviderRepository? provider,
  TestLocationRepository? location,
  TestBridgeRepository? bridge,
  TestBatteryOptimizationRepository? battery,
  TestWatchDispatcher? dispatcher,
  Size surfaceSize = const Size(900, 1400),
  double textScaleFactor = 1,
  bool settle = true,
}) async {
  final effectiveProvider =
      provider ?? TestProviderRepository(status: _readyProvider);
  final effectiveLocation =
      location ??
      TestLocationRepository(
        accessStatus: _readyLocationAccess,
        location: _freshLocation(),
      );
  await _pumpMappy(
    tester,
    provider: effectiveProvider,
    location: effectiveLocation,
    bridge:
        bridge ??
        TestBridgeRepository(
          status: _bridgeStatus(
            providerStatus: effectiveProvider.status,
            locationAccess: effectiveLocation.accessStatus,
            notification: NotificationPermissionState.granted,
          ),
        ),
    battery:
        battery ??
        TestBatteryOptimizationRepository(
          state: BatteryOptimizationState.disabled,
        ),
    dispatcher:
        dispatcher ??
        TestWatchDispatcher(providerStatus: effectiveProvider.status),
    surfaceSize: surfaceSize,
    textScaleFactor: textScaleFactor,
    settle: settle,
  );
}

Future<void> _pumpMappy(
  WidgetTester tester, {
  required TestProviderRepository provider,
  required TestLocationRepository location,
  TestBridgeRepository? bridge,
  TestBatteryOptimizationRepository? battery,
  TestWatchDispatcher? dispatcher,
  Size surfaceSize = const Size(900, 1400),
  double textScaleFactor = 1,
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  tester.binding.platformDispatcher.textScaleFactorTestValue = textScaleFactor;
  addTearDown(tester.binding.platformDispatcher.clearTextScaleFactorTestValue);
  final effectiveBridge =
      bridge ??
      TestBridgeRepository(
        status: _bridgeStatus(
          providerStatus: provider.status,
          locationAccess: location.accessStatus,
          notification: NotificationPermissionState.granted,
        ),
      );
  await tester.pumpWidget(
    MappyApp(
      locationRepository: location,
      providerRepository: provider,
      bridgeRepository: effectiveBridge,
      batteryOptimizationRepository:
          battery ??
          TestBatteryOptimizationRepository(
            state: BatteryOptimizationState.disabled,
          ),
      watchDispatcher:
          dispatcher ?? TestWatchDispatcher(providerStatus: provider.status),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    for (var i = 0; i < 5; i += 1) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }
}

BridgeStatus _bridgeStatus({
  required ProviderStatus providerStatus,
  required LocationAccessStatus locationAccess,
  required NotificationPermissionState notification,
  bool watchReady = false,
  bool gpsStreaming = false,
}) {
  return BridgeStatus(
    registered: true,
    watchReady: watchReady,
    watchConnected: watchReady,
    watchAppActive: watchReady,
    foregroundServiceActive: watchReady,
    queueLength: 0,
    inFlight: false,
    setupState: providerStatus.validationState == ProviderValidationState.valid
        ? locationAccess.isReady
              ? BridgeSetupState.ready
              : BridgeSetupState.locationRequired
        : BridgeSetupState.providerRequired,
    permissionState: locationAccess.legacyPermissionState,
    locationAccessStatus: locationAccess,
    notificationPermissionState: notification,
    providerStatus: providerStatus,
    gpsStreamRequested: gpsStreaming,
    gpsStreaming: gpsStreaming,
    gpsStreamProviders: gpsStreaming ? const ['gps'] : const [],
  );
}

LocationSnapshot _freshLocation() => LocationSnapshot(
  latitude: 37.41973,
  longitude: -122.08278,
  timestamp: DateTime.now(),
  accuracyMeters: 8,
  provider: 'gps',
  isFresh: true,
);

WatchActiveRoute _activeRoute() => WatchActiveRoute(
  requestId: 42,
  originPolicy: WatchRouteOriginPolicy.currentLocation,
  destination: const WatchRouteEndpoint(
    label: 'Auckland Museum',
    address: 'Auckland Domain, Parnell',
    latitude: -36.86097,
    longitude: 174.77774,
    placeId: 'museum',
  ),
  travelMode: WatchTravelMode.walk,
  updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
);

TestProviderRepository _routingProvider() {
  return TestProviderRepository(
    status: _readyProvider,
    suggestionsByRole: const {
      PlaceSearchRole.destination: [
        PlaceAutocompleteSuggestion(
          placeId: 'googleplex',
          primaryText: 'Googleplex',
          secondaryText: 'Mountain View, CA',
          fullText: 'Googleplex, Mountain View, CA',
        ),
      ],
    },
    resolutionsByPlaceId: const {
      'googleplex': PlaceResolutionResult(
        ok: true,
        status: _readyProvider,
        latitude: 37.42228,
        longitude: -122.08434,
        label: 'Googleplex',
        formattedAddress: '1600 Amphitheatre Pkwy',
        placeId: 'googleplex',
      ),
    },
  );
}

class TestLocationRepository extends LocationRepository {
  TestLocationRepository({required this.accessStatus, this.location});

  LocationAccessStatus accessStatus;
  LocationAccessStatus? requestedAccessStatus;
  LocationSnapshot? location;
  int foregroundRequestCount = 0;
  int openAppSettingsCount = 0;
  int openLocationServicesCount = 0;

  @override
  Future<LocationPermissionState> getPermissionState() async =>
      accessStatus.legacyPermissionState;

  @override
  Future<LocationAccessStatus> getLocationAccessStatus() async => accessStatus;

  @override
  Future<LocationSnapshot?> getCurrentLocation({Duration? timeout}) async =>
      location;

  @override
  Future<LocationPermissionState> requestLocationPermission() async =>
      (await requestForegroundLocationPermission()).legacyPermissionState;

  @override
  Future<LocationAccessStatus> requestForegroundLocationPermission() async {
    foregroundRequestCount++;
    accessStatus = requestedAccessStatus ?? accessStatus;
    return accessStatus;
  }

  @override
  Future<bool> openAppLocationSettings() async {
    openAppSettingsCount++;
    return true;
  }

  @override
  Future<bool> openLocationServicesSettings() async {
    openLocationServicesCount++;
    return true;
  }
}

class TestBridgeRepository extends BridgeRepository {
  TestBridgeRepository({
    required this.status,
    this.requestedStatus,
    this.eventStream = const Stream<BridgeEvent>.empty(),
    this.diagnostics = const <String, Object?>{
      'schema_version': 1,
      'events': <Object?>[],
    },
    this.setupChecklistVersion = setupChecklistCurrentVersion,
    this.setupChecklistWriteSucceeds = true,
  });

  BridgeStatus status;
  final BridgeStatus? requestedStatus;
  final Stream<BridgeEvent> eventStream;
  final Map<String, Object?> diagnostics;
  int setupChecklistVersion;
  final bool setupChecklistWriteSucceeds;
  int setupChecklistReadCount = 0;
  int setupChecklistWriteCount = 0;
  int notificationRequestCount = 0;
  int openNotificationSettingsCount = 0;
  int openWatchCount = 0;

  @override
  Stream<BridgeEvent> get events => eventStream;

  @override
  Future<void> clearDiagnostics() async {}

  @override
  Future<Map<String, Object?>> exportDiagnostics() async => diagnostics;

  @override
  Future<BridgeStatus> getBridgeStatus() async => status;

  @override
  Future<int> getSetupChecklistVersion() async {
    setupChecklistReadCount++;
    return setupChecklistVersion;
  }

  @override
  Future<bool> openNotificationSettings() async {
    openNotificationSettingsCount++;
    return true;
  }

  @override
  Future<BridgeStatus> requestNotificationPermission() async {
    notificationRequestCount++;
    status = requestedStatus ?? status;
    return status;
  }

  @override
  Future<bool> setSetupChecklistVersion(int version) async {
    setupChecklistWriteCount++;
    if (!setupChecklistWriteSucceeds) return false;
    setupChecklistVersion = version;
    return true;
  }

  @override
  Future<BridgeStatus> startWatchApp() async {
    openWatchCount++;
    return status;
  }
}

class DeferredChecklistVersionBridgeRepository extends TestBridgeRepository {
  DeferredChecklistVersionBridgeRepository({required super.status});

  final Completer<int> version = Completer<int>();

  @override
  Future<int> getSetupChecklistVersion() {
    setupChecklistReadCount += 1;
    return version.future;
  }
}

class TestBatteryOptimizationRepository
    implements BatteryOptimizationRepository {
  TestBatteryOptimizationRepository({required this.state, this.requestedState});

  BatteryOptimizationState state;
  final BatteryOptimizationState? requestedState;
  int requestCount = 0;

  @override
  Future<BatteryOptimizationState> getBatteryOptimizationState() async => state;

  @override
  Future<bool> openBatterySettings() async {
    openSettingsCount++;
    return settingsOpened;
  }

  int openSettingsCount = 0;
  bool settingsOpened = true;

  @override
  Future<BatteryOptimizationState> requestDisableBatteryOptimization() async {
    requestCount++;
    state = requestedState ?? state;
    return state;
  }
}

class TestProviderRepository implements ProviderRepository {
  TestProviderRepository({
    this.status = const ProviderStatus.notConfigured(),
    this.currentMapSettings = MapTileSettings.defaults,
    this.suggestionsByRole = const {},
    this.resolutionsByPlaceId = const {},
    this.geocodeResult,
    this.routeResult,
  });

  ProviderStatus status;
  MapTileSettings currentMapSettings;
  final Map<PlaceSearchRole, List<PlaceAutocompleteSuggestion>>
  suggestionsByRole;
  final Map<String, PlaceResolutionResult> resolutionsByPlaceId;
  final GeocodeResult? geocodeResult;
  final RouteResult? routeResult;
  int mapSettingsSaveCount = 0;
  int searchRequests = 0;
  double? lastSearchOriginLatitude;
  double? lastSearchOriginLongitude;

  @override
  Future<ProviderStatus> clearApiKey() async {
    status = const ProviderStatus.notConfigured();
    return status;
  }

  @override
  Future<MapTileSettingsResult> clearMapTileCache() async =>
      MapTileSettingsResult(
        ok: true,
        status: status,
        settings: currentMapSettings,
        changed: true,
        detail: 'Map tile caches were cleared.',
      );

  @override
  Future<ProviderStatus> clearProviderValidationCache() async => status;

  @override
  Future<PlaceAutocompleteResult> autocompleteDestination({
    required String input,
    double? originLatitude,
    double? originLongitude,
    String? sessionToken,
    String language = 'en-US',
    String region = 'US',
  }) => searchPlaces(
    input: input,
    originLatitude: originLatitude,
    originLongitude: originLongitude,
    sessionToken: sessionToken,
    language: language,
    region: region,
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
  }) async => routeResult ?? RouteResult(ok: false, status: status);

  @override
  Future<GeocodeResult> geocodeDestination({
    required String addressText,
    String language = 'en-US',
    String region = 'US',
  }) async => geocodeResult ?? GeocodeResult(ok: false, status: status);

  @override
  Future<MapTileSettingsResult> getMapTileSettings() async =>
      MapTileSettingsResult(
        ok: true,
        status: status,
        settings: currentMapSettings,
      );

  @override
  Future<PreviewTileResult> getPreviewTile({
    required double latitude,
    required double longitude,
    int zoom = 16,
  }) async => PreviewTileResult(status: status);

  @override
  Future<ProviderStatus> getProviderStatus() async => status;

  @override
  Future<WatchTileResult> getWatchTile({
    required int worldX,
    required int worldY,
    required int zoom,
  }) async => WatchTileResult(
    ok: false,
    status: status,
    worldX: worldX,
    worldY: worldY,
    zoom: zoom,
  );

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
  Future<MapTileSettingsResult> setMapTileSettings(
    MapTileSettings settings,
  ) async {
    mapSettingsSaveCount++;
    currentMapSettings = settings;
    return MapTileSettingsResult(
      ok: true,
      status: status,
      settings: settings,
      changed: true,
      detail: 'Map tile settings updated; tile caches were cleared.',
      watchMessage: WatchMessage.command(WatchCommands.mapSettings, {
        WatchKeys.buttonId: settings.source.index,
        WatchKeys.totalBytes: mapSettingsSaveCount,
      }),
    );
  }

  @override
  Future<ProviderStatus> storeApiKey(String apiKey) async => status;

  @override
  Future<ProviderStatus> validateProviderSetup() async => status;
}

class DeferredSearchLocationRepository extends TestLocationRepository {
  DeferredSearchLocationRepository({super.location})
    : super(accessStatus: _readyLocationAccess);

  final requests = <Duration?>[];
  final lateFix = Completer<LocationSnapshot?>();

  @override
  Future<LocationSnapshot?> getCurrentLocation({Duration? timeout}) {
    requests.add(timeout);
    return requests.length == 1 ? Future.value(location) : lateFix.future;
  }
}

class PendingAutocompleteRequest {
  PendingAutocompleteRequest({
    required this.input,
    required this.role,
    required this.latitude,
    required this.longitude,
    required this.sessionToken,
  });

  final String input;
  final PlaceSearchRole role;
  final double? latitude;
  final double? longitude;
  final String? sessionToken;
  final result = Completer<PlaceAutocompleteResult>();

  void complete(String name) {
    result.complete(
      PlaceAutocompleteResult(
        ok: true,
        status: _readyProvider,
        suggestions: [
          PlaceAutocompleteSuggestion(
            placeId: name,
            primaryText: name,
            secondaryText: '',
            fullText: name,
          ),
        ],
      ),
    );
  }
}

class ControlledAutocompleteProvider extends TestProviderRepository {
  ControlledAutocompleteProvider() : super(status: _readyProvider);
  final requests = <PendingAutocompleteRequest>[];

  @override
  Future<PlaceAutocompleteResult> searchPlaces({
    required String input,
    PlaceSearchRole role = PlaceSearchRole.destination,
    double? originLatitude,
    double? originLongitude,
    String? sessionToken,
    String language = 'en-US',
    String region = 'US',
  }) {
    final request = PendingAutocompleteRequest(
      input: input,
      role: role,
      latitude: originLatitude,
      longitude: originLongitude,
      sessionToken: sessionToken,
    );
    requests.add(request);
    return request.result.future;
  }
}

class DeferredFirstProviderRepository extends TestProviderRepository {
  DeferredFirstProviderRepository({required super.status});

  final Completer<ProviderStatus> firstStatus = Completer<ProviderStatus>();
  int statusRequestCount = 0;

  @override
  Future<ProviderStatus> getProviderStatus() {
    statusRequestCount += 1;
    if (statusRequestCount == 1) return firstStatus.future;
    return super.getProviderStatus();
  }
}

class TestWatchDispatcher implements WatchMessageDispatcher {
  TestWatchDispatcher({
    required this.providerStatus,
    List<WatchDestinationConfig>? destinations,
    this.activeRoute,
    this.replaceDestinationFailure,
  }) : savedDestinations = List.of(destinations ?? const []);

  final ProviderStatus providerStatus;
  final List<WatchMessage> phoneMessages = [];
  final List<WatchDestinationConfig> savedDestinations;
  WatchActiveRoute? activeRoute;
  final String? replaceDestinationFailure;
  WatchNavigationRequest? lastNavigationRequest;
  WatchTravelMode travelMode = WatchTravelMode.drive;
  WatchUnitsMode unitsMode = WatchUnitsMode.metric;
  WatchBacklightMode backlightMode = WatchBacklightMode.system;
  WatchNavigationFeedbackMode hapticMode = WatchNavigationFeedbackMode.all;
  WatchNavigationFeedbackMode glanceMode = WatchNavigationFeedbackMode.all;
  WatchMapOrientation mapOrientation = WatchMapOrientation.northUp;
  WatchTileAnimationMode tileAnimationMode = WatchTileAnimationMode.fadeIn;
  int displaySettingsSaveCount = 0;
  int routeStarts = 0;
  int reroutes = 0;
  int clears = 0;
  int _requestId = 100;

  @override
  ProviderStatus get lastProviderStatus => providerStatus;

  @override
  Future<WatchNavigationDispatchResult> clearActiveRoute() async {
    clears++;
    activeRoute = null;
    return WatchNavigationDispatchResult(
      responses: [WatchMessage.command(WatchCommands.routeClear)],
      deliveryState: WatchNavigationDeliveryState.applied,
    );
  }

  @override
  Future<List<WatchDestinationConfig>> getDestinations() async =>
      List.unmodifiable(savedDestinations);

  @override
  Future<WatchDisplaySettings> getDisplaySettings() async =>
      WatchDisplaySettings(
        travelMode: travelMode,
        unitsMode: unitsMode,
        backlightMode: backlightMode,
        hapticMode: hapticMode,
        glanceMode: glanceMode,
        mapOrientation: mapOrientation,
        tileAnimationMode: tileAnimationMode,
      );

  @override
  Future<WatchMapOrientation> getMapOrientation() async => mapOrientation;

  @override
  Future<WatchActiveRoute?> getActiveRoute() async => activeRoute;

  @override
  Future<List<WatchMessage>> handleWatchMessage(WatchMessage message) async =>
      const [];

  @override
  Future<WatchNavigationDispatchResult> rerouteActiveRoute() async {
    reroutes++;
    return WatchNavigationDispatchResult(
      responses: _routeMessages(),
      deliveryState: WatchNavigationDeliveryState.applied,
    );
  }

  @override
  Future<List<WatchMessage>> replaceDestination(
    WatchDestinationConfig config,
  ) async {
    if (replaceDestinationFailure case final failure?) {
      return [
        WatchMessage.command(WatchCommands.errorState, {
          WatchKeys.instruction: failure,
        }),
      ];
    }
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
  Future<void> sendPhoneMessage(WatchMessage message) async {
    phoneMessages.add(message);
  }

  @override
  Future<List<WatchMessage>> setDisplaySettings(
    WatchDisplaySettings settings,
  ) async {
    travelMode = settings.travelMode;
    unitsMode = settings.unitsMode;
    backlightMode = settings.backlightMode;
    hapticMode = settings.hapticMode;
    glanceMode = settings.glanceMode;
    mapOrientation = settings.mapOrientation;
    tileAnimationMode = settings.tileAnimationMode;
    displaySettingsSaveCount++;
    final messages = settings.toMessages();
    phoneMessages.addAll(messages);
    return messages;
  }

  @override
  Future<WatchMessage> setMapOrientation(
    WatchMapOrientation orientation,
  ) async {
    mapOrientation = orientation;
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
    routeStarts++;
    lastNavigationRequest = request;
    activeRoute = WatchActiveRoute(
      requestId: ++_requestId,
      originPolicy: request.originPolicy,
      origin: request.origin,
      destination: request.destination,
      travelMode: request.travelMode,
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    return WatchNavigationDispatchResult(
      responses: _routeMessages(),
      deliveryState: WatchNavigationDeliveryState.applied,
      routeRequestId: _requestId,
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
