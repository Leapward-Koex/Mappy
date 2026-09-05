import 'package:flutter/material.dart';

import 'battery_optimization_bridge.dart';
import 'bridge_channel.dart';
import 'provider_bridge.dart';
import 'settings_screens.dart';

const int setupChecklistCurrentVersion = 1;

class SetupChecklistSnapshot {
  const SetupChecklistSnapshot({
    required this.providerStatus,
    required this.permissions,
  });

  final ProviderStatus providerStatus;
  final PermissionsSnapshot permissions;

  bool get providerReady =>
      providerStatus.configured &&
      providerStatus.validationState == ProviderValidationState.valid;

  bool get locationReady => permissions.location.isReady;

  bool get notificationsReady =>
      permissions.notification.allowsWatchNotification;

  bool get batteryReady =>
      permissions.battery == BatteryOptimizationState.disabled;

  bool get reliabilityReady => notificationsReady && batteryReady;

  bool get requiredReady => providerReady && locationReady;

  bool get allReady => requiredReady && reliabilityReady;

  bool get needsAttention => !allReady;

  String get summary {
    if (!requiredReady) return 'Needs setup';
    if (!reliabilityReady) return 'Recommendations available';
    return 'Ready';
  }
}

class FirstRunSetupChecklist extends StatelessWidget {
  const FirstRunSetupChecklist({
    required this.snapshot,
    required this.onOpenGoogleSetup,
    required this.onOpenPermissions,
    required this.onContinue,
    required this.onDismiss,
    this.manual = false,
    super.key,
  });

  final SetupChecklistSnapshot snapshot;
  final VoidCallback onOpenGoogleSetup;
  final ValueChanged<PermissionsFocus> onOpenPermissions;
  final VoidCallback onContinue;
  final VoidCallback onDismiss;
  final bool manual;

  @override
  Widget build(BuildContext context) {
    final primaryLabel = manual
        ? 'Done'
        : !snapshot.requiredReady
        ? 'Finish required setup'
        : snapshot.reliabilityReady
        ? 'Start using Mappy'
        : 'Continue for now';
    final primaryAction = manual || snapshot.requiredReady ? onContinue : null;

    return Scaffold(
      appBar: manual ? AppBar(title: const Text('Setup checklist')) : null,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalPadding = constraints.maxWidth < 360 ? 12.0 : 20.0;
            return Column(
              children: [
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: ListView(
                        key: const ValueKey('setup-checklist-list'),
                        padding: EdgeInsets.fromLTRB(
                          horizontalPadding,
                          manual ? 12 : 24,
                          horizontalPadding,
                          12,
                        ),
                        children: [
                          if (!manual) ...[
                            Icon(
                              Icons.route_outlined,
                              size: 42,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Set up Mappy',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Google Maps and location are required for routes. The reliability recommendations help Mappy keep watch updates running in the background.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 20),
                          ],
                          _ChecklistItem(
                            key: const ValueKey('setup-checklist-google'),
                            icon: Icons.key_outlined,
                            title: 'Google Maps',
                            requirement: 'Required',
                            ready: snapshot.providerReady,
                            detail: _providerDetail(snapshot),
                            actionLabel: snapshot.providerReady
                                ? 'Review'
                                : 'Set up',
                            onAction: onOpenGoogleSetup,
                          ),
                          const SizedBox(height: 10),
                          _ChecklistItem(
                            key: const ValueKey('setup-checklist-location'),
                            icon: Icons.location_on_outlined,
                            title: 'Location',
                            requirement: 'Required',
                            ready: snapshot.locationReady,
                            detail: _locationDetail(snapshot),
                            actionLabel: snapshot.locationReady
                                ? 'Review'
                                : 'Set up',
                            onAction: () =>
                                onOpenPermissions(PermissionsFocus.location),
                          ),
                          const SizedBox(height: 10),
                          _ChecklistItem(
                            key: const ValueKey('setup-checklist-reliability'),
                            icon: Icons.sync_lock_outlined,
                            title: 'Background reliability',
                            requirement: 'Recommended',
                            ready: snapshot.reliabilityReady,
                            detail: _reliabilityDetail(snapshot),
                            actionLabel: snapshot.reliabilityReady
                                ? 'Review'
                                : 'Improve',
                            onAction: () =>
                                onOpenPermissions(PermissionsFocus.reliability),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        8,
                        horizontalPadding,
                        12,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FilledButton(
                            key: const ValueKey(
                              'setup-checklist-primary-action',
                            ),
                            onPressed: primaryAction,
                            child: Text(primaryLabel),
                          ),
                          if (!manual && !snapshot.requiredReady) ...[
                            const SizedBox(height: 4),
                            TextButton(
                              key: const ValueKey(
                                'setup-checklist-dismiss-action',
                              ),
                              onPressed: onDismiss,
                              child: const Text('Do this later'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static String _providerDetail(SetupChecklistSnapshot snapshot) {
    if (snapshot.providerReady) return 'API key saved and validated.';
    final status = snapshot.providerStatus;
    if (!status.configured) {
      return 'Needs setup. Add and validate a Google API key.';
    }
    return switch (status.validationState) {
      ProviderValidationState.notConfigured =>
        'Needs setup. Add and validate a Google API key.',
      ProviderValidationState.notValidated =>
        'Not validated. Save and validate the configured key.',
      ProviderValidationState.validating => 'Validating the configured key.',
      ProviderValidationState.valid => 'API key saved and validated.',
      ProviderValidationState.invalidKey =>
        'Invalid key. Check the value and try again.',
      ProviderValidationState.apiDisabled =>
        'API disabled. Enable every required Google Maps API.',
      ProviderValidationState.quotaOrBillingIssue =>
        'Quota or billing issue. Check the Google Cloud project.',
      ProviderValidationState.providerPermissionDenied =>
        'Permission denied. Check the package name and signing SHA-1 restrictions.',
      ProviderValidationState.networkUnavailable =>
        'Network unavailable. Reconnect and retry validation.',
      ProviderValidationState.unsupportedRestrictedKeyBehavior =>
        'Key restrictions could not be validated. Review them and retry.',
      ProviderValidationState.unknown =>
        'Validation failed. Open setup for details and retry.',
    };
  }

  static String _locationDetail(SetupChecklistSnapshot snapshot) {
    final location = snapshot.permissions.location;
    if (!location.servicesEnabled) return 'Turn on device location services.';
    if (!location.foregroundGranted) {
      return 'Allow Mappy to use this phone’s location.';
    }
    if (!location.backgroundReady) {
      return 'Allow background location for navigation on the watch.';
    }
    return 'Device, app, and required background access are ready.';
  }

  static String _reliabilityDetail(SetupChecklistSnapshot snapshot) {
    final notification = switch (snapshot.permissions.notification) {
      NotificationPermissionState.granted => 'Ready',
      NotificationPermissionState.notRequired => 'Not required',
      NotificationPermissionState.requestAvailable => 'Needs permission',
      NotificationPermissionState.denied ||
      NotificationPermissionState.permanentlyDenied => 'Not allowed',
      NotificationPermissionState.unknown => 'Unknown',
      NotificationPermissionState.unavailable => 'Unavailable',
    };
    final battery = switch (snapshot.permissions.battery) {
      BatteryOptimizationState.disabled => 'Unrestricted',
      BatteryOptimizationState.enabled => 'Optimized',
      BatteryOptimizationState.unknown => 'Unknown',
      BatteryOptimizationState.unavailable => 'Unavailable',
    };
    return 'Notifications: $notification.\nBattery usage: $battery.';
  }
}

class _ChecklistItem extends StatelessWidget {
  const _ChecklistItem({
    required this.icon,
    required this.title,
    required this.requirement,
    required this.ready,
    required this.detail,
    required this.actionLabel,
    required this.onAction,
    super.key,
  });

  final IconData icon;
  final String title;
  final String requirement;
  final bool ready;
  final String detail;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final statusColor = ready ? colors.primary : colors.tertiary;
    final statusBackground = ready
        ? colors.primaryContainer
        : colors.tertiaryContainer;
    final statusIcon = ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: statusBackground,
          shape: BoxShape.circle,
        ),
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Icon(ready ? Icons.check : icon, size: 20, color: statusColor),
        ),
      ),
    );
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 2),
        Text(
          ready ? 'Ready' : 'Needs attention',
          style: theme.textTheme.labelMedium?.copyWith(color: statusColor),
        ),
      ],
    );
    final requirementPill = DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Text(requirement, style: theme.textTheme.labelSmall),
      ),
    );
    return Semantics(
      container: true,
      label: '$title, $requirement, ${ready ? 'Ready' : 'Needs attention'}',
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact =
                      constraints.maxWidth < 360 ||
                      MediaQuery.textScalerOf(context).scale(14) > 18;
                  final identity = Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      statusIcon,
                      const SizedBox(width: 12),
                      Expanded(child: titleBlock),
                    ],
                  );
                  if (compact) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        identity,
                        const SizedBox(height: 8),
                        requirementPill,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: identity),
                      const SizedBox(width: 8),
                      requirementPill,
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              Text(detail),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: onAction,
                  child: Text(actionLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
