import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mappy/about_screen.dart';

void main() {
  Widget buildSubject({
    AboutInfoLoader? loadInfo,
    ExternalUrlLauncher? launchExternalUrl,
  }) {
    return MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: AboutScreen(
        loadInfo:
            loadInfo ??
            () async => const AboutAppInfo(version: '1.2.3', buildNumber: '45'),
        launchExternalUrl: launchExternalUrl ?? (uri) async => true,
      ),
    );
  }

  testWidgets('shows app identity and installed version', (tester) async {
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    expect(find.text('About'), findsOneWidget);
    expect(find.text('Mappy'), findsOneWidget);
    expect(find.text('Version 1.2.3 (build 45)'), findsOneWidget);
    expect(find.text('View source on GitHub'), findsOneWidget);
  });

  testWidgets('opens the Mappy repository externally', (tester) async {
    Uri? launchedUri;
    await tester.pumpWidget(
      buildSubject(
        launchExternalUrl: (uri) async {
          launchedUri = uri;
          return true;
        },
      ),
    );

    await tester.tap(find.byKey(const Key('about-github-button')));
    await tester.pumpAndSettle();

    expect(launchedUri, Uri.parse(mappyGitHubUri));
    expect(
      find.text('Couldn\'t open the Mappy GitHub repository.'),
      findsNothing,
    );
  });

  testWidgets('shows feedback when GitHub cannot be opened', (tester) async {
    await tester.pumpWidget(
      buildSubject(launchExternalUrl: (uri) async => false),
    );

    await tester.tap(find.byKey(const Key('about-github-button')));
    await tester.pump();

    expect(
      find.text('Couldn\'t open the Mappy GitHub repository.'),
      findsOneWidget,
    );
  });

  testWidgets('shows a fallback when version loading fails', (tester) async {
    await tester.pumpWidget(
      buildSubject(loadInfo: () async => throw StateError('unavailable')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Version unavailable'), findsOneWidget);
  });
}
