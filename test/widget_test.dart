// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:whisper/main.dart';

void main() {
  testWidgets('Whisper smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const WhisperApp());

    // Verify the app title is shown.
    expect(find.text('耳语 Whisper'), findsOneWidget);
    expect(find.text('耳语 · 阶段二开发中 · 准备就绪'), findsOneWidget);
  });
}
