import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mappy/battery_optimization_bridge.dart';
import 'package:mappy/bridge_channel.dart';
import 'package:mappy/first_run_setup_checklist.dart';
import 'package:mappy/location_bridge.dart';
import 'package:mappy/provider_bridge.dart';
import 'package:mappy/settings_screens.dart';

const _validProvider = ProviderStatus(
  configured: true,
  validationState: ProviderValidationState.valid,
);

const _readyLocation = LocationAccessStatus(
  servicesEnabled: true,
  foregroundState: ForegroundLocationState.precise,
  backgroundRequired: true,
  backgroundGranted: true,
);

const _readyPermissions = PermissionsSnapshot(
  location: _readyLocation,
  notification: NotificationPermissionState.granted,
  battery: BatteryOptimizationState.disabled,
);

void main() {
  group('SetupChecklistSnapshot', () {
    test('keeps required and recommended readiness separate', () {
      const snapshot = SetupChecklistSnapshot(
        providerStatus: _validProvider,
        permissions: PermissionsSnapshot(
          location: LocationAccessStatus(
            servicesEnabled: true,
            foregroundState: ForegroundLocationState.approximate,
            backgroundRequired: true,
            backgroundGranted: true,
          ),
          notification: NotificationPermissionState.denied,
          battery: BatteryOptimizationState.enabled,
        ),
      );

      expect(snapshot.providerReady, isTrue);
      expect(snapshot.locationReady, isTrue);
      expect(snapshot.requiredReady, isTrue);
      expect(snapshot.reliabilityReady, isFalse);
      expect(snapshot.summary, 'Recommendations available');
    });

    test('requires successful provider validation and background location', () {
      const snapshot = SetupChecklistSnapshot(
        providerStatus: ProviderStatus(
          configured: true,
          validationState: ProviderValidationState.notValidated,
        ),
        permissions: PermissionsSnapshot(
          location: LocationAccessStatus(
            servicesEnabled: true,
            foregroundState: ForegroundLocationState.precise,
            backgroundRequired: true,
            backgroundGranted: false,
          ),
          notification: NotificationPermissionState.notRequired,
          battery: BatteryOptimizationState.disabled,
        ),
      );

      expect(snapshot.providerReady, isFalse);
      expect(snapshot.locationReady, isFalse);
      expect(snapshot.requiredReady, isFalse);
      expect(snapshot.reliabilityReady, isTrue);
      expect(snapshot.summary, 'Needs setup');
    });
  });

  testWidgets('required setup gates the primary action and can be deferred', (
    tester,
  ) async {
    var googleOpens = 0;
    var dismisses = 0;
    PermissionsFocus? focus;

    await tester.pumpWidget(
      MaterialApp(
        home: FirstRunSetupChecklist(
          snapshot: const SetupChecklistSnapshot(
            providerStatus: ProviderStatus.notConfigured(),
            permissions: _readyPermissions,
          ),
          onOpenGoogleSetup: () => googleOpens++,
          onOpenPermissions: (value) => focus = value,
          onContinue: () => fail('Required setup must gate Continue.'),
          onDismiss: () => dismisses++,
        ),
      ),
    );

    final primary = tester.widget<FilledButton>(
      find.byKey(const ValueKey('setup-checklist-primary-action')),
    );
    expect(primary.onPressed, isNull);
    expect(find.text('Finish required setup'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('setup-checklist-google')),
        matching: find.text('Set up'),
      ),
    );
    expect(googleOpens, 1);

    final locationReview = find.descendant(
      of: find.byKey(const ValueKey('setup-checklist-location')),
      matching: find.text('Review'),
    );
    await tester.ensureVisible(locationReview);
    await tester.pumpAndSettle();
    await tester.tap(locationReview);
    expect(focus, PermissionsFocus.location);

    await tester.tap(find.text('Do this later'));
    expect(dismisses, 1);
  });

  testWidgets('required-ready setup can continue without recommendations', (
    tester,
  ) async {
    var continues = 0;
    PermissionsFocus? focus;
    const snapshot = SetupChecklistSnapshot(
      providerStatus: _validProvider,
      permissions: PermissionsSnapshot(
        location: _readyLocation,
        notification: NotificationPermissionState.permanentlyDenied,
        battery: BatteryOptimizationState.enabled,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: FirstRunSetupChecklist(
          snapshot: snapshot,
          onOpenGoogleSetup: () {},
          onOpenPermissions: (value) => focus = value,
          onContinue: () => continues++,
          onDismiss: () {},
        ),
      ),
    );

    expect(find.text('Continue for now'), findsOneWidget);
    expect(find.text('Do this later'), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('setup-checklist-reliability')),
      180,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('setup-checklist-list')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      find.text('Notifications: Not allowed.\nBattery usage: Optimized.'),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('setup-checklist-reliability')),
        matching: find.text('Improve'),
      ),
    );
    expect(focus, PermissionsFocus.reliability);

    await tester.tap(find.text('Continue for now'));
    expect(continues, 1);
  });

  testWidgets('configured Google failures remain actionable in the checklist', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FirstRunSetupChecklist(
          snapshot: const SetupChecklistSnapshot(
            providerStatus: ProviderStatus(
              configured: true,
              validationState: ProviderValidationState.invalidKey,
            ),
            permissions: _readyPermissions,
          ),
          onOpenGoogleSetup: () {},
          onOpenPermissions: (_) {},
          onContinue: () {},
          onDismiss: () {},
        ),
      ),
    );

    expect(
      find.text('Invalid key. Check the value and try again.'),
      findsOneWidget,
    );
    expect(find.text('Finish required setup'), findsOneWidget);
  });

  testWidgets('first-run checklist fits narrow screens with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    tester.binding.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(
      tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: FirstRunSetupChecklist(
          snapshot: const SetupChecklistSnapshot(
            providerStatus: ProviderStatus.notConfigured(),
            permissions: PermissionsSnapshot(
              location: LocationAccessStatus.unavailable(),
              notification: NotificationPermissionState.unknown,
              battery: BatteryOptimizationState.unknown,
            ),
          ),
          onOpenGoogleSetup: () {},
          onOpenPermissions: (_) {},
          onContinue: () {},
          onDismiss: () {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Finish required setup'), findsOneWidget);
    expect(find.text('Do this later'), findsOneWidget);
  });

  testWidgets('fully ready and manual checklists use their approved labels', (
    tester,
  ) async {
    const snapshot = SetupChecklistSnapshot(
      providerStatus: _validProvider,
      permissions: _readyPermissions,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: FirstRunSetupChecklist(
          snapshot: snapshot,
          onOpenGoogleSetup: () {},
          onOpenPermissions: (_) {},
          onContinue: () {},
          onDismiss: () {},
        ),
      ),
    );
    expect(find.text('Start using Mappy'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: FirstRunSetupChecklist(
          snapshot: snapshot,
          onOpenGoogleSetup: () {},
          onOpenPermissions: (_) {},
          onContinue: () {},
          onDismiss: () {},
          manual: true,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Do this later'), findsNothing);
  });

  testWidgets('Permissions reliability focus scrolls to its first issue', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const permissions = PermissionsSnapshot(
      location: _readyLocation,
      notification: NotificationPermissionState.denied,
      battery: BatteryOptimizationState.disabled,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PermissionsScreen(
          initialSnapshot: permissions,
          focus: PermissionsFocus.reliability,
          onRefresh: () async => permissions,
          onRequestForegroundLocation: () async => _readyLocation,
          onOpenAppLocationSettings: () async => true,
          onOpenLocationServicesSettings: () async => true,
          onRequestNotifications: () async => const BridgeStatus.unavailable(),
          onOpenNotificationSettings: () async => true,
          onRequestBatteryExemption: () async =>
              BatteryOptimizationState.disabled,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Notifications'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Notifications')).dy, lessThan(180));
  });

  testWidgets('Permissions labels background access that does not apply', (
    tester,
  ) async {
    const permissions = PermissionsSnapshot(
      location: LocationAccessStatus(
        servicesEnabled: true,
        foregroundState: ForegroundLocationState.approximate,
        backgroundRequired: false,
        backgroundGranted: true,
      ),
      notification: NotificationPermissionState.notRequired,
      battery: BatteryOptimizationState.disabled,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PermissionsScreen(
          initialSnapshot: permissions,
          focus: PermissionsFocus.location,
          onRefresh: () async => permissions,
          onRequestForegroundLocation: () async => permissions.location,
          onOpenAppLocationSettings: () async => true,
          onOpenLocationServicesSettings: () async => true,
          onRequestNotifications: () async => const BridgeStatus.unavailable(),
          onOpenNotificationSettings: () async => true,
          onRequestBatteryExemption: () async =>
              BatteryOptimizationState.disabled,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Background location'), findsOneWidget);
    expect(find.text('Not required'), findsNWidgets(2));
    expect(find.text('Allow always'), findsNothing);
  });

  testWidgets('Permissions routes permanent location denial to app settings', (
    tester,
  ) async {
    var appSettingsOpens = 0;
    const permissions = PermissionsSnapshot(
      location: LocationAccessStatus(
        servicesEnabled: true,
        foregroundState: ForegroundLocationState.permanentlyDenied,
        backgroundRequired: true,
        backgroundGranted: false,
      ),
      notification: NotificationPermissionState.notRequired,
      battery: BatteryOptimizationState.disabled,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PermissionsScreen(
          initialSnapshot: permissions,
          focus: PermissionsFocus.location,
          onRefresh: () async => permissions,
          onRequestForegroundLocation: () async => permissions.location,
          onOpenAppLocationSettings: () async {
            appSettingsOpens += 1;
            return true;
          },
          onOpenLocationServicesSettings: () async => true,
          onRequestNotifications: () async => const BridgeStatus.unavailable(),
          onOpenNotificationSettings: () async => true,
          onRequestBatteryExemption: () async =>
              BatteryOptimizationState.disabled,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Open settings'));
    await tester.pumpAndSettle();
    expect(appSettingsOpens, 1);
  });

  testWidgets('Permissions reliability focus targets battery when needed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const permissions = PermissionsSnapshot(
      location: _readyLocation,
      notification: NotificationPermissionState.granted,
      battery: BatteryOptimizationState.unknown,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PermissionsScreen(
          initialSnapshot: permissions,
          focus: PermissionsFocus.reliability,
          onRefresh: () async => permissions,
          onRequestForegroundLocation: () async => _readyLocation,
          onOpenAppLocationSettings: () async => true,
          onOpenLocationServicesSettings: () async => true,
          onRequestNotifications: () async => const BridgeStatus.unavailable(),
          onOpenNotificationSettings: () async => true,
          onRequestBatteryExemption: () async =>
              BatteryOptimizationState.disabled,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Battery usage'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Battery usage')).dy, lessThan(180));
    expect(find.text('Unknown'), findsOneWidget);
  });

  testWidgets('Settings hub exposes the setup checklist first', (tester) async {
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsHubScreen(
            providerStatus: _validProvider,
            setupChecklistSummary: 'Recommendations available',
            setupChecklistNeedsAttention: true,
            permissionsSummary: 'Needs attention',
            watchSummary: 'Ready',
            readinessLoaded: true,
            providerNeedsAttention: false,
            permissionsNeedAttention: true,
            onOpenSetupChecklist: () => opens++,
            onOpenGoogleSetup: () {},
            onOpenPermissions: () {},
            onOpenWatchConnection: () {},
            onOpenNavigationPreferences: () {},
            onOpenAppearancePreferences: () {},
            onOpenWatchMapPreferences: () {},
            onOpenDiagnostics: () {},
            onOpenAbout: () {},
          ),
        ),
      ),
    );

    final checklist = find.byKey(const ValueKey('settings-setup-checklist'));
    final google = find.byKey(const ValueKey('settings-google-maps'));
    expect(checklist, findsOneWidget);
    expect(
      tester.getTopLeft(checklist).dy,
      lessThan(tester.getTopLeft(google).dy),
    );
    await tester.tap(checklist);
    expect(opens, 1);
  });
}
