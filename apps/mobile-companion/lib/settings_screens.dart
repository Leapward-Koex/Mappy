import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'battery_optimization_bridge.dart';
import 'bridge_channel.dart';
import 'location_bridge.dart';
import 'provider_bridge.dart';
import 'watch_phone_worker.dart';
import 'watch_protocol.dart';

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
      _message = _providerReady(status)
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
      _message = _providerReady(status)
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

  @override
  Widget build(BuildContext context) {
    final ready = _providerReady(_status);
    final packageName = _status.packageName ?? 'com.leapwardkoex.mappy';
    final sha = _status.certSha1;
    const requiredApis = 'Map Tiles, Places, Geocoding, and Routes';
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
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
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
          Text('Google Cloud restrictions', style: theme.textTheme.titleMedium),
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
        ],
      ),
    );
  }
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
          subtitle: 'Theme and backlight',
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
                onAction: batteryReady || _busy
                    ? null
                    : () => _perform(widget.onRequestBatteryExemption),
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
            WatchTravelMode.drive,
            WatchTravelMode.walk,
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
        _PreferenceChoiceTile<WatchThemeMode>(
          icon: Icons.brightness_6_outlined,
          title: 'Theme',
          value: _settings.themeMode,
          values: WatchThemeMode.values,
          labelFor: (value) => value.label,
          onChanged: (value) => _save(_settings.copyWith(themeMode: value)),
        ),
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
