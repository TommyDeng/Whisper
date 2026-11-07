import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_webrtc_spike/main.dart';

void main() {
  testWidgets('shows the spike shell', (tester) async {
    await tester.pumpWidget(const WhisperSpikeApp());
    expect(find.text('耳语 WebRTC Spike'), findsOneWidget);
    expect(find.text('DTLS-SRTP：开启（未关闭）。状态 —。应用层 E2EE：本 spike 没有。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
