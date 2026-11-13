import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/ui/about.dart';
import 'package:whisper/update/app_update.dart';

class _FakeUpdater implements AppUpdater {
  _FakeUpdater({this.latest, this.kind = InstallKind.linuxDeb, this.error});

  String? latest;
  String? error;
  final gate = Completer<void>();
  String? installed;

  @override
  final InstallKind kind;

  @override
  Future<String?> latestVersion() async => latest;

  @override
  Future<void> downloadAndInstall(
    String version, {
    void Function(double progress)? onProgress,
    void Function()? onInstalling,
  }) async {
    onProgress?.call(0.5);
    await gate.future;
    if (error != null) throw UpdateException(error!);
    onInstalling?.call();
    installed = version;
  }
}

void main() {
  var quits = 0;

  Future<void> pump(WidgetTester tester, AppUpdater updater) async {
    quits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UpdateSection(
            updater: updater,
            currentVersion: '1.0.5',
            onQuit: () async => quits++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('版本一致时不出现更新按钮', (tester) async {
    await pump(tester, _FakeUpdater(latest: '1.0.5'));
    expect(find.text('已是最新版本'), findsOneWidget);
    expect(find.text('更新客户端'), findsNothing);
  });

  testWidgets('查不到最新版本时只提示，不出现按钮', (tester) async {
    await pump(tester, _FakeUpdater());
    expect(find.text('没能检查更新'), findsOneWidget);
    expect(find.text('更新客户端'), findsNothing);
  });

  testWidgets('有新版本：确认后下载安装，装好就退出让新版本启动', (tester) async {
    final updater = _FakeUpdater(latest: '1.0.6');
    await pump(tester, updater);
    expect(find.text('有新版本 1.0.6'), findsOneWidget);

    await tester.tap(find.text('更新客户端'));
    await tester.pumpAndSettle();
    expect(find.text('更新到 1.0.6？'), findsOneWidget);
    await tester.tap(find.text('更新'));
    await tester.pumpAndSettle();
    expect(find.text('正在下载… 50%'), findsOneWidget);
    expect(quits, 0);

    updater.gate.complete();
    await tester.pumpAndSettle();
    expect(updater.installed, '1.0.6');
    expect(quits, 1);
    expect(find.text('正在重启…'), findsOneWidget);
  });

  testWidgets('点取消就什么都不做', (tester) async {
    final updater = _FakeUpdater(latest: '1.0.6');
    await pump(tester, updater);
    await tester.tap(find.text('更新客户端'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('更新客户端'), findsOneWidget);
    expect(updater.installed, isNull);
    expect(quits, 0);
  });

  testWidgets('更新失败：显示原因，不退出，可以再试', (tester) async {
    final updater = _FakeUpdater(latest: '1.0.6', error: '签名校验没有通过，已停止更新');
    await pump(tester, updater);
    await tester.tap(find.text('更新客户端'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新'));
    updater.gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('签名校验没有通过，已停止更新'), findsOneWidget);
    expect(find.text('更新客户端'), findsOneWidget);
    expect(quits, 0);
  });

  testWidgets('便携包只给下载入口', (tester) async {
    await pump(tester, _FakeUpdater(latest: '1.0.6', kind: InstallKind.manual));
    expect(find.text('前往下载'), findsOneWidget);
    expect(find.text('更新客户端'), findsNothing);
  });
}
