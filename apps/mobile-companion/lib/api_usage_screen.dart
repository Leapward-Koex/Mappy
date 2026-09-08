import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_usage.dart';

class ApiUsageScreen extends StatefulWidget {
  const ApiUsageScreen({required this.controller, super.key});
  final ApiUsageController controller;
  @override
  State<ApiUsageScreen> createState() => _ApiUsageScreenState();
}

class _ApiUsageScreenState extends State<ApiUsageScreen>
    with WidgetsBindingObserver {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(widget.controller.refresh());
    _startRefresh();
  }

  void _startRefresh() {
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(widget.controller.refresh()),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _timer?.cancel();
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.controller.refresh());
      _startRefresh();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _editCap(ApiProductUsage product) async {
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => _FreeCapDialog(product: product),
    );
    if (result != null) {
      await widget.controller.update({'freeCaps': result});
    }
  }

  Future<void> _openSource(String path) async {
    final url = Uri.parse(
      'https://developers.google.com/maps/billing-and-pricing/$path',
    );
    try {
      if (await launchUrl(url, mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      /* Show a recoverable message below. */
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the Google documentation. Try again.'),
        ),
      );
    }
  }

  String _date(DateTime date) =>
      MaterialLocalizations.of(context).formatMediumDate(date);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('API usage'),
      actions: [
        IconButton(
          tooltip: 'Refresh usage',
          onPressed: widget.controller.refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final state = controller.state;
        if (state == null && controller.error == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (controller.error != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    controller.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            if (state != null) ...[
              SwitchListTile(
                key: const ValueKey('api-usage-enabled'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Enable Google Maps API requests'),
                subtitle: Text(
                  state.settings.apiEnabled
                      ? 'Applies to phone, watch, setup checks, and map previews.'
                      : 'Google Maps API requests are disabled. New map, search, and route requests will not run.',
                ),
                value: state.settings.apiEnabled,
                onChanged: controller.saving
                    ? null
                    : (value) => controller.update({'apiEnabled': value}),
              ),
              const SizedBox(height: 12),
              const Text('When a product reaches its allowance'),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                key: const ValueKey('api-usage-mode'),
                segments: const [
                  ButtonSegment(
                    value: 'warn',
                    label: Text('Warn'),
                    icon: Icon(Icons.warning_amber),
                  ),
                  ButtonSegment(
                    value: 'block',
                    label: Text('Block'),
                    icon: Icon(Icons.block),
                  ),
                ],
                selected: {state.settings.mode},
                onSelectionChanged: controller.saving
                    ? null
                    : (selection) =>
                          controller.update({'mode': selection.single}),
              ),
              const SizedBox(height: 8),
              Text(
                state.settings.mode == 'warn'
                    ? 'Warns at 80% and 100%. Requests continue beyond the allowance and may incur charges.'
                    : 'Warns at 80% and 100%. Blocks new requests for each product once its allowance is reached.',
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<int>(
                key: ValueKey(
                  'api-usage-rollover-${state.settings.rolloverDay}',
                ),
                decoration: const InputDecoration(
                  labelText: 'Monthly billing day',
                  border: OutlineInputBorder(),
                ),
                initialValue: state.settings.rolloverDay,
                items: [
                  for (var day = 1; day <= 31; day++)
                    DropdownMenuItem(value: day, child: Text('Day $day')),
                ],
                onChanged: controller.saving
                    ? null
                    : (day) {
                        if (day != null) {
                          controller.update({'rolloverDay': day});
                        }
                      },
              ),
              const SizedBox(height: 8),
              Text(
                'Current period: ${_date(state.periodStart)} – ${_date(state.nextRollover)}. '
                'Resets at local midnight; shorter months use their final day. Changing the day keeps current usage and never brings the next reset forward.',
              ),
              const SizedBox(height: 20),
              for (final product in state.products)
                Card(
                  key: ValueKey('api-product-${product.product.name}'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                product.label,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Edit ${product.label} free allowance',
                              onPressed: controller.saving
                                  ? null
                                  : () => _editCap(product),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                          ],
                        ),
                        Text(product.usageLabel),
                        if (product.freeCap != null) ...[
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: product.fraction!.clamp(0, 1),
                            color: product.warningLevel == 2
                                ? Theme.of(context).colorScheme.error
                                : product.warningLevel == 1
                                ? Colors.orange.shade800
                                : null,
                            semanticsLabel:
                                '${product.label} estimated usage: ${product.usageLabel}, ${product.percentLabel}',
                          ),
                          const SizedBox(height: 6),
                          Text(product.percentLabel),
                          if (product.used > product.freeCap!)
                            Text(
                              '${product.used - product.freeCap!} ${product.unit} over the allowance',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          if (product.warningLevel > 0)
                            Text(
                              product.warningLevel == 1
                                  ? 'Approaching the estimated free allowance.'
                                  : state.settings.mode == 'block'
                                  ? 'Allowance reached · New requests blocked.'
                                  : 'Allowance reached · Warn mode allows further requests.',
                            ),
                        ],
                        const SizedBox(height: 6),
                        Text('Rollover: ${_date(state.nextRollover)}'),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Card(
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Estimated usage only',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'This is an in-app estimate, not Google billing data. It counts only requests made by Mappy; calls made elsewhere, Google’s billing calculations, and pricing/free-usage changes may differ. Your custom rollover period may also differ from Google’s billing period.',
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'The estimates may not be perfectly accurate or match current Google Maps API free usage limits. Google’s standard free caps reset on the first day of each month at midnight Pacific US time.',
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Tracking starts when this feature is installed; earlier usage is unknown. Clearing app data removes the estimates. Failed requests and every autocomplete request are counted conservatively; session discounts are not deducted.',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Global pricing defaults reviewed ${state.reviewedOn}. Edit allowances to match your account.',
                      ),
                      Wrap(
                        children: [
                          TextButton(
                            onPressed: () => _openSource('pricing'),
                            child: const Text('Google pricing'),
                          ),
                          TextButton(
                            onPressed: () => _openSource('pay-as-you-go'),
                            child: const Text('Google billing guide'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        );
      },
    ),
  );
}

class _FreeCapDialog extends StatefulWidget {
  const _FreeCapDialog({required this.product});
  final ApiProductUsage product;
  @override
  State<_FreeCapDialog> createState() => _FreeCapDialogState();
}

class _FreeCapDialogState extends State<_FreeCapDialog> {
  final _form = GlobalKey<FormState>();
  late final _text = TextEditingController(
    text: widget.product.freeCap?.toString() ?? '',
  );
  late bool _unlimited = widget.product.freeCap == null;
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.product.label} allowance'),
    content: SingleChildScrollView(
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Unlimited allowance'),
              value: _unlimited,
              onChanged: (value) => setState(() => _unlimited = value),
            ),
            TextFormField(
              key: const ValueKey('api-free-cap-input'),
              controller: _text,
              enabled: !_unlimited,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Free allowance per period',
                helperText: '0 blocks all new requests in Block mode.',
              ),
              validator: (value) {
                if (_unlimited) return null;
                final number = int.tryParse(value?.trim() ?? '');
                return number == null || number < 0 || number > 1000000000
                    ? 'Enter a whole number from 0 to 1000000000.'
                    : null;
              },
            ),
            TextButton(
              onPressed: () => setState(() {
                _unlimited = widget.product.defaultCap == null;
                _text.text = widget.product.defaultCap?.toString() ?? '';
              }),
              child: const Text('Use documented default'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(context, <String, Object?>{
              widget.product.product.name: _unlimited
                  ? null
                  : int.parse(_text.text.trim()),
            });
          }
        },
        child: const Text('Save'),
      ),
    ],
  );
}
