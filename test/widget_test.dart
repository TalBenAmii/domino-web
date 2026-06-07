// Basic smoke test: the app builds and shows its title and the mic button.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:domino/main.dart';

void main() {
  testWidgets('App renders title and mic button', (WidgetTester tester) async {
    await tester.pumpWidget(const DominoApp());
    await tester.pump(); // build the first frame (avoid settling the pulse loop)

    expect(find.text('דיבור לטקסט'), findsWidgets);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
  });
}
