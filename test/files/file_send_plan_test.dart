import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/files/file_cipher.dart';
import 'package:whisper/files/file_send_plan.dart';

void main() {
  const mib = 1024 * 1024;

  test('双方在线时无论大小都先走直传', () {
    expect(
      planFileSend(size: 10, peerOnline: true).action,
      FileSendAction.direct,
    );
    expect(
      planFileSend(size: FileCipher.maxFileBytes, peerOnline: true).action,
      FileSendAction.direct,
    );
    expect(
      planFileSend(size: FileCipher.maxFileBytes + 1, peerOnline: true).action,
      FileSendAction.direct,
    );
    expect(
      planFileSend(size: FileCipher.maxDirectFileBytes, peerOnline: true).action,
      FileSendAction.direct,
    );
  });

  test('超过 100 GiB 直接拒绝', () {
    final plan = planFileSend(
      size: FileCipher.maxDirectFileBytes + 1,
      peerOnline: true,
    );
    expect(plan.action, FileSendAction.tooLarge);
    expect(plan.reason, isNull);
  });

  test('对方离线且不超过中转上限：需要确认后走中转', () {
    final plan = planFileSend(size: 8 * mib, peerOnline: false);
    expect(plan.action, FileSendAction.relayConfirm);
    expect(plan.reason, 'offline');
  });

  test('对方离线且超过中转上限：不能中转', () {
    final plan = planFileSend(
      size: FileCipher.maxFileBytes + 1,
      peerOnline: false,
    );
    expect(plan.action, FileSendAction.relayUnavailable);
    expect(plan.reason, 'offline');
  });

  test('没有直传能力时与离线类似', () {
    final small = planFileSend(size: 100, peerOnline: true, directAvailable: false);
    expect(small.action, FileSendAction.relayConfirm);
    expect(small.reason, 'no-direct');

    final large = planFileSend(
      size: FileCipher.maxFileBytes + 1,
      peerOnline: true,
      directAvailable: false,
    );
    expect(large.action, FileSendAction.relayUnavailable);
    expect(large.reason, 'no-direct');
  });

  test('直传因离线或没有直连失败后，可改走中转；其它失败不行', () {
    expect(canFallbackToRelay('offline'), isTrue);
    expect(canFallbackToRelay('no-direct'), isTrue);
    expect(canFallbackToRelay('busy'), isFalse);
    expect(canFallbackToRelay('declined'), isFalse);
    expect(canFallbackToRelay('timeout'), isFalse);
    expect(canFallbackToRelay('network'), isFalse);
    expect(canFallbackToRelay('failed'), isFalse);

    final afterNoDirect = planFileSend(
      size: 1024,
      peerOnline: true,
      directFailure: 'no-direct',
    );
    expect(afterNoDirect.action, FileSendAction.relayConfirm);
    expect(afterNoDirect.reason, 'no-direct');

    final afterOfflineLarge = planFileSend(
      size: FileCipher.maxFileBytes + 1,
      peerOnline: true,
      directFailure: 'offline',
    );
    expect(afterOfflineLarge.action, FileSendAction.relayUnavailable);
    expect(afterOfflineLarge.reason, 'offline');

    expect(
      () => planFileSend(size: 10, peerOnline: true, directFailure: 'busy'),
      throwsArgumentError,
    );
  });
}
