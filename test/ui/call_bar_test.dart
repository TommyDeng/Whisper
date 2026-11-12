import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/call/call_service.dart';
import 'package:whisper/contact/contact.dart';
import 'package:whisper/ui/app_theme.dart';
import 'package:whisper/ui/call_overlay.dart';
import 'package:whisper/voice/ice_strategy.dart';

Contact _contact() => Contact(
      deviceId: 'bob',
      name: 'Bob',
      x25519PublicKeyBase64: 'k',
      ed25519PublicKeyBase64: 'e',
      safetyCode: 'code',
      isVerified: false,
      createdAt: 1,
      lastMessageTime: 0,
      sessionId: 'session-call-bar',
      peerRole: 'a',
    );

void main() {
  testWidgets('通话中输入框仍可输入，通话条只在顶部', (tester) async {
    const inputKey = Key('chat-input');
    final now = DateTime(2026, 1, 1, 12, 0, 30);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Column(
            children: [
              CallBar(
                snapshot: CallSnapshot(
                  phase: CallPhase.active,
                  contact: _contact(),
                  muted: false,
                  connectedAt: DateTime(2026, 1, 1, 12),
                ),
                path: IcePathType.lan,
                micLevel: 0.5,
                now: now,
              ),
              const Expanded(
                child: TextField(key: inputKey, decoration: InputDecoration(hintText: '输入消息...')),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('00:30'), findsOneWidget);
    expect(find.text('端到端加密 · 局域网直连'), findsOneWidget);
    expect(find.text('挂断'), findsOneWidget);
    expect(find.text('静音'), findsOneWidget);
    expect(find.byType(MicLevelBar), findsOneWidget);

    await tester.enterText(find.byKey(inputKey), '通话时也能发消息');
    expect(find.text('通话时也能发消息'), findsOneWidget);
  });

  testWidgets('来电横幅有接听和拒接，不挡住输入', (tester) async {
    const inputKey = Key('chat-input');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Column(
            children: [
              CallBar(
                snapshot: CallSnapshot(phase: CallPhase.incoming, contact: _contact()),
                path: null,
                micLevel: 0,
              ),
              const Expanded(child: TextField(key: inputKey)),
            ],
          ),
        ),
      ),
    );
    expect(find.text('语音来电'), findsOneWidget);
    expect(find.text('接听'), findsOneWidget);
    expect(find.text('拒接'), findsOneWidget);
    await tester.enterText(find.byKey(inputKey), 'hi');
    expect(find.text('hi'), findsOneWidget);
  });
}
