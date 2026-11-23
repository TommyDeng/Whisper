// 通话记录在聊天里的图标 / 文字 / 警示色映射。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/messaging/call_record.dart';
import 'package:whisper/ui/chat_screen.dart';

void main() {
  test('接通的呼出：箭头朝外、显示时长', () {
    final d = callRecordDisplay(
      const CallRecord(
        outgoing: true,
        outcome: CallOutcome.completed,
        duration: Duration(minutes: 5, seconds: 23),
      ),
    );
    expect(d.icon, Icons.call_made);
    expect(d.text, '通话时长 05:23');
    expect(d.alert, isFalse);
  });

  test('接通的来电：箭头朝内', () {
    final d = callRecordDisplay(
      const CallRecord(
        outgoing: false,
        outcome: CallOutcome.completed,
        duration: Duration(seconds: 5),
      ),
    );
    expect(d.icon, Icons.call_received);
    expect(d.text, '通话时长 00:05');
  });

  test('未接来电用警示色', () {
    final d = callRecordDisplay(
      const CallRecord(outgoing: false, outcome: CallOutcome.missed),
    );
    expect(d.icon, Icons.call_missed);
    expect(d.text, '未接来电');
    expect(d.alert, isTrue);
  });

  test('各结局都有文字', () {
    const texts = {
      CallOutcome.canceled: '已取消',
      CallOutcome.rejected: '对方已拒接',
      CallOutcome.declined: '已拒接',
      CallOutcome.busy: '对方忙线中',
      CallOutcome.offline: '对方不在线',
      CallOutcome.noAnswer: '无人接听',
      CallOutcome.failed: '通话失败',
    };
    texts.forEach((outcome, text) {
      final d = callRecordDisplay(
        CallRecord(outgoing: true, outcome: outcome),
      );
      expect(d.text, text);
    });
  });
}
