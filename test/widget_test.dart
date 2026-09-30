// Minimal smoke test: app builds and runs without crashing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:blind_nav_cam/main.dart';

void main() {
  testWidgets('App builds', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp(cameras: []));
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('Launching...'), findsOneWidget);
    // Unmount so the splash timer is cancelled before the test ends.
    await tester.pumpWidget(const SizedBox());
  });
}
