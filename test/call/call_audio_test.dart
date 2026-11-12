import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:whisper/call/call_audio.dart';

void main() {
  group('isMonitorAudioDevice', () {
    test('识别 Pulse / PipeWire 的监听源', () {
      expect(isMonitorAudioDevice('alsa_output.pci-0000_00_1f.3.analog-stereo.monitor', 'Monitor of 内置音频'), isTrue);
      expect(isMonitorAudioDevice('default', 'Monitor of HDMI'), isTrue);
      expect(isMonitorAudioDevice('alsa_input.pci-0000_00_1f.3.analog-stereo', '内置音频 模拟立体声'), isFalse);
      expect(isMonitorAudioDevice('default', 'default: 内置音频 模拟立体声'), isFalse);
    });
  });

  group('pickDefaultPlayoutDeviceId', () {
    test('跳过 monitor，优先选名字带 default 的输出设备', () {
      const devices = [
        AudioDeviceOption(deviceId: 'hdmi-monitor', label: 'Monitor of HDMI', kind: 'audiooutput'),
        AudioDeviceOption(deviceId: 'hdmi', label: 'HDMI', kind: 'audiooutput'),
        AudioDeviceOption(deviceId: 'default-sink', label: 'default: 内置音频', kind: 'audiooutput'),
        AudioDeviceOption(deviceId: 'mic', label: '内置麦克风', kind: 'audioinput'),
      ];
      expect(pickDefaultPlayoutDeviceId(devices), 'default-sink');
    });

    test('没有 default 时取第一个非 monitor 输出', () {
      const devices = [
        AudioDeviceOption(deviceId: 'mon', label: 'Monitor of Speakers', kind: 'audiooutput'),
        AudioDeviceOption(deviceId: 'speakers', label: 'Speakers', kind: 'audiooutput'),
        AudioDeviceOption(deviceId: 'hdmi', label: 'HDMI', kind: 'audiooutput'),
      ];
      expect(pickDefaultPlayoutDeviceId(devices), 'speakers');
    });

    test('没有可用输出时返回 null', () {
      expect(pickDefaultPlayoutDeviceId(const []), isNull);
      expect(
        pickDefaultPlayoutDeviceId(const [
          AudioDeviceOption(deviceId: 'mon', label: 'Monitor of Speakers', kind: 'audiooutput'),
          AudioDeviceOption(deviceId: 'mic', label: 'Mic', kind: 'audioinput'),
          AudioDeviceOption(deviceId: '', label: 'empty', kind: 'audiooutput'),
        ]),
        isNull,
      );
    });
  });

  group('localAudioLevelFromStats', () {
    StatsReport report(String id, String type, Map<dynamic, dynamic> values) =>
        StatsReport(id, type, 0, values);

    test('优先用 media-source 的 audioLevel', () {
      final reports = [
        report('out', 'outbound-rtp', {'kind': 'audio', 'audioLevel': 0.1}),
        report('src', 'media-source', {'kind': 'audio', 'audioLevel': 0.42}),
        report('trk', 'track', {'kind': 'audio', 'remoteSource': false, 'audioLevel': 0.2}),
      ];
      expect(localAudioLevelFromStats(reports), closeTo(0.42, 1e-9));
    });

    test('没有 media-source 时用本端 track，再其次 outbound-rtp', () {
      expect(
        localAudioLevelFromStats([
          report('out', 'outbound-rtp', {'kind': 'audio', 'audioLevel': 0.1}),
          report('trk', 'track', {'kind': 'audio', 'remoteSource': false, 'audioLevel': 0.25}),
        ]),
        closeTo(0.25, 1e-9),
      );
      expect(
        localAudioLevelFromStats([
          report('out', 'outbound-rtp', {'kind': 'audio', 'audioLevel': 0.1}),
        ]),
        closeTo(0.1, 1e-9),
      );
    });

    test('忽略远端 track、视频和缺失字段，并夹紧到 0–1', () {
      expect(
        localAudioLevelFromStats([
          report('remote', 'track', {'kind': 'audio', 'remoteSource': true, 'audioLevel': 0.9}),
          report('video', 'media-source', {'kind': 'video', 'audioLevel': 0.9}),
          report('src', 'media-source', {'kind': 'audio', 'audioLevel': 1.5}),
        ]),
        1,
      );
      expect(localAudioLevelFromStats([report('src', 'media-source', {'kind': 'audio'})]), isNull);
      expect(localAudioLevelFromStats(const []), isNull);
    });
  });
}
