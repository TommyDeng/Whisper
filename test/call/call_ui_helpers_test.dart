import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/call/call_service.dart';
import 'package:whisper/call/webrtc_call_media.dart';
import 'package:whisper/ui/call_overlay.dart';
import 'package:whisper/voice/ice_strategy.dart';

void main() {
  test('通话时长格式', () {
    expect(formatCallDuration(Duration.zero), '00:00');
    expect(formatCallDuration(const Duration(seconds: 75)), '01:15');
    expect(formatCallDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
    expect(formatCallDuration(const Duration(seconds: -5)), '00:00');
  });

  test('状态文字', () {
    final now = DateTime(2026, 1, 1, 12);
    expect(callStatusText(const CallSnapshot(phase: CallPhase.outgoing), now), '正在呼叫…');
    expect(callStatusText(const CallSnapshot(phase: CallPhase.outgoing, remoteRinging: true), now), '对方响铃中…');
    expect(
      callStatusText(const CallSnapshot(phase: CallPhase.active, reconnecting: true), now),
      '正在重新连接…',
    );
    expect(
      callStatusText(
        CallSnapshot(phase: CallPhase.active, connectedAt: now.subtract(const Duration(seconds: 61))),
        now,
      ),
      '01:01',
    );
    expect(
      callStatusText(const CallSnapshot(phase: CallPhase.ended, endReason: CallEndReason.offline), now),
      '对方不在线',
    );
    for (final reason in CallEndReason.values) {
      expect(callEndText(reason), isNotEmpty);
    }
  });

  test('路径判断', () {
    IcePathType path(String local, String remote, {String address = '192.168.1.5', Set<String> zt = const {}}) =>
        classifyPath(localType: local, remoteType: remote, localAddress: address, zeroTierAddresses: zt);

    expect(path('host', 'host'), IcePathType.lan);
    expect(path('host', 'host', address: '10.147.17.8', zt: {'10.147.17.8'}), IcePathType.zerotier);
    expect(path('srflx', 'host'), IcePathType.srflx);
    expect(path('host', 'srflx'), IcePathType.srflx);
    expect(path('prflx', 'prflx'), IcePathType.srflx);
    expect(path('relay', 'host'), IcePathType.relay);
    expect(path('host', 'relay'), IcePathType.relay);
    // 经 TURN 中继时即使本端地址在 ZeroTier 上也算中继
    expect(path('relay', 'host', address: '10.147.17.8', zt: {'10.147.17.8'}), IcePathType.relay);
    expect(path('null', 'null'), IcePathType.unknown);
  });

  test('ZeroTier 网卡名', () {
    expect(isZeroTierInterface('ztabcdef12'), isTrue);
    expect(isZeroTierInterface('ZeroTier One [8056c2e21c000001]'), isTrue);
    expect(isZeroTierInterface('eth0'), isFalse);
    expect(isZeroTierInterface('wlan0'), isFalse);
  });
}
