import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum ApiProduct {
  mapTiles2d,
  geocoding,
  autocomplete,
  placeDetailsPro,
  computeRoutesEssentials,
}

class ApiUsageSettings {
  const ApiUsageSettings({
    required this.apiEnabled,
    required this.mode,
    required this.rolloverDay,
    required this.freeCaps,
  });

  final bool apiEnabled;
  final String mode;
  final int rolloverDay;
  final Map<ApiProduct, int?> freeCaps;
}

class ApiProductUsage {
  const ApiProductUsage({
    required this.product,
    required this.label,
    required this.unit,
    required this.used,
    required this.freeCap,
    required this.defaultCap,
  });

  final ApiProduct product;
  final String label;
  final String unit;
  final int used;
  final int? freeCap;
  final int? defaultCap;
  double? get fraction => freeCap == null
      ? null
      : freeCap == 0
      ? (used == 0 ? 0 : 1)
      : used / freeCap!;
  int get warningLevel => freeCap == null
      ? 0
      : used >= freeCap!
      ? 2
      : fraction! >= .8
      ? 1
      : 0;
  String get usageLabel => freeCap == null
      ? '$used $unit · Unlimited allowance'
      : '$used / $freeCap $unit';
  String get percentLabel => freeCap == 0
      ? 'No free allowance'
      : '${(fraction! * 100).toStringAsFixed(0)}% used';
}

class ApiUsageState {
  const ApiUsageState({
    required this.settings,
    required this.products,
    required this.periodStart,
    required this.nextRollover,
    required this.reviewedOn,
  });

  final ApiUsageSettings settings;
  final List<ApiProductUsage> products;
  final DateTime periodStart;
  final DateTime nextRollover;
  final String reviewedOn;

  factory ApiUsageState.fromChannel(Object? value) {
    final data = value as Map;
    final rows = (data['products'] as List).cast<Map>();
    final products = [
      for (final product in ApiProduct.values)
        (() {
          final row = rows.singleWhere((r) => r['id'] == product.name);
          return ApiProductUsage(
            product: product,
            label: row['label'] as String,
            unit: row['unit'] as String,
            used: (row['used'] as num).toInt(),
            freeCap: (row['freeCap'] as num?)?.toInt(),
            defaultCap: (row['defaultCap'] as num?)?.toInt(),
          );
        })(),
    ];
    return ApiUsageState(
      settings: ApiUsageSettings(
        apiEnabled: data['apiEnabled'] as bool,
        mode: data['mode'] as String,
        rolloverDay: (data['rolloverDay'] as num).toInt(),
        freeCaps: {for (final row in products) row.product: row.freeCap},
      ),
      products: products,
      periodStart: DateTime.fromMillisecondsSinceEpoch(
        (data['periodStart'] as num).toInt(),
      ),
      nextRollover: DateTime.fromMillisecondsSinceEpoch(
        (data['nextRollover'] as num).toInt(),
      ),
      reviewedOn: data['reviewedOn'] as String,
    );
  }
}

abstract interface class ApiUsageRepository {
  Future<ApiUsageState> getUsage();
  Future<ApiUsageState> updateSettings(Map<String, Object?> changes);
}

class NativeApiUsageRepository implements ApiUsageRepository {
  const NativeApiUsageRepository();
  static const _channel = MethodChannel('com.leapwardkoex.mappy/provider');
  Future<ApiUsageState> _call(
    String method, [
    Map<String, Object?>? arguments,
  ]) async => ApiUsageState.fromChannel(
    await _channel.invokeMethod<Object?>(method, arguments),
  );
  @override
  Future<ApiUsageState> getUsage() => _call('getApiUsage');
  @override
  Future<ApiUsageState> updateSettings(Map<String, Object?> changes) =>
      _call('setApiUsageSettings', changes);
}

class ApiUsageController extends ChangeNotifier {
  ApiUsageController(this.repository);
  final ApiUsageRepository repository;
  ApiUsageState? state;
  String? error;
  bool saving = false;
  bool _disposed = false;
  int _revision = 0;
  Future<void>? _refreshing;
  Timer? _rolloverTimer;

  void _accept(ApiUsageState next) {
    state = next;
    error = null;
    _rolloverTimer?.cancel();
    final delay = next.nextRollover.difference(DateTime.now());
    if (delay > Duration.zero) {
      _rolloverTimer = Timer(
        delay + const Duration(seconds: 1),
        () => unawaited(refresh()),
      );
    }
  }

  bool get apiEnabled => state?.settings.apiEnabled == true && error == null;

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  Future<void> _refresh() async {
    final revision = _revision;
    try {
      final next = await repository.getUsage();
      if (_disposed || revision != _revision) return;
      _accept(next);
    } catch (failure) {
      if (_disposed || revision != _revision) return;
      error = _message(failure);
    }
    if (!_disposed) notifyListeners();
  }

  Future<bool> update(Map<String, Object?> changes) async {
    if (saving) return false;
    saving = true;
    _revision++;
    notifyListeners();
    try {
      final next = await repository.updateSettings(changes);
      if (_disposed) return false;
      _accept(next);
      return true;
    } catch (failure) {
      if (!_disposed) error = _message(failure);
      return false;
    } finally {
      saving = false;
      if (!_disposed) notifyListeners();
    }
  }

  static String _message(Object failure) => failure is PlatformException
      ? failure.message ?? 'API usage is unavailable.'
      : 'API usage is unavailable. Google Maps requests cannot be enabled here until it is available.';

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _rolloverTimer?.cancel();
    super.dispose();
  }
}

class ApiUsageScope extends InheritedWidget {
  const ApiUsageScope({
    required this.controller,
    required super.child,
    super.key,
  });
  final ApiUsageController controller;
  static ApiUsageController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ApiUsageScope>()?.controller;
  @override
  bool updateShouldNotify(ApiUsageScope oldWidget) =>
      controller != oldWidget.controller;
}

/// The developer-managed preview follows the master switch without consuming user usage.
class ApiUsageMapGate extends StatelessWidget {
  const ApiUsageMapGate({
    required this.controller,
    required this.map,
    required this.fallback,
    super.key,
  });
  final ApiUsageController controller;
  final Widget map;
  final Widget fallback;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => controller.apiEnabled
        ? map
        : Stack(
            fit: StackFit.expand,
            children: [
              fallback,
              const Positioned(
                left: 8,
                right: 8,
                bottom: 58,
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: Text(
                      'Google Maps preview paused · See Settings > API usage',
                    ),
                  ),
                ),
              ),
            ],
          ),
  );
}

class ApiUsageNotice extends StatelessWidget {
  const ApiUsageNotice({
    required this.controller,
    required this.onOpen,
    super.key,
  });
  final ApiUsageController controller;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final state = controller.state;
      if (state == null) return const SizedBox.shrink();
      final warnings = state.products
          .where((product) => product.warningLevel > 0)
          .toList();
      final message = !state.settings.apiEnabled
          ? 'Google Maps API requests are disabled.'
          : warnings.isNotEmpty
          ? '${warnings.first.label}: ${warnings.first.percentLabel}. '
                '${state.settings.mode == 'warn' ? 'Warn mode allows further requests.' : 'Requests stop at the allowance.'}'
          : null;
      if (message == null) return const SizedBox.shrink();
      return Material(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.data_usage),
          title: Text(message),
          trailing: TextButton(
            onPressed: onOpen,
            child: const Text('API usage'),
          ),
        ),
      );
    },
  );
}
