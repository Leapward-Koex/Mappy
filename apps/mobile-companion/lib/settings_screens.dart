import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'battery_optimization_bridge.dart';
import 'bridge_channel.dart';
import 'location_bridge.dart';
import 'provider_bridge.dart';
import 'watch_phone_worker.dart';
import 'watch_protocol.dart';

const googleCloudConsoleUri = 'https://console.cloud.google.com/';
const googleMapsRequiredApisLabel =
    'Map Tiles API, Places API (New), Geocoding API, and Routes API';

final _googleApiKeyPattern = RegExp(r'^AIza[0-9A-Za-z_-]{16,}$');

String? googleApiKeyValidationError(String input) {
  final value = input.trim();
  if (value.isEmpty) {
    return 'Enter a Google API key before validating.';
  }
  if (!_googleApiKeyPattern.hasMatch(value)) {
    return 'Enter a valid Google API key starting with AIza, without spaces or surrounding text.';
  }
  return null;
}

bool _providerReady(ProviderStatus status) =>
    status.configured &&
    status.validationState == ProviderValidationState.valid;

String _providerFixMessage(ProviderStatus status) {
  switch (status.validationState) {
    case ProviderValidationState.valid:
      return 'Provider setup is ready.';
    case ProviderValidationState.notConfigured:
      return 'Add a Google API key in Setup before navigation can use Google services.';
    case ProviderValidationState.notValidated:
    case ProviderValidationState.validating:
      return 'Validate the Google API key in Setup before starting navigation.';
    case ProviderValidationState.invalidKey:
      return 'Check that the value is a Google API key starting with AIza, not a URL, bearer token, or configuration document.';
    case ProviderValidationState.apiDisabled:
      return 'Enable Map Tiles, Places, Geocoding, and Routes APIs for this key in Google Cloud.';
    case ProviderValidationState.quotaOrBillingIssue:
      return 'Check Google Cloud billing, quota, and project limits for this key.';
    case ProviderValidationState.providerPermissionDenied:
      return 'Check the Android package and signing SHA-1 restrictions shown in Setup.';
    case ProviderValidationState.networkUnavailable:
      return 'Check the phone network connection, then validate the provider again.';
    case ProviderValidationState.unsupportedRestrictedKeyBehavior:
      return 'Restricted-key validation did not behave predictably. Keep Android restrictions enabled and fix the package/SHA-1 setup before release.';
    case ProviderValidationState.unknown:
      return status.validationDetail ??
          'Provider setup failed. Validate the key again from Setup.';
  }
}

class GoogleMapsSetupScreen extends StatefulWidget {
  const GoogleMapsSetupScreen({
    required this.initialStatus,
    required this.onStoreApiKey,
    required this.onValidateProviderSetup,
    required this.onRemoveKey,
    super.key,
  });

  final ProviderStatus initialStatus;
  final Future<ProviderStatus> Function(String apiKey) onStoreApiKey;
  final Future<ProviderStatus> Function() onValidateProviderSetup;
  final Future<ProviderStatus> Function() onRemoveKey;

  @override
  State<GoogleMapsSetupScreen> createState() => _GoogleMapsSetupScreenState();
}

class _GoogleMapsSetupScreenState extends State<GoogleMapsSetupScreen> {
  final TextEditingController _controller = TextEditingController();
  late ProviderStatus _status;
  bool _busy = false;
  bool _controllerDisposed = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _status = widget.initialStatus;
  }

  @override
  void dispose() {
    _controller.clear();
    _controllerDisposed = true;
    _controller.dispose();
    super.dispose();
  }

  void _clearController() {
    if (!_controllerDisposed) _controller.clear();
  }

  Future<ProviderStatus> _storeEnteredApiKey() async {
    try {
      return await widget.onStoreApiKey(_controller.text.trim());
    } finally {
      // The native call has finished, so the plaintext is no longer needed.
      _clearController();
    }
  }

  Future<void> _saveAndValidate() async {
    final error = googleApiKeyValidationError(_controller.text);
    if (error != null) {
      _clearController();
      setState(() => _message = error);
      return;
    }
    final validateProviderSetup = widget.onValidateProviderSetup;
    setState(() {
      _busy = true;
      _message = null;
    });

    late final ProviderStatus storedStatus;
    try {
      storedStatus = await _storeEnteredApiKey();
    } catch (_) {
      _clearController();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = 'Could not save the API key securely. Try again.';
      });
      return;
    }

    if (mounted) setState(() => _status = storedStatus);

    late final ProviderStatus status;
    try {
      status = await validateProviderSetup();
    } catch (_) {
      _clearController();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message =
            'The API key was saved securely, but validation could not be completed. Try again.';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _status = status;
      _busy = false;
      _message = status.usageBlocked
          ? status.validationDetail
          : _providerReady(status)
          ? 'Google services are ready.'
          : _providerFixMessage(status);
    });
  }

  Future<void> _retry() async {
    // A replacement key may have been typed before Retry was pressed. It is
    // not part of this request and must not remain in memory during validation.
    _clearController();
    setState(() {
      _busy = true;
      _message = null;
    });
    late final ProviderStatus status;
    try {
      status = await widget.onValidateProviderSetup();
    } catch (_) {
      _clearController();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = 'Provider validation could not be completed. Try again.';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _status = status;
      _busy = false;
      _message = status.usageBlocked
          ? status.validationDetail
          : _providerReady(status)
          ? 'Google services are ready.'
          : _providerFixMessage(status);
    });
  }

  Future<void> _removeKey() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove API key?'),
        content: const Text(
          'Navigation and place search will be unavailable until another key is validated.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove key'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _clearController();
    setState(() => _busy = true);
    final status = await widget.onRemoveKey();
    if (!mounted) return;
    setState(() {
      _status = status;
      _busy = false;
      _message = 'API key removed.';
    });
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label copied.')));
  }

  Future<void> _openGoogleCloudConsole() async {
    try {
      final opened = await launchUrl(
        Uri.parse(googleCloudConsoleUri),
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted) {
        setState(() {
          _message =
              'Could not open Google Cloud. Visit console.cloud.google.com in a browser.';
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _message =
            'Could not open Google Cloud. Visit console.cloud.google.com in a browser.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _providerReady(_status);
    final packageName = _status.packageName ?? 'com.leapwardkoex.mappy';
    final sha = _status.certSha1;
    const requiredApis = googleMapsRequiredApisLabel;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Google Maps setup'),
        actions: [
          if (_status.configured)
            PopupMenuButton<String>(
              tooltip: 'More actions',
              enabled: !_busy,
              onSelected: (value) {
                if (value == 'remove') unawaited(_removeKey());
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'remove', child: Text('Remove key')),
              ],
            ),
        ],
      ),
      body: SingleChildScrollView(
        key: const ValueKey('google-maps-setup-list'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ReadinessBanner(
              ready: ready,
              icon: ready ? Icons.check_circle_outline : Icons.key_off_outlined,
              title: ready ? 'Google services ready' : 'Setup required',
              detail: ready
                  ? 'Your key is stored securely and validated.'
                  : _providerFixMessage(_status),
            ),
            const SizedBox(height: 20),
            Text(
              'Google Cloud restrictions',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.android),
              title: const Text('Android package'),
              subtitle: Text(packageName),
              trailing: IconButton(
                tooltip: 'Copy package',
                onPressed: () => _copy('Package', packageName),
                icon: const Icon(Icons.copy_outlined),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('Signing SHA-1'),
              subtitle: Text(sha ?? 'Waiting for Android'),
              trailing: IconButton(
                tooltip: 'Copy SHA-1',
                onPressed: sha == null ? null : () => _copy('SHA-1', sha),
                icon: const Icon(Icons.copy_outlined),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.api_outlined),
              title: const Text('Required APIs'),
              subtitle: const Text(requiredApis),
              trailing: IconButton(
                tooltip: 'Copy required APIs',
                onPressed: () => _copy('Required APIs', requiredApis),
                icon: const Icon(Icons.copy_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('google-api-key-input'),
              controller: _controller,
              enabled: !_busy,
              obscureText: true,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              autocorrect: false,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: _status.configured
                    ? 'Replace API key'
                    : 'Google API key',
                helperText: _status.configured
                    ? 'Stored key: ${_status.keyLabel}'
                    : 'The full key is never displayed after saving.',
              ),
              onSubmitted: (_) => _saveAndValidate(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('save-and-validate-key'),
              onPressed: _busy ? null : _saveAndValidate,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.verified_outlined),
              label: Text(_busy ? 'Validating' : 'Save and validate'),
            ),
            if (_status.configured && !ready) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _retry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry validation'),
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(_message!),
            ],
            const SizedBox(height: 24),
            _GoogleApiKeyWalkthrough(
              initiallyExpanded: false,
              packageName: packageName,
              sha1: sha,
              onOpenGoogleCloud: _openGoogleCloudConsole,
            ),
          ],
        ),
      ),
    );
  }
}

class _GoogleApiKeyWalkthrough extends StatelessWidget {
  const _GoogleApiKeyWalkthrough({
    required this.initiallyExpanded,
    required this.packageName,
    required this.sha1,
    required this.onOpenGoogleCloud,
  });

  final bool initiallyExpanded;
  final String packageName;
  final String? sha1;
  final Future<void> Function() onOpenGoogleCloud;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: const ValueKey('google-api-key-guide'),
        initiallyExpanded: initiallyExpanded,
        leading: const Icon(Icons.menu_book_outlined),
        title: const Text('Create a restricted Google API key'),
        subtitle: const Text('Step-by-step Google Cloud setup'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        children: [
          Text(
            'Mappy uses your own Google Maps Platform account. Google requires a billing account for these services; review the current pricing and billing terms in Google Cloud before continuing.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              key: const ValueKey('open-google-cloud-console'),
              onPressed: () => unawaited(onOpenGoogleCloud()),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open Google Cloud Console'),
            ),
          ),
          const SizedBox(height: 16),
          const _GoogleCloudGuideStep(
            number: 1,
            title: 'Sign in',
            detail:
                'Sign in at the Google Cloud Console with the Google account that will own this key.',
          ),
          const _GoogleCloudGuideStep(
            number: 2,
            title: 'Create and select a project',
            detail:
                'Choose Select a project, then New project. On the next screen, name the project, choose Create, wait for creation to finish, and select the new project.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _GoogleCloudGuideScreenshot(
                  asset:
                      'assets/google_cloud_setup/select-project-new-project.png',
                  semanticLabel:
                      'Google Cloud Select a project dialog with New project circled',
                  aspectRatio: 1207 / 829,
                  callouts: [
                    _GoogleCloudScreenshotCallout(
                      center: Offset(.78, .205),
                      size: Size(.16, .065),
                      arrowStart: Offset(.70, .33),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                _GoogleCloudGuideScreenshot(
                  asset: 'assets/google_cloud_setup/create-project.png',
                  semanticLabel:
                      'Google Cloud New Project screen with project name and Create highlighted',
                  aspectRatio: 1207 / 829,
                  callouts: [
                    _GoogleCloudScreenshotCallout(
                      center: Offset(.245, .375),
                      size: Size(.43, .085),
                      arrowStart: Offset(.47, .28),
                    ),
                    _GoogleCloudScreenshotCallout(
                      center: Offset(.062, .57),
                      size: Size(.095, .055),
                      arrowStart: Offset(.17, .64),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const _GoogleCloudGuideStep(
            number: 3,
            title: 'Link billing',
            detail:
                'Open Billing and link a billing account to this project. Google may ask you to verify a payment method before Maps Platform APIs can be used. After activating the full billing account, set a low budget alert so unexpected usage does not become a surprise bill.',
          ),
          const _GoogleCloudGuideStep(
            number: 4,
            title: 'Enable the four APIs',
            detail:
                'Open the navigation menu, choose APIs & Services, then Enabled APIs & services. From Library, search for and enable Map Tiles API, Places API (New), Geocoding API, and Routes API.',
            child: _GoogleCloudGuideScreenshot(
              asset: 'assets/google_cloud_setup/apis-services-enabled-apis.png',
              semanticLabel:
                  'Google Cloud navigation with APIs and Services then Enabled APIs and services highlighted',
              aspectRatio: 1207 / 829,
              callouts: [
                _GoogleCloudScreenshotCallout(
                  center: Offset(.12, .585),
                  size: Size(.21, .055),
                  arrowStart: Offset(.30, .51),
                ),
                _GoogleCloudScreenshotCallout(
                  center: Offset(.32, .596),
                  size: Size(.15, .05),
                  arrowStart: Offset(.46, .66),
                ),
              ],
            ),
          ),
          const _GoogleCloudGuideStep(
            number: 5,
            title: 'Create the key',
            detail:
                'Open APIs & Services > Credentials. Select Create credentials, then API key. Leave service-account authentication off; it is not required for these Maps APIs.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _GoogleCloudGuideScreenshot(
                  asset: 'assets/google_cloud_setup/credentials-navigation.png',
                  semanticLabel:
                      'Google Cloud navigation with APIs and Services then Credentials highlighted',
                  aspectRatio: 1207 / 829,
                  callouts: [
                    _GoogleCloudScreenshotCallout(
                      center: Offset(.12, .585),
                      size: Size(.21, .055),
                      arrowStart: Offset(.30, .51),
                    ),
                    _GoogleCloudScreenshotCallout(
                      center: Offset(.32, .675),
                      size: Size(.15, .05),
                      arrowStart: Offset(.47, .72),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                _GoogleCloudGuideScreenshot(
                  asset: 'assets/google_cloud_setup/create-api-key.png',
                  semanticLabel:
                      'Google Cloud Credentials screen with Create credentials and API key highlighted',
                  aspectRatio: 1207 / 829,
                  callouts: [
                    _GoogleCloudScreenshotCallout(
                      center: Offset(.44, .152),
                      size: Size(.16, .055),
                      arrowStart: Offset(.58, .23),
                    ),
                    _GoogleCloudScreenshotCallout(
                      center: Offset(.40, .202),
                      size: Size(.08, .055),
                      arrowStart: Offset(.49, .29),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _GoogleCloudGuideStep(
            number: 6,
            title: 'Restrict it to this Android app',
            detail:
                'In the key editor, choose Android apps under Application restrictions. Use Add an item, then paste the package name and signing SHA-1 shown above.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Package name: $packageName'),
                Text('Signing SHA-1: ${sha1 ?? 'Waiting for Android'}'),
                const Text('Use the copy buttons above to copy these values.'),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset(
                    'assets/google_cloud_setup/android-app-restriction.png',
                    fit: BoxFit.contain,
                    semanticLabel:
                        'Google Cloud Application restrictions screen with Android apps highlighted',
                  ),
                ),
              ],
            ),
          ),
          _GoogleCloudGuideStep(
            number: 7,
            title: 'Restrict the key to Mappy APIs',
            detail:
                'Under API restrictions, select Restrict key and choose only Map Tiles API, Places API (New), Geocoding API, and Routes API. Then save the key.',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/google_cloud_setup/api-restrictions.png',
                fit: BoxFit.contain,
                semanticLabel:
                    'Google Cloud API restrictions dropdown with four APIs highlighted',
              ),
            ),
          ),
          _GoogleCloudGuideStep(
            number: 8,
            title: 'Copy, save, and validate',
            detail:
                'Copy the new key from Google Cloud, paste it below, and select Save and validate. Never share the full key; regenerate it in Google Cloud if it is exposed.',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/google_cloud_setup/finished-key.png',
                fit: BoxFit.contain,
                semanticLabel:
                    'Google Cloud credentials list showing a completed Mappy API key',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GoogleCloudGuideStep extends StatelessWidget {
  const _GoogleCloudGuideStep({
    required this.number,
    required this.title,
    required this.detail,
    this.child,
  });

  final int number;
  final String title;
  final String detail;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.secondaryContainer,
              shape: BoxShape.circle,
            ),
            child: SizedBox(
              width: 28,
              height: 28,
              child: Center(
                child: Text(
                  '$number',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: colors.onSecondaryContainer,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(detail),
                if (child != null) ...[const SizedBox(height: 8), child!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GoogleCloudGuideScreenshot extends StatelessWidget {
  const _GoogleCloudGuideScreenshot({
    required this.asset,
    required this.semanticLabel,
    required this.aspectRatio,
    required this.callouts,
  });

  final String asset;
  final String semanticLabel;
  final double aspectRatio;
  final List<_GoogleCloudScreenshotCallout> callouts;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: semanticLabel,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(asset, fit: BoxFit.fill, excludeFromSemantics: true),
              IgnorePointer(
                child: CustomPaint(
                  painter: _GoogleCloudScreenshotCalloutPainter(callouts),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoogleCloudScreenshotCallout {
  const _GoogleCloudScreenshotCallout({
    required this.center,
    required this.size,
    required this.arrowStart,
  });

  final Offset center;
  final Size size;
  final Offset arrowStart;
}

class _GoogleCloudScreenshotCalloutPainter extends CustomPainter {
  const _GoogleCloudScreenshotCalloutPainter(this.callouts);

  final List<_GoogleCloudScreenshotCallout> callouts;

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = math.max(3.0, math.min(size.width, size.height) * .009);
    final paint = Paint()
      ..color = const Color(0xFFFFC107)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (final callout in callouts) {
      final center = Offset(
        callout.center.dx * size.width,
        callout.center.dy * size.height,
      );
      final ovalSize = Size(
        callout.size.width * size.width,
        callout.size.height * size.height,
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: center,
          width: ovalSize.width,
          height: ovalSize.height,
        ),
        paint,
      );

      final start = Offset(
        callout.arrowStart.dx * size.width,
        callout.arrowStart.dy * size.height,
      );
      final delta = center - start;
      final distance = delta.distance;
      if (distance == 0) continue;
      final direction = Offset(delta.dx / distance, delta.dy / distance);
      final tip =
          center -
          direction * (math.min(ovalSize.width, ovalSize.height) * .35);
      canvas.drawLine(start, tip, paint);

      final angle = math.atan2(direction.dy, direction.dx);
      final arrowLength = math.max(12.0, strokeWidth * 3.6);
      for (final turn in [-.6, .6]) {
        final wing = Offset(
          tip.dx + math.cos(angle + math.pi + turn) * arrowLength,
          tip.dy + math.sin(angle + math.pi + turn) * arrowLength,
        );
        canvas.drawLine(tip, wing, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_GoogleCloudScreenshotCalloutPainter oldDelegate) =>
      oldDelegate.callouts != callouts;
}

class _ReadinessBanner extends StatelessWidget {
  const _ReadinessBanner({
    required this.ready,
    required this.icon,
    required this.title,
    required this.detail,
  });

  final bool ready;
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = ready
        ? const Color(0xFFE0F1E7)
        : const Color(0xFFFFF0C2);
    final foreground = ready
        ? const Color(0xFF135D36)
        : const Color(0xFF715000);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: foreground),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: foreground,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsHubScreen extends StatelessWidget {
  const SettingsHubScreen({
    required this.providerStatus,
    required this.setupChecklistSummary,
    required this.setupChecklistNeedsAttention,
    required this.permissionsSummary,
    required this.watchSummary,
    required this.readinessLoaded,
    required this.providerNeedsAttention,
    required this.permissionsNeedAttention,
    required this.onOpenSetupChecklist,
    required this.onOpenGoogleSetup,
    required this.onOpenPermissions,
    this.onOpenApiUsage,
    required this.onOpenWatchConnection,
    required this.onOpenNavigationPreferences,
    required this.onOpenAppearancePreferences,
    required this.onOpenWatchMapPreferences,
    required this.onOpenDiagnostics,
    required this.onOpenAbout,
    super.key,
  });

  final ProviderStatus providerStatus;
  final String setupChecklistSummary;
  final bool setupChecklistNeedsAttention;
  final String permissionsSummary;
  final String watchSummary;
  final bool readinessLoaded;
  final bool providerNeedsAttention;
  final bool permissionsNeedAttention;
  final VoidCallback onOpenSetupChecklist;
  final VoidCallback onOpenGoogleSetup;
  final VoidCallback onOpenPermissions;
  final VoidCallback? onOpenApiUsage;
  final VoidCallback onOpenWatchConnection;
  final VoidCallback onOpenNavigationPreferences;
  final VoidCallback onOpenAppearancePreferences;
  final VoidCallback onOpenWatchMapPreferences;
  final VoidCallback onOpenDiagnostics;
  final VoidCallback onOpenAbout;

  @override
  Widget build(BuildContext context) {
    final providerSummary = _providerReady(providerStatus)
        ? 'Ready'
        : providerStatus.configured
        ? providerStatus.providerLabel
        : 'Needs setup';
    return ListView(
      key: const PageStorageKey('settings-list'),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 32),
      children: [
        const _SettingsSectionHeader('Required setup'),
        _SettingsLinkTile(
          key: const ValueKey('settings-setup-checklist'),
          icon: Icons.checklist_outlined,
          title: 'Setup checklist',
          subtitle: setupChecklistSummary,
          showWarning: readinessLoaded && setupChecklistNeedsAttention,
          onTap: onOpenSetupChecklist,
        ),
        _SettingsLinkTile(
          key: const ValueKey('settings-google-maps'),
          icon: Icons.key_outlined,
          title: 'Google Maps setup',
          subtitle: providerSummary,
          showWarning: readinessLoaded && providerNeedsAttention,
          onTap: onOpenGoogleSetup,
        ),
        if (onOpenApiUsage != null)
          _SettingsLinkTile(
            key: const ValueKey('settings-api-usage'),
            icon: Icons.data_usage,
            title: 'API usage',
            subtitle: 'Free allowances, rollover, and request controls',
            onTap: onOpenApiUsage!,
          ),
        _SettingsLinkTile(
          key: const ValueKey('settings-permissions'),
          icon: Icons.admin_panel_settings_outlined,
          title: 'Permissions',
          subtitle: permissionsSummary,
          showWarning: readinessLoaded && permissionsNeedAttention,
          onTap: onOpenPermissions,
        ),
        _SettingsLinkTile(
          key: const ValueKey('settings-watch-connection'),
          icon: Icons.watch_outlined,
          title: 'Watch connection',
          subtitle: watchSummary,
          onTap: onOpenWatchConnection,
        ),
        const _SettingsSectionHeader('Watch preferences'),
        _SettingsLinkTile(
          icon: Icons.alt_route_outlined,
          title: 'Navigation',
          subtitle: 'Units, travel mode, feedback',
          onTap: onOpenNavigationPreferences,
        ),
        _SettingsLinkTile(
          icon: Icons.palette_outlined,
          title: 'Appearance',
          subtitle: 'Backlight',
          onTap: onOpenAppearancePreferences,
        ),
        _SettingsLinkTile(
          icon: Icons.map_outlined,
          title: 'Watch map',
          subtitle: 'Orientation, animation, and tiles',
          onTap: onOpenWatchMapPreferences,
        ),
        const _SettingsSectionHeader('Support'),
        _SettingsLinkTile(
          icon: Icons.help_outline,
          title: 'Help & diagnostics',
          subtitle: 'Compass calibration and troubleshooting',
          onTap: onOpenDiagnostics,
        ),
        _SettingsLinkTile(
          icon: Icons.info_outline,
          title: 'About',
          onTap: onOpenAbout,
        ),
      ],
    );
  }
}

class WatchConnectionScreen extends StatefulWidget {
  const WatchConnectionScreen({
    required this.initialStatus,
    required this.initialDetail,
    required this.onRefresh,
    required this.onOpenWatch,
    super.key,
  });

  final BridgeStatus initialStatus;
  final String? initialDetail;
  final Future<BridgeStatus> Function() onRefresh;
  final Future<BridgeStatus> Function() onOpenWatch;

  @override
  State<WatchConnectionScreen> createState() => _WatchConnectionScreenState();
}

class _WatchConnectionScreenState extends State<WatchConnectionScreen> {
  late BridgeStatus _status;
  late String? _detail;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _status = widget.initialStatus;
    _detail = widget.initialDetail;
  }

  Future<void> _run(Future<BridgeStatus> Function() action) async {
    setState(() => _busy = true);
    final status = await action();
    if (!mounted) return;
    setState(() {
      _status = status;
      _busy = false;
      _detail = null;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Watch connection')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _ReadinessBanner(
          ready: _status.watchReady,
          icon: _status.watchReady
              ? Icons.watch_outlined
              : Icons.watch_off_outlined,
          title: _status.watchLabel,
          detail: _status.watchDetailLabel,
        ),
        const SizedBox(height: 12),
        ListTile(
          leading: const Icon(Icons.run_circle_outlined),
          title: const Text('Watch session'),
          subtitle: Text(_status.foregroundServiceLabel),
        ),
        ListTile(
          leading: const Icon(Icons.gps_fixed),
          title: const Text('Live GPS'),
          subtitle: Text(_status.locationStreamLabel),
        ),
        if (_detail != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(_detail!),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const ValueKey('open-watch'),
          onPressed: _busy ? null : () => _run(widget.onOpenWatch),
          icon: const Icon(Icons.watch_outlined),
          label: Text(_busy ? 'Working' : 'Open watch'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _run(widget.onRefresh),
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh'),
        ),
      ],
    ),
  );
}

class PermissionsSnapshot {
  const PermissionsSnapshot({
    required this.location,
    required this.notification,
    required this.battery,
  });

  final LocationAccessStatus location;
  final NotificationPermissionState notification;
  final BatteryOptimizationState battery;

  bool get needsAttention =>
      !location.isReady ||
      !notification.allowsWatchNotification ||
      battery != BatteryOptimizationState.disabled;
}

enum PermissionsFocus { location, reliability }

class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({
    required this.initialSnapshot,
    required this.onRefresh,
    required this.onRequestForegroundLocation,
    required this.onOpenAppLocationSettings,
    required this.onOpenLocationServicesSettings,
    required this.onRequestNotifications,
    required this.onOpenNotificationSettings,
    required this.onRequestBatteryExemption,
    required this.onOpenBatterySettings,
    this.focus,
    super.key,
  });

  final PermissionsSnapshot initialSnapshot;
  final Future<PermissionsSnapshot> Function() onRefresh;
  final Future<LocationAccessStatus> Function() onRequestForegroundLocation;
  final Future<bool> Function() onOpenAppLocationSettings;
  final Future<bool> Function() onOpenLocationServicesSettings;
  final Future<BridgeStatus> Function() onRequestNotifications;
  final Future<bool> Function() onOpenNotificationSettings;
  final Future<BatteryOptimizationState> Function() onRequestBatteryExemption;
  final Future<bool> Function() onOpenBatterySettings;
  final PermissionsFocus? focus;

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  final GlobalKey _locationSectionKey = GlobalKey(
    debugLabel: 'permissions-location-section',
  );
  final GlobalKey _notificationSectionKey = GlobalKey(
    debugLabel: 'permissions-notification-section',
  );
  final GlobalKey _batterySectionKey = GlobalKey(
    debugLabel: 'permissions-battery-section',
  );
  late PermissionsSnapshot _snapshot;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _snapshot = widget.initialSnapshot;
    _scheduleFocus();
  }

  @override
  void didUpdateWidget(PermissionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focus != oldWidget.focus) _scheduleFocus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  void _scheduleFocus() {
    if (widget.focus == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_focusRequestedSection());
    });
  }

  Future<void> _focusRequestedSection() async {
    final focus = widget.focus;
    if (focus == null) return;
    final targetKey = switch (focus) {
      PermissionsFocus.location => _locationSectionKey,
      PermissionsFocus.reliability =>
        !_snapshot.notification.allowsWatchNotification
            ? _notificationSectionKey
            : _batterySectionKey,
    };
    final targetContext = targetKey.currentContext;
    if (targetContext == null) return;
    await Scrollable.ensureVisible(
      targetContext,
      alignment: 0.05,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    final label = focus == PermissionsFocus.location
        ? 'Location permissions'
        : 'Background reliability permissions';
    SemanticsService.sendAnnouncement(
      View.of(context),
      label,
      Directionality.of(context),
    );
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final snapshot = await widget.onRefresh();
      if (!mounted) return;
      setState(() => _snapshot = snapshot);
    } catch (_) {
      if (mounted) _showFailure('Permissions could not be refreshed.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _perform(Future<Object?> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      final snapshot = await widget.onRefresh();
      if (!mounted) return;
      setState(() => _snapshot = snapshot);
    } catch (_) {
      if (mounted) _showFailure('That setting could not be opened or updated.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showFailure(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final location = _snapshot.location;
    final notification = _snapshot.notification;
    final batteryReady = _snapshot.battery == BatteryOptimizationState.disabled;
    final batteryLabel = switch (_snapshot.battery) {
      BatteryOptimizationState.disabled => 'Unrestricted',
      BatteryOptimizationState.enabled => 'Optimized',
      BatteryOptimizationState.unknown => 'Unknown',
      BatteryOptimizationState.unavailable => 'Unavailable',
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('Permissions'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _PermissionSection(
            key: _locationSectionKey,
            icon: Icons.location_on_outlined,
            title: 'Location',
            ready: location.isReady,
            children: [
              _PermissionStatusRow(
                title: 'Device location services',
                value: location.servicesEnabled ? 'Ready' : 'Off',
                ready: location.servicesEnabled,
                actionLabel: location.servicesEnabled ? null : 'Turn on',
                onAction: location.servicesEnabled || _busy
                    ? null
                    : () => _perform(widget.onOpenLocationServicesSettings),
              ),
              _PermissionStatusRow(
                title: 'App location access',
                value: location.foregroundState.label,
                ready: location.foregroundGranted,
                actionLabel: location.foregroundGranted
                    ? null
                    : location.foregroundState.canRequest
                    ? 'Allow'
                    : 'Open settings',
                onAction: location.foregroundGranted || _busy
                    ? null
                    : () => _perform(
                        location.foregroundState.canRequest
                            ? widget.onRequestForegroundLocation
                            : widget.onOpenAppLocationSettings,
                      ),
              ),
              _PermissionStatusRow(
                title: 'Background location',
                value: !location.backgroundRequired
                    ? 'Not required'
                    : location.backgroundGranted
                    ? 'Allowed'
                    : 'Not allowed',
                ready: location.backgroundReady,
                actionLabel: location.backgroundReady ? null : 'Allow always',
                onAction:
                    location.backgroundReady ||
                        !location.foregroundGranted ||
                        _busy
                    ? null
                    : () => _perform(widget.onOpenAppLocationSettings),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _PermissionSection(
            key: _notificationSectionKey,
            icon: Icons.notifications_outlined,
            title: 'Notifications',
            ready: notification.allowsWatchNotification,
            children: [
              _PermissionStatusRow(
                title: 'Watch-session notifications',
                value: notification == NotificationPermissionState.notRequired
                    ? 'Not required'
                    : notification.allowsWatchNotification
                    ? 'Ready'
                    : 'Not allowed',
                ready: notification.allowsWatchNotification,
                actionLabel: notification.allowsWatchNotification
                    ? null
                    : notification.canRequest
                    ? 'Allow'
                    : 'Open settings',
                onAction: notification.allowsWatchNotification || _busy
                    ? null
                    : () => _perform(
                        notification.canRequest
                            ? widget.onRequestNotifications
                            : widget.onOpenNotificationSettings,
                      ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _PermissionSection(
            key: _batterySectionKey,
            icon: Icons.battery_saver_outlined,
            title: 'Battery usage',
            ready: batteryReady,
            children: [
              _PermissionStatusRow(
                title: 'Background optimization',
                value: batteryLabel,
                ready: batteryReady,
                actionLabel: batteryReady ? null : 'Change setting',
                onAction: !_snapshot.battery.canRequest || _busy
                    ? null
                    : () => _perform(widget.onRequestBatteryExemption),
              ),
              if (_snapshot.battery != BatteryOptimizationState.unavailable)
                ListTile(
                  title: const Text('Phone battery settings'),
                  subtitle: const Text(
                    'Open Mappy’s app settings to review battery usage. If your '
                    'phone has autostart or sleeping-app controls, also allow '
                    'Mappy there. These extra settings cannot be checked here.',
                  ),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: _busy
                      ? null
                      : () => _perform(() async {
                          final opened = await widget.onOpenBatterySettings();
                          if (!opened && mounted) {
                            _showFailure(
                              'Phone battery settings could not be opened.',
                            );
                          }
                          return opened;
                        }),
                ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 20),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}

class _PermissionSection extends StatelessWidget {
  const _PermissionSection({
    required this.icon,
    required this.title,
    required this.ready,
    required this.children,
    super.key,
  });

  final IconData icon;
  final String title;
  final bool ready;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '$title, ${ready ? 'Ready' : 'Needs attention'}',
    child: Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            leading: Icon(icon),
            title: Text(title),
            subtitle: Text(ready ? 'Ready' : 'Needs attention'),
            trailing: Icon(
              ready ? Icons.check_circle_outline : Icons.warning_amber,
              color: ready ? const Color(0xFF135D36) : const Color(0xFF715000),
            ),
          ),
          const Divider(height: 1),
          ...children,
        ],
      ),
    ),
  );
}

class _PermissionStatusRow extends StatelessWidget {
  const _PermissionStatusRow({
    required this.title,
    required this.value,
    required this.ready,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String value;
  final bool ready;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(title),
    subtitle: Text(value),
    leading: Icon(
      ready ? Icons.check_circle_outline : Icons.error_outline,
      color: ready ? const Color(0xFF135D36) : const Color(0xFF715000),
    ),
    trailing: actionLabel == null
        ? null
        : TextButton(onPressed: onAction, child: Text(actionLabel!)),
  );
}

class _SettingsSectionHeader extends StatelessWidget {
  const _SettingsSectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _SettingsLinkTile extends StatelessWidget {
  const _SettingsLinkTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.showWarning = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool showWarning;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Semantics(
      label: showWarning ? '$title, needs attention' : title,
      child: _WarningDotIcon(icon: icon, show: showWarning),
    ),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

class _WarningDotIcon extends StatelessWidget {
  const _WarningDotIcon({required this.icon, required this.show});

  final IconData icon;
  final bool show;

  @override
  Widget build(BuildContext context) => Badge(
    isLabelVisible: show,
    smallSize: 9,
    backgroundColor: const Color(0xFFE0A000),
    child: Icon(icon),
  );
}

class NavigationPreferencesScreen extends StatefulWidget {
  const NavigationPreferencesScreen({
    required this.initialSettings,
    required this.onChanged,
    super.key,
  });

  final WatchDisplaySettings initialSettings;
  final Future<WatchDisplaySettings> Function(WatchDisplaySettings settings)
  onChanged;

  @override
  State<NavigationPreferencesScreen> createState() =>
      _NavigationPreferencesScreenState();
}

class _NavigationPreferencesScreenState
    extends State<NavigationPreferencesScreen> {
  late WatchDisplaySettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
  }

  Future<void> _save(WatchDisplaySettings settings) async {
    final saved = await widget.onChanged(settings);
    if (mounted) setState(() => _settings = saved);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Navigation preferences')),
    body: ListView(
      children: [
        _PreferenceChoiceTile<WatchUnitsMode>(
          icon: Icons.straighten_outlined,
          title: 'Units',
          value: _settings.unitsMode,
          values: WatchUnitsMode.values,
          labelFor: (value) => value.label,
          onChanged: (value) => _save(_settings.copyWith(unitsMode: value)),
        ),
        _PreferenceChoiceTile<WatchTravelMode>(
          icon: Icons.alt_route_outlined,
          title: 'Default travel mode',
          value: _settings.travelMode,
          values: const [
            WatchTravelMode.walk,
            WatchTravelMode.drive,
            WatchTravelMode.bike,
          ],
          labelFor: (value) => value.label,
          onChanged: (value) => _save(_settings.copyWith(travelMode: value)),
        ),
        _PreferenceChoiceTile<WatchNavigationFeedbackMode>(
          icon: Icons.vibration,
          title: 'Haptics',
          value: _settings.hapticMode,
          values: WatchNavigationFeedbackMode.values,
          labelFor: (value) => value.label,
          onChanged: (value) => _save(_settings.copyWith(hapticMode: value)),
        ),
        _PreferenceChoiceTile<WatchNavigationFeedbackMode>(
          icon: Icons.visibility_outlined,
          title: 'Navigation glance',
          value: _settings.glanceMode,
          values: WatchNavigationFeedbackMode.values,
          labelFor: (value) => value.label,
          onChanged: (value) => _save(_settings.copyWith(glanceMode: value)),
        ),
      ],
    ),
  );
}

class AppearancePreferencesScreen extends StatefulWidget {
  const AppearancePreferencesScreen({
    required this.initialSettings,
    required this.onChanged,
    super.key,
  });

  final WatchDisplaySettings initialSettings;
  final Future<WatchDisplaySettings> Function(WatchDisplaySettings settings)
  onChanged;

  @override
  State<AppearancePreferencesScreen> createState() =>
      _AppearancePreferencesScreenState();
}

class _AppearancePreferencesScreenState
    extends State<AppearancePreferencesScreen> {
  late WatchDisplaySettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
  }

  Future<void> _save(WatchDisplaySettings settings) async {
    final saved = await widget.onChanged(settings);
    if (mounted) setState(() => _settings = saved);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Appearance')),
    body: ListView(
      children: [
        _PreferenceChoiceTile<WatchBacklightMode>(
          icon: Icons.light_mode_outlined,
          title: 'Backlight',
          value: _settings.backlightMode,
          values: WatchBacklightMode.values,
          labelFor: (value) => value.label,
          onChanged: (value) => _save(_settings.copyWith(backlightMode: value)),
        ),
      ],
    ),
  );
}

class WatchMapPreferencesScreen extends StatefulWidget {
  const WatchMapPreferencesScreen({
    required this.initialDisplaySettings,
    required this.initialMapSettings,
    required this.onDisplayChanged,
    required this.onMapChanged,
    super.key,
  });

  final WatchDisplaySettings initialDisplaySettings;
  final MapTileSettings initialMapSettings;
  final Future<WatchDisplaySettings> Function(WatchDisplaySettings settings)
  onDisplayChanged;
  final Future<MapTileSettings> Function(MapTileSettings settings) onMapChanged;

  @override
  State<WatchMapPreferencesScreen> createState() =>
      _WatchMapPreferencesScreenState();
}

class _WatchMapPreferencesScreenState extends State<WatchMapPreferencesScreen> {
  late WatchDisplaySettings _display;
  late MapTileSettings _map;

  @override
  void initState() {
    super.initState();
    _display = widget.initialDisplaySettings;
    _map = widget.initialMapSettings;
  }

  Future<void> _saveDisplay(WatchDisplaySettings settings) async {
    final saved = await widget.onDisplayChanged(settings);
    if (mounted) setState(() => _display = saved);
  }

  Future<void> _saveMap(MapTileSettings settings) async {
    final saved = await widget.onMapChanged(settings);
    if (mounted) setState(() => _map = saved);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Watch map')),
    body: ListView(
      children: [
        _PreferenceChoiceTile<WatchMapOrientation>(
          icon: Icons.explore_outlined,
          title: 'Orientation',
          value: _display.mapOrientation,
          values: WatchMapOrientation.values,
          labelFor: (value) => value.label,
          onChanged: (value) =>
              _saveDisplay(_display.copyWith(mapOrientation: value)),
        ),
        _PreferenceChoiceTile<WatchTileAnimationMode>(
          icon: Icons.animation,
          title: 'Tile animation',
          value: _display.tileAnimationMode,
          values: WatchTileAnimationMode.values,
          labelFor: (value) => value.label,
          onChanged: (value) =>
              _saveDisplay(_display.copyWith(tileAnimationMode: value)),
        ),
        _PreferenceChoiceTile<MapTileSource>(
          icon: Icons.layers_outlined,
          title: 'Tile source',
          value: _map.source,
          values: MapTileSource.values,
          labelFor: (value) => value.label,
          onChanged: (value) => _saveMap(_map.copyWith(source: value)),
        ),
        _PreferenceChoiceTile<WatchTileSize>(
          icon: Icons.grid_view_outlined,
          title: 'Rendered tile',
          value: _map.tileSize,
          values: WatchTileSize.values,
          labelFor: (value) => value.label,
          onChanged: (value) => _saveMap(_map.copyWith(tileSize: value)),
        ),
      ],
    ),
  );
}

class _PreferenceChoiceTile<T> extends StatelessWidget {
  const _PreferenceChoiceTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.values,
    required this.labelFor,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final T value;
  final List<T> values;
  final String Function(T value) labelFor;
  final Future<void> Function(T value) onChanged;

  Future<void> _open(BuildContext context) async {
    final selected = await showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
            for (final option in values)
              ListTile(
                title: Text(labelFor(option)),
                trailing: option == value ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, option),
              ),
          ],
        ),
      ),
    );
    if (selected != null && selected != value) await onChanged(selected);
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(labelFor(value)),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => _open(context),
  );
}

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({
    required this.events,
    required this.isClearingDiagnostics,
    required this.onExportDiagnostics,
    required this.onClearDiagnostics,
    required this.isClearingTileCache,
    required this.onClearTileCache,
    required this.isClearingRouteCache,
    required this.onClearRouteCache,
    required this.isClearingProviderValidationCache,
    required this.onClearProviderValidationCache,
    super.key,
  });

  final List<String> events;
  final bool isClearingDiagnostics;
  final Future<void> Function() onExportDiagnostics;
  final Future<void> Function() onClearDiagnostics;
  final bool isClearingTileCache;
  final Future<void> Function() onClearTileCache;
  final bool isClearingRouteCache;
  final Future<void> Function() onClearRouteCache;
  final bool isClearingProviderValidationCache;
  final Future<void> Function() onClearProviderValidationCache;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Help & diagnostics')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const ExpansionTile(
            key: PageStorageKey('compass-calibration-help'),
            leading: Icon(Icons.explore_outlined),
            title: Text('Compass points the wrong way'),
            subtitle: Text('Fix jumps or rotation that only moves halfway'),
            childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 20),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'An inaccurate compass calibration can make Face forward '
                'rotate only halfway, jump suddenly, or point in the wrong '
                'direction. Recalibrating the watch can fix this.',
              ),
              SizedBox(height: 16),
              Text(
                '1. Open Mappy on your watch in Face forward mode, or open a '
                'compass app. Keep it open while you recalibrate.',
              ),
              SizedBox(height: 12),
              Text(
                '2. Briefly attach the watch charger until charging registers, '
                'then remove it. This clears the saved compass calibration.',
              ),
              SizedBox(height: 12),
              Text(
                '3. Move away from the charger, phone, magnets, and metal '
                'furniture. Gently rotate and tilt the watch in several '
                'directions to let it recalibrate. If your compass app shows '
                'a calibration status, wait for Calibrated.',
              ),
              SizedBox(height: 12),
              Text(
                '4. Hold the watch face level, turn it roughly 90 degrees, '
                'and hold still for two seconds. The map should rotate by '
                'about the same amount; a compass reading should change by '
                'about 90 degrees. Repeat in the other direction.',
              ),
              SizedBox(height: 16),
              Text(
                'If the problem continues, try another location and check '
                'for watch firmware updates. You can use North up while '
                'troubleshooting: Settings > Watch map > Orientation.',
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('copy-diagnostics'),
            onPressed: onExportDiagnostics,
            icon: const Icon(Icons.copy_outlined),
            label: const Text('Copy diagnostics'),
          ),
          const SizedBox(height: 12),
          ExpansionTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('Recent events'),
            subtitle: Text(
              events.isEmpty
                  ? 'No diagnostics yet'
                  : '${events.length} recorded',
            ),
            children: [
              if (events.isEmpty)
                const ListTile(title: Text('No diagnostics yet'))
              else
                for (final event in events.take(8))
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.circle, size: 8),
                    title: Text(event),
                  ),
            ],
          ),
          ExpansionTile(
            leading: const Icon(Icons.build_outlined),
            title: const Text('Maintenance'),
            children: [
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(
                  isClearingDiagnostics
                      ? 'Clearing diagnostics'
                      : 'Clear diagnostics',
                ),
                enabled: !isClearingDiagnostics,
                onTap: isClearingDiagnostics ? null : onClearDiagnostics,
              ),
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: Text(
                  isClearingTileCache
                      ? 'Clearing tile cache'
                      : 'Clear tile cache',
                ),
                enabled: !isClearingTileCache,
                onTap: isClearingTileCache ? null : onClearTileCache,
              ),
              ListTile(
                leading: const Icon(Icons.route_outlined),
                title: Text(
                  isClearingRouteCache
                      ? 'Clearing active route'
                      : 'Clear active route',
                ),
                enabled: !isClearingRouteCache,
                onTap: isClearingRouteCache ? null : onClearRouteCache,
              ),
              ListTile(
                leading: const Icon(Icons.verified_user_outlined),
                title: Text(
                  isClearingProviderValidationCache
                      ? 'Clearing validation cache'
                      : 'Clear provider validation cache',
                ),
                enabled: !isClearingProviderValidationCache,
                onTap: isClearingProviderValidationCache
                    ? null
                    : onClearProviderValidationCache,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum StatusTone { ok, warning, neutral }

class StatusPill extends StatelessWidget {
  const StatusPill({
    required this.icon,
    required this.label,
    required this.tone,
    super.key,
  });

  final IconData icon;
  final String label;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (background, foreground) = switch (tone) {
      StatusTone.ok => (const Color(0xFFE0F1E7), const Color(0xFF135D36)),
      StatusTone.warning => (const Color(0xFFFFF0C2), const Color(0xFF715000)),
      StatusTone.neutral => (
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurfaceVariant,
      ),
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 8),
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(color: foreground),
            ),
          ],
        ),
      ),
    );
  }
}
