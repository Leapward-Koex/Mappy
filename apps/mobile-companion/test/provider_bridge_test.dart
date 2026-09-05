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

  test('watch tile method carries codec geometry and native metrics', () async {
    final payload = Uint8List.fromList([0xf1, 0xe1]);
    MethodCall? request;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(providerChannel, (call) async {
          request = call;
          return {
            'ok': true,
            'providerStatus': {'configured': true, 'validationState': 'valid'},
            'world_x': 123,
            'world_y': 456,
            'tile_zoom': 16,
            'width': 72,
            'height': 84,
            'compression_format': 4,
            'total_bytes': payload.length,
            'chunk_data': payload,
            'preparation_metrics': {
              'encoding_ms': 0.5,
              'encoded_cache_hit': true,
            },
          };
        });
    final result = await const NativeProviderRepository().getWatchTile(
      worldX: 123,
      worldY: 456,
      zoom: 16,
    );
    expect(request!.method, 'getWatchTile');
    expect(request!.arguments, {'worldX': 123, 'worldY': 456, 'zoom': 16});
    expect(result.ok, isTrue);
    expect(result.width, 72);
    expect(result.height, 84);
    expect(result.compressionFormat, 4);
    expect(result.chunkData, payload);
    expect(result.totalBytes, payload.length);
    expect(result.preparationMetrics, {
      'encoding_ms': 0.5,
      'encoded_cache_hit': true,
    });
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
