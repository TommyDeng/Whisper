import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:whisper/pairing/invitation_code.dart';
import 'package:whisper/pairing/pairing_manager.dart';
import 'package:whisper/pairing/pairing_page.dart';
import 'package:whisper/ui/app_theme.dart';

/// 邀请码要等 [ready] 完成才生成，用来看生成前后对话框大小。
class _SlowManager extends _FakeManager {
  final ready = Completer<void>();
  bool _made = false;

  @override
  InvitationCode? get openInvitation => _made ? _invitation : null;

  @override
  Future<InvitationCode> ensureInvitation() async {
    await ready.future;
    _made = true;
    return _invitation;
  }
}

class _FakeManager extends Fake implements PairingManager {
  final _invitation = InvitationCode(
    publicKey: Uint8List.fromList(List.generate(32, (i) => i)),
    token: Uint8List.fromList(List.generate(16, (i) => i + 100)),
    expiry: 1900000000,
  );

  @override
  Stream<void> get changes => const Stream.empty();

  @override
  Stream<PairingNotice> get notices => const Stream.empty();

  @override
  List<IncomingPairRequest> get incomingRequests => const [];

  @override
  List<OutgoingJoin> get joins => const [];

  @override
  InvitationCode? get openInvitation => _invitation;

  @override
  Future<InvitationCode> ensureInvitation() async => _invitation;

  @override
  bool isRegistered(InvitationCode invitation) => true;
}

void main() {
  testWidgets('添加联系人是一个对话框，点关闭收起', (tester) async {
    final manager = _FakeManager();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPairingDialog(context, manager: manager),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('添加联系人'), findsOneWidget);
    expect(find.text('输入对方的邀请码'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    // 背后的页面还在，说明没有整页跳转
    expect(find.text('打开'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('窗口很矮时内容可以滚动，不溢出', (tester) async {
    tester.view.physicalSize = const Size(500, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PairingPage(manager: _FakeManager())),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('邀请码生成前后对话框一样大，不跳动', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final manager = _SlowManager();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(body: PairingPage(manager: manager)),
      ),
    );
    await tester.pump();
    expect(find.byType(QrImageView), findsNothing);
    final before = tester.getRect(find.byType(Dialog));

    manager.ready.complete();
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(tester.getRect(find.byType(Dialog)), before);
  });

  testWidgets('已有邀请码时第一帧就显示二维码', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PairingPage(manager: _FakeManager())),
      ),
    );
    expect(find.byType(QrImageView), findsOneWidget);
  });
}
