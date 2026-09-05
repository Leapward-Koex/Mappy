import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

const mappyGitHubUri = 'https://github.com/Leapward-Koex/Mappy';

typedef AboutInfoLoader = Future<AboutAppInfo> Function();
typedef ExternalUrlLauncher = Future<bool> Function(Uri uri);

@immutable
class AboutAppInfo {
  const AboutAppInfo({required this.version, required this.buildNumber});

  final String version;
  final String buildNumber;
}

Future<AboutAppInfo> _loadAboutAppInfo() async {
  final packageInfo = await PackageInfo.fromPlatform();
  return AboutAppInfo(
    version: packageInfo.version,
    buildNumber: packageInfo.buildNumber,
  );
}

Future<bool> _launchExternalUrl(Uri uri) {
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

class AboutScreen extends StatefulWidget {
  const AboutScreen({
    super.key,
    this.loadInfo = _loadAboutAppInfo,
    this.launchExternalUrl = _launchExternalUrl,
  });

  final AboutInfoLoader loadInfo;
  final ExternalUrlLauncher launchExternalUrl;

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  late final Future<AboutAppInfo> _appInfo;

  @override
  void initState() {
    super.initState();
    _appInfo = widget.loadInfo();
  }

  Future<void> _openGitHub() async {
    var launched = false;
    try {
      launched = await widget.launchExternalUrl(Uri.parse(mappyGitHubUri));
    } on Object {
      launched = false;
    }

    if (!mounted || launched) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Couldn\'t open the Mappy GitHub repository.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          children: [
            Center(
              child: Column(
                children: [
                  Semantics(
                    label: 'Mappy app icon',
                    image: true,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: Image.asset(
                        'icon/icon_1024_1024.png',
                        width: 96,
                        height: 96,
                        fit: BoxFit.cover,
                        excludeFromSemantics: true,
                        errorBuilder: (context, error, stackTrace) {
                          return ColoredBox(
                            color: colorScheme.primaryContainer,
                            child: SizedBox.square(
                              dimension: 96,
                              child: Icon(
                                Icons.navigation_rounded,
                                size: 52,
                                color: colorScheme.onPrimaryContainer,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Mappy',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  FutureBuilder<AboutAppInfo>(
                    future: _appInfo,
                    builder: (context, snapshot) {
                      final text = switch (snapshot) {
                        AsyncSnapshot(
                          connectionState: ConnectionState.done,
                          hasData: true,
                          data: final info?,
                        ) =>
                          'Version ${info.version} (build ${info.buildNumber})',
                        AsyncSnapshot(connectionState: ConnectionState.done) =>
                          'Version unavailable',
                        _ => 'Loading version…',
                      };
                      return Text(
                        text,
                        key: const Key('about-version'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            FilledButton.tonalIcon(
              key: const Key('about-github-button'),
              onPressed: _openGitHub,
              icon: const Icon(Icons.code_rounded),
              label: const Text('View source on GitHub'),
            ),
          ],
        ),
      ),
    );
  }
}
