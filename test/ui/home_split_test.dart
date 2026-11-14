import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/contact/contact_model.dart';
import 'package:whisper/ui/app_theme.dart';
import 'package:whisper/ui/contacts_list.dart';

Contact _contact(String id, String name) => Contact(
  deviceId: id,
  name: name,
  x25519PublicKeyBase64: 'key-$id-0123456789',
  ed25519PublicKeyBase64: 'sig-$id',
  safetyCode: '0000',
  isVerified: true,
  createdAt: 1,
  lastMessageTime: 1,
  sessionId: 'session-$id',
  peerRole: 'b',
);

void main() {
  late List<Contact> contacts;

  setUp(() {
    contacts = [_contact('a', '妈妈'), _contact('b', '老爸')];
  });

  Future<void> pumpHome(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: ContactsListScreen(
          loadContacts: () async => List.of(contacts),
          loadUnread: () async => {'session-b': 2},
          isOnline: (contact) => contact.deviceId == 'a',
          removeContact: (contact) async =>
              contacts.removeWhere((c) => c.deviceId == contact.deviceId),
          chatBuilder: (contact, onBack) => Column(
            children: [
              if (onBack != null)
                TextButton(onPressed: onBack, child: const Text('返回')),
              Text('聊天：${contact.name}'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool canPop(WidgetTester tester) =>
      tester.state<NavigatorState>(find.byType(Navigator)).canPop();

  ContactItem row(WidgetTester tester, String name) =>
      tester.widget<ContactItem>(find.widgetWithText(ContactItem, name));

  testWidgets('宽窗口：没选联系人时右边是空状态', (tester) async {
    await pumpHome(tester, const Size(1280, 720));

    expect(find.text('妈妈'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('选一个联系人开始聊天'), findsOneWidget);
    expect(find.textContaining('聊天：'), findsNothing);
  });

  testWidgets('宽窗口：点联系人后列表和聊天同屏，不跳页，该行选中', (tester) async {
    await pumpHome(tester, const Size(1280, 720));

    await tester.tap(find.text('妈妈'));
    await tester.pumpAndSettle();

    expect(find.text('聊天：妈妈'), findsOneWidget);
    expect(find.text('老爸'), findsOneWidget);
    expect(find.text('返回'), findsNothing);
    expect(find.text('选一个联系人开始聊天'), findsNothing);
    expect(canPop(tester), isFalse);
    expect(row(tester, '妈妈').selected, isTrue);
    expect(row(tester, '老爸').selected, isFalse);

    await tester.tap(find.text('老爸'));
    await tester.pumpAndSettle();

    expect(find.text('聊天：老爸'), findsOneWidget);
    expect(find.text('聊天：妈妈'), findsNothing);
    expect(row(tester, '老爸').selected, isTrue);
  });

  testWidgets('宽窗口：删除正在看的联系人后回到空状态', (tester) async {
    await pumpHome(tester, const Size(1280, 720));
    await tester.tap(find.text('妈妈'));
    await tester.pumpAndSettle();

    // 删除按钮鼠标移上去才出现。
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('妈妈')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ContactItem, '妈妈'),
        matching: find.byTooltip('删除联系人'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('删除 妈妈？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('妈妈'), findsNothing);
    expect(find.text('老爸'), findsOneWidget);
    expect(find.textContaining('聊天：'), findsNothing);
    expect(find.text('选一个联系人开始聊天'), findsOneWidget);
  });

  testWidgets('窄窗口：点联系人后只看到聊天，有返回', (tester) async {
    await pumpHome(tester, const Size(600, 720));

    expect(find.text('选一个联系人开始聊天'), findsNothing);
    await tester.tap(find.text('妈妈'));
    await tester.pumpAndSettle();

    expect(find.text('聊天：妈妈'), findsOneWidget);
    expect(find.text('老爸'), findsNothing);
    expect(canPop(tester), isFalse);

    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();

    expect(find.text('老爸'), findsOneWidget);
    expect(find.textContaining('聊天：'), findsNothing);
  });

  testWidgets('选中某人后把窗口拖窄再拖宽，一直是这个人的聊天', (tester) async {
    await pumpHome(tester, const Size(1280, 720));
    await tester.tap(find.text('老爸'));
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(600, 720);
    await tester.pumpAndSettle();
    expect(find.text('聊天：老爸'), findsOneWidget);
    expect(find.text('返回'), findsOneWidget);
    expect(find.text('妈妈'), findsNothing);

    tester.view.physicalSize = const Size(1280, 720);
    await tester.pumpAndSettle();
    expect(find.text('聊天：老爸'), findsOneWidget);
    expect(find.text('妈妈'), findsOneWidget);
    expect(row(tester, '老爸').selected, isTrue);
  });

  testWidgets('没有联系人时给出添加入口', (tester) async {
    contacts = [];
    await pumpHome(tester, const Size(1280, 720));

    expect(find.text('暂无联系人'), findsOneWidget);
    expect(find.text('用邀请码添加亲友'), findsOneWidget);
    expect(find.text('添加联系人'), findsOneWidget);
  });

  testWidgets('头像颜色只分在线和离线，和名字无关', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const Row(
          children: [
            ContactMark(name: '妈妈', online: true),
            ContactMark(name: '老爸', online: true),
            ContactMark(name: '小姨', online: false),
            ContactMark(name: '阿哲', online: false),
          ],
        ),
      ),
    );

    Color? letter(String text) =>
        tester.widget<Text>(find.text(text)).style?.color;
    expect(letter('妈'), AppTheme.accent);
    expect(letter('老'), AppTheme.accent);
    expect(letter('小'), AppTheme.text3);
    expect(letter('阿'), AppTheme.text3);
    expect(ContactMark.foregroundFor(online: true), AppTheme.accent);
    expect(ContactMark.backgroundFor(online: false), AppTheme.raised);
  });

  test('主题是深色，主色是荧光绿，警告色是红', () {
    final theme = AppTheme.dark;
    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.primary, const Color(0xFF00F5A0));
    expect(theme.colorScheme.error, const Color(0xFFFF3B3B));
    expect(theme.scaffoldBackgroundColor, const Color(0xFF05080A));
  });
}
