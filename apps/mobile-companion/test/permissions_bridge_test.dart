import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mappy/bridge_channel.dart';
import 'package:mappy/location_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const locationChannel = MethodChannel('com.leapwardkoex.mappy/location');
  const bridgeChannel = MethodChannel('app.mappy.bridge/methods');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(locationChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(bridgeChannel, null);
  });

  test('native location repository parses the non-lossy status', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(locationChannel, (call) async {
          calls.add(call.method);
          return {
            'servicesEnabled': false,
            'foregroundState': 'precise',
            'backgroundRequired': true,
            'backgroundGranted': false,
          };
        });

    const repository = NativeLocationRepository();
    final readStatus = await repository.getLocationAccessStatus();
    final requestedStatus = await repository
        .requestForegroundLocationPermission();

    expect(calls, [
      'getLocationAccessStatus',
      'requestForegroundLocationPermission',
    ]);
    expect(readStatus.servicesEnabled, isFalse);
    expect(readStatus.foregroundState, ForegroundLocationState.precise);
    expect(readStatus.backgroundGranted, isFalse);
    expect(requestedStatus.foregroundState, ForegroundLocationState.precise);
  });

  test(
    'native location repository exposes separate settings actions',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(locationChannel, (call) async {
            calls.add(call.method);
            return true;
          });

      const repository = NativeLocationRepository();
      expect(await repository.openLocationServicesSettings(), isTrue);
      expect(await repository.openAppLocationSettings(), isTrue);
      expect(calls, [
        'openLocationServicesSettings',
        'openAppLocationSettings',
      ]);
    },
  );

  test('native bridge exposes notification settings recovery', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(bridgeChannel, (call) async {
          calls.add(call.method);
          return true;
        });

    const repository = NativeBridgeRepository();
    expect(await repository.openNotificationSettings(), isTrue);
    expect(calls, ['openNotificationSettings']);
  });
}
