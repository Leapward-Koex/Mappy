import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mappy/api_usage.dart';
import 'package:mappy/api_usage_screen.dart';

Map<String, Object?> usageFixture() => {
  'apiEnabled': true,
  'mode': 'block',
  'rolloverDay': 1,
  'periodStart': DateTime(2100, 9, 1).millisecondsSinceEpoch,
  'nextRollover': DateTime(2100, 10, 1).millisecondsSinceEpoch,
  'reviewedOn': '2026-09-08',
  'products': [
    for (final product in ApiProduct.values)
      <String, Object?>{
        'id': product.name,
        'label': switch (product) {
          ApiProduct.mapTiles2d => '2D Map Tiles',
          ApiProduct.geocoding => 'Geocoding',
          ApiProduct.autocomplete => 'Places Autocomplete Requests',
          ApiProduct.placeDetailsPro => 'Place Details Pro',
          ApiProduct.computeRoutesEssentials => 'Compute Routes Essentials',
        },
        'unit': 'requests',
        'used': 0,
        'freeCap': 10,
        'defaultCap': 10,
      },
  ],
};

class FakeUsageRepository implements ApiUsageRepository {
  final data = usageFixture();
  final updates = <Map<String, Object?>>[];
  Object? loadError;
  Map<String, Object?> row(ApiProduct product) =>
      (data['products'] as List<Map<String, Object?>>).singleWhere(
        (r) => r['id'] == product.name,
      );

  @override
  Future<ApiUsageState> getUsage() async {
    if (loadError != null) throw loadError!;
    return ApiUsageState.fromChannel(data);
  }

  @override
  Future<ApiUsageState> updateSettings(Map<String, Object?> changes) async {
    updates.add(changes);
    for (final entry in changes.entries) {
      if (entry.key == 'freeCaps') {
        for (final cap in (entry.value as Map<String, Object?>).entries) {
          row(ApiProduct.values.byName(cap.key))['freeCap'] = cap.value;
        }
      } else {
        data[entry.key] = entry.value;
      }
    }
    return getUsage();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('API usage fits a narrow screen with large text', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    final repository = FakeUsageRepository();
    repository.row(ApiProduct.mapTiles2d)['used'] = 12;
    final controller = ApiUsageController(repository);
    final capture = GlobalKey();
    try {
      if (const bool.fromEnvironment('MAPPY_CAPTURE_API_USAGE')) {
        await tester.runAsync(() async {
          final artifacts = File(
            Platform.resolvedExecutable,
          ).parent.parent.parent;
          for (final font in {
            'Roboto': 'roboto-regular.ttf',
            'MaterialIcons': 'materialicons-regular.otf',
          }.entries) {
            final bytes = await File(
              '${artifacts.path}/material_fonts/${font.value}',
            ).readAsBytes();
            await (FontLoader(
              font.key,
            )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
          }
        });
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            fontFamily: 'Roboto',
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF1D706D),
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: RepaintBoundary(
            key: capture,
            child: ApiUsageScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('api-product-mapTiles2d')),
        250,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('MAPPY_CAPTURE_API_USAGE')) {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          final folder = Directory('build/api-usage-qa');
          await folder.create(recursive: true);
          await File(
            '${folder.path}/usage-narrow.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
      await tester.tap(find.byTooltip('Edit 2D Map Tiles free allowance'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  test(
    'bridge exposes only user products and sends requested settings',
    () async {
      const channel = MethodChannel('com.leapwardkoex.mappy/provider');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return usageFixture();
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      const repository = NativeApiUsageRepository();
      final state = await repository.getUsage();
      expect(state.products.length, ApiProduct.values.length);
      expect(state.products.length, 5);
      expect(
        state.products.map((row) => row.label),
        isNot(contains('Maps SDK')),
      );
      await repository.updateSettings({'mode': 'warn'});
      expect(calls.map((call) => call.method), [
        'getApiUsage',
        'setApiUsageSettings',
      ]);
      expect(calls[1].arguments, {'mode': 'warn'});
    },
  );

  testWidgets('settings persist master switch, mode and billing day', (
    tester,
  ) async {
    final repository = FakeUsageRepository();
    final controller = ApiUsageController(repository);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ApiUsageScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('api-usage-enabled')));
    await tester.pumpAndSettle();
    expect(repository.data['apiEnabled'], false);
    expect(
      find.textContaining('Google Maps API requests are disabled.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Warn'));
    await tester.pumpAndSettle();
    expect(repository.data['mode'], 'warn');
    await tester.tap(find.byKey(const ValueKey('api-usage-rollover-1')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Day 12'),
      150,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Day 12').last);
    await tester.pumpAndSettle();
    expect(repository.data['rolloverDay'], 12);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'cap editor rejects invalid values and saves finite or unlimited allowances',
    (tester) async {
      final repository = FakeUsageRepository();
      final controller = ApiUsageController(repository);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: ApiUsageScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      final edit = find.byTooltip('Edit 2D Map Tiles free allowance');
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('api-free-cap-input'));
      for (final invalid in ['-1', '1.5', '1000000001', '']) {
        await tester.enterText(input, invalid);
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(
          find.text('Enter a whole number from 0 to 1000000000.'),
          findsOneWidget,
        );
        expect(repository.updates, isEmpty);
      }
      await tester.enterText(input, '0');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repository.row(ApiProduct.mapTiles2d)['freeCap'], 0);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unlimited allowance'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repository.row(ApiProduct.mapTiles2d)['freeCap'], isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'bars expose overflow semantics and unlimited products have no finite bar',
    (tester) async {
      final repository = FakeUsageRepository();
      repository.row(ApiProduct.mapTiles2d)['used'] = 12;
      repository.row(ApiProduct.geocoding)['freeCap'] = null;
      repository.data['mode'] = 'warn';
      final controller = ApiUsageController(repository);
      addTearDown(controller.dispose);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(home: ApiUsageScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('api-product-mapTiles2d')),
      );
      expect(find.text('120% used'), findsOneWidget);
      expect(find.text('2 requests over the allowance'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator).first,
      );
      expect(bar.value, 1);
      expect(bar.semanticsLabel, contains('120% used'));
      final unlimited = find.byKey(const ValueKey('api-product-geocoding'));
      await tester.scrollUntilVisible(unlimited, 350);
      expect(
        find.descendant(
          of: unlimited,
          matching: find.byType(LinearProgressIndicator),
        ),
        findsNothing,
      );
      expect(find.text('0 requests · Unlimited allowance'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Estimated usage only'), 350);
      expect(
        find.textContaining('may not be perfectly accurate'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
      controller.dispose();
    },
  );

  testWidgets('preview follows master switch without consuming user usage', (
    tester,
  ) async {
    final repository = FakeUsageRepository();
    final controller = ApiUsageController(repository);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: ApiUsageMapGate(
            controller: controller,
            map: const Text('SDK mounted'),
            fallback: const Text('Local preview'),
          ),
        ),
      );
      expect(find.text('SDK mounted'), findsNothing);
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(find.text('SDK mounted'), findsOneWidget);
      await controller.update({'apiEnabled': false});
      await tester.pumpAndSettle();
      expect(find.text('SDK mounted'), findsNothing);
      await controller.update({'apiEnabled': true});
      await tester.pumpAndSettle();
      expect(find.text('SDK mounted'), findsOneWidget);
      expect(controller.state!.products.every((row) => row.used == 0), isTrue);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
  });

  testWidgets('user product caps do not limit the developer-managed preview', (
    tester,
  ) async {
    final repository = FakeUsageRepository();
    for (final product in ApiProduct.values) {
      repository.row(product)['freeCap'] = 0;
    }
    final controller = ApiUsageController(repository);
    try {
      await controller.refresh();
      await tester.pumpWidget(
        MaterialApp(
          home: ApiUsageMapGate(
            controller: controller,
            map: const Text('SDK mounted'),
            fallback: const Text('Local preview'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('SDK mounted'), findsOneWidget);
      expect(controller.state!.products.every((row) => row.used == 0), isTrue);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
  });

  testWidgets('failed usage loads are visible and never enable the preview', (
    tester,
  ) async {
    final repository = FakeUsageRepository()
      ..loadError = PlatformException(
        code: 'api_usage_unavailable',
        message: 'API usage could not be read.',
      );
    final controller = ApiUsageController(repository);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ApiUsageScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('API usage could not be read.'), findsOneWidget);
    expect(controller.apiEnabled, false);
    expect(find.byKey(const ValueKey('api-usage-enabled')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
