import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/desktop/autostart.dart';
import 'package:whisper/ui/about.dart';

class _FakeAutostart implements Autostart {
  _FakeAutostart({this.enabled = false, this.fail = false});

  bool enabled;
  bool fail;

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<void> setEnabled(bool value) async {
    if (fail) throw StateError('失败');
    enabled = value;
  }
}

Future<void> _pump(WidgetTester tester, Autostart autostart) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: AutostartSwitch(autostart: autostart)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('开关显示系统里的状态，点一下就改掉', (tester) async {
    final autostart = _FakeAutostart(enabled: false);
    await _pump(tester, autostart);
    expect(find.text('开机自动启动'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(autostart.enabled, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(autostart.enabled, isFalse);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('已经打开时开关是开的', (tester) async {
    await _pump(tester, _FakeAutostart(enabled: true));
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('设置失败时开关不变并给出提示', (tester) async {
    final autostart = _FakeAutostart(fail: true);
    await _pump(tester, autostart);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.text('设置没有成功'), findsOneWidget);
  });
}
