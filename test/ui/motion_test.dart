import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/ui/app_theme.dart';

double _scaleIn(WidgetTester tester, Finder button) => tester
    .widget<AnimatedScale>(
      find.descendant(of: button, matching: find.byType(AnimatedScale)).first,
    )
    .scale;

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.dark,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('Material 按钮按下缩小、松开弹回，点击照常生效', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(FilledButton(onPressed: () => taps++, child: const Text('配对'))),
    );
    final button = find.byType(FilledButton);
    expect(_scaleIn(tester, button), 1);

    final gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump(const Duration(milliseconds: 50));
    expect(_scaleIn(tester, button), Motion.pressedScale);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(_scaleIn(tester, button), 1);
    expect(taps, 1);
  });

  testWidgets('描边按钮悬停时铺一层底色', (tester) async {
    await tester.pumpWidget(
      _host(OutlinedButton(onPressed: () {}, child: const Text('复制'))),
    );
    Color? fill() =>
        (tester
                    .widget<AnimatedContainer>(
                      find.descendant(
                        of: find.byType(OutlinedButton),
                        matching: find.byType(AnimatedContainer),
                      ),
                    )
                    .decoration
                as BoxDecoration?)
            ?.color;
    expect(fill(), Colors.transparent);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(OutlinedButton)));
    await tester.pumpAndSettle();
    expect(fill(), isNot(Colors.transparent));
  });

  testWidgets('图标按钮：按下缩小，快速点击也能看到按下，不可点时没反应', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TermIconButton(
              key: const ValueKey('on'),
              icon: Icons.add,
              tooltip: '加',
              onPressed: () => taps++,
            ),
            const TermIconButton(
              key: ValueKey('off'),
              icon: Icons.remove,
              tooltip: '减',
              onPressed: null,
            ),
          ],
        ),
      ),
    );
    final on = find.byKey(const ValueKey('on'));
    await tester.tap(on);
    await tester.pump();
    // 抬起后仍保持按下一小会儿，然后弹回。
    expect(_scaleIn(tester, on), Motion.pressedScale);
    await tester.pumpAndSettle();
    expect(_scaleIn(tester, on), 1);
    expect(taps, 1);

    final off = find.byKey(const ValueKey('off'));
    await tester.tap(off, warnIfMissed: false);
    await tester.pump();
    expect(_scaleIn(tester, off), 1);
  });

  testWidgets('对话框弹出有过渡，结束后完整显示', (tester) async {
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showTermDialog<void>(
              context: context,
              builder: (_) => const TermDialog(
                title: '标题',
                tag: 'TEST_',
                content: Text('内容'),
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final mid = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byType(TermDialog),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(mid.opacity.value, inExclusiveRange(0, 1));

    await tester.pumpAndSettle();
    expect(find.text('内容'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(TermDialog), findsNothing);
  });
}
