import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mappy/provider_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const providerChannel = MethodChannel('com.leapwardkoex.mappy/provider');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(providerChannel, null);
  });

  test(
    'native provider calls do not accept Android identity header overrides',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(providerChannel, (call) async {
            calls.add(call);
            return <String, Object?>{
              'ok': true,
              'providerStatus': <String, Object?>{
                'configured': true,
                'validationState': 'valid',
              },
              'routePoints': <Object?>[],
              'steps': <Object?>[],
            };
          });

      await const NativeProviderRepository().computeRoute(
        originLatitude: 37.0,
        originLongitude: -122.0,
        destinationAddress: 'Synthetic destination',
        destinationLatitude: 37.1,
        destinationLongitude: -121.9,
        travelMode: TravelMode.drive,
      );

      final arguments = calls.single.arguments as Map<Object?, Object?>;
      expect(arguments.keys, isNot(contains('X-Android-Package')));
      expect(arguments.keys, isNot(contains('X-Android-Cert')));
      expect(arguments.keys, isNot(contains('packageName')));
      expect(arguments.keys, isNot(contains('certSha1')));
    },
  );
}
