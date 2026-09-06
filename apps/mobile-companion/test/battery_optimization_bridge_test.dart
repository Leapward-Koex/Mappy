import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mappy/battery_optimization_bridge.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter.baseflow.com/permissions/methods');
  const repository = NativeBatteryOptimizationRepository();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final permission = Permission.ignoreBatteryOptimizations.value;

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('reads the actual exemption again when settings change', () async {
    var status = PermissionStatus.denied;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'checkPermissionStatus');
      expect(call.arguments, permission);
      return status.index;
    });

    expect(
      await repository.getBatteryOptimizationState(),
      BatteryOptimizationState.enabled,
    );
    status = PermissionStatus.granted;
    expect(
      await repository.getBatteryOptimizationState(),
      BatteryOptimizationState.disabled,
    );
    status = PermissionStatus.denied;
    expect(
      await repository.getBatteryOptimizationState(),
      BatteryOptimizationState.enabled,
    );
  });

  for (final granted in [false, true]) {
    test('waits for the system decision (granted: $granted)', () async {
      final response = Completer<Map<int, int>>();
      final invoked = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) {
        expect(call.method, 'requestPermissions');
        expect(call.arguments, [permission]);
        invoked.complete();
        return response.future;
      });

      var completed = false;
      final pending = repository.requestDisableBatteryOptimization().then((
        state,
      ) {
        completed = true;
        return state;
      });
      await invoked.future;
      expect(completed, isFalse);
      response.complete({
        permission:
            (granted ? PermissionStatus.granted : PermissionStatus.denied)
                .index,
      });
      expect(
        await pending,
        granted
            ? BatteryOptimizationState.disabled
            : BatteryOptimizationState.enabled,
      );
    });
  }

  test(
    'plugin failures never report battery optimization as disabled',
    () async {
      for (final error in [
        MissingPluginException(),
        PlatformException(code: 'unavailable'),
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async => throw error);
        expect(
          await repository.getBatteryOptimizationState(),
          BatteryOptimizationState.unavailable,
        );
        expect(
          await repository.requestDisableBatteryOptimization(),
          BatteryOptimizationState.unavailable,
        );
        expect(await repository.openBatterySettings(), isFalse);
      }
    },
  );

  test('unsupported platforms do not call the Android battery API', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      fail('Android battery API called on an unsupported platform');
    });
    for (final platform in TargetPlatform.values.where(
      (value) => value != TargetPlatform.android,
    )) {
      debugDefaultTargetPlatformOverride = platform;
      expect(
        await repository.getBatteryOptimizationState(),
        BatteryOptimizationState.unavailable,
      );
      expect(
        await repository.requestDisableBatteryOptimization(),
        BatteryOptimizationState.unavailable,
      );
      expect(await repository.openBatterySettings(), isFalse);
    }
  });

  test(
    'opens app settings without treating it as an exemption grant',
    () async {
      var opened = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'openAppSettings') return opened;
        expect(call.method, 'checkPermissionStatus');
        return PermissionStatus.denied.index;
      });
      expect(await repository.openBatterySettings(), isFalse);
      opened = true;
      expect(await repository.openBatterySettings(), isTrue);
      expect(
        await repository.getBatteryOptimizationState(),
        BatteryOptimizationState.enabled,
      );
    },
  );
}
