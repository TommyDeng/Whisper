import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:whisper/call/call_audio.dart';

StatsReport report(String id, String type, Map<dynamic, dynamic> values) =>
    StatsReport(id, type, 0, values);

void main() {
  group('isMonitorAudioDevice', () {
    test('识别 Pulse / PipeWire 的监听源', () {
      expect(
        isMonitorAudioDevice(
          'alsa_output.pci-0000_00_1f.3.analog-stereo.monitor',
          'Monitor of 内置音频',
        ),
        isTrue,
      );
      expect(isMonitorAudioDevice('default', 'Monitor of HDMI'), isTrue);
      expect(
        isMonitorAudioDevice(
          'alsa_input.pci-0000_00_1f.3.analog-stereo',
          '内置音频 模拟立体声',
        ),
        isFalse,
      );
      expect(isMonitorAudioDevice('default', 'default: 内置音频 模拟立体声'), isFalse);
    });
  });

  group('pickDefaultPlayoutDeviceId', () {
    test('跳过 monitor，优先选名字带 default 的输出设备', () {
      const devices = [
        AudioDeviceOption(
          deviceId: 'hdmi-monitor',
          label: 'Monitor of HDMI',
          kind: 'audiooutput',
        ),
        AudioDeviceOption(deviceId: 'hdmi', label: 'HDMI', kind: 'audiooutput'),
        AudioDeviceOption(
          deviceId: 'default-sink',
          label: 'default: 内置音频',
          kind: 'audiooutput',
        ),
        AudioDeviceOption(deviceId: 'mic', label: '内置麦克风', kind: 'audioinput'),
      ];
      expect(pickDefaultPlayoutDeviceId(devices), 'default-sink');
    });

    test('没有 default 时取第一个非 monitor 输出', () {
      const devices = [
        AudioDeviceOption(
          deviceId: 'mon',
          label: 'Monitor of Speakers',
          kind: 'audiooutput',
        ),
        AudioDeviceOption(
          deviceId: 'speakers',
          label: 'Speakers',
          kind: 'audiooutput',
        ),
        AudioDeviceOption(deviceId: 'hdmi', label: 'HDMI', kind: 'audiooutput'),
      ];
      expect(pickDefaultPlayoutDeviceId(devices), 'speakers');
    });

    test('没有可用输出时返回 null', () {
      expect(pickDefaultPlayoutDeviceId(const []), isNull);
      expect(
        pickDefaultPlayoutDeviceId(const [
          AudioDeviceOption(
            deviceId: 'mon',
            label: 'Monitor of Speakers',
            kind: 'audiooutput',
          ),
          AudioDeviceOption(deviceId: 'mic', label: 'Mic', kind: 'audioinput'),
          AudioDeviceOption(deviceId: '', label: 'empty', kind: 'audiooutput'),
        ]),
        isNull,
      );
    });
  });

  group('localAudioLevelFromStats', () {
    test('优先用 media-source 的 audioLevel', () {
      final reports = [
        report('out', 'outbound-rtp', {'kind': 'audio', 'audioLevel': 0.1}),
        report('src', 'media-source', {'kind': 'audio', 'audioLevel': 0.42}),
        report('trk', 'track', {
          'kind': 'audio',
          'remoteSource': false,
          'audioLevel': 0.2,
        }),
      ];
      expect(localAudioLevelFromStats(reports), closeTo(0.42, 1e-9));
    });

    test('没有 media-source 时用本端 track，再其次 outbound-rtp', () {
      expect(
        localAudioLevelFromStats([
          report('out', 'outbound-rtp', {'kind': 'audio', 'audioLevel': 0.1}),
          report('trk', 'track', {
            'kind': 'audio',
            'remoteSource': false,
            'audioLevel': 0.25,
          }),
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
          report('remote', 'track', {
            'kind': 'audio',
            'remoteSource': true,
            'audioLevel': 0.9,
          }),
          report('video', 'media-source', {'kind': 'video', 'audioLevel': 0.9}),
          report('src', 'media-source', {'kind': 'audio', 'audioLevel': 1.5}),
        ]),
        1,
      );
      expect(
        localAudioLevelFromStats([
          report('src', 'media-source', {'kind': 'audio'}),
        ]),
        isNull,
      );
      expect(localAudioLevelFromStats(const []), isNull);
    });
  });

  group('选默认麦克风', () {
    test('跳过 monitor，优先 default，否则第一个输入', () {
      expect(
        pickDefaultRecordingDeviceId([
          const AudioDeviceOption(
            deviceId: 'mon',
            label: 'Monitor of Speakers',
            kind: 'audioinput',
          ),
          const AudioDeviceOption(
            deviceId: 'mic1',
            label: 'Built-in Mic',
            kind: 'audioinput',
          ),
          const AudioDeviceOption(
            deviceId: 'default:1',
            label: 'Default',
            kind: 'audioinput',
          ),
        ]),
        'default:1',
      );
      expect(
        pickDefaultRecordingDeviceId([
          const AudioDeviceOption(
            deviceId: 'out',
            label: 'Speaker',
            kind: 'audiooutput',
          ),
          const AudioDeviceOption(
            deviceId: 'mic1',
            label: 'Mic',
            kind: 'audioinput',
          ),
        ]),
        'mic1',
      );
      expect(pickDefaultRecordingDeviceId(const []), isNull);
    });
  });

  group('收发统计', () {
    test('同时读出本端发送和远端接收', () {
      final stats = callAudioStatsFromReports([
        report('src', 'media-source', {
          'kind': 'audio',
          'audioLevel': 0.25,
          'totalAudioEnergy': 1.5,
        }),
        report('out', 'outbound-rtp', {'kind': 'audio', 'bytesSent': 12800}),
        report('in', 'inbound-rtp', {
          'kind': 'audio',
          'audioLevel': 0.4,
          'bytesReceived': 40960,
          'totalAudioEnergy': 3.2,
        }),
      ]);
      expect(stats.localLevel, closeTo(0.25, 1e-9));
      expect(stats.bytesSent, 12800);
      expect(stats.localEnergy, closeTo(1.5, 1e-9));
      expect(stats.remoteLevel, closeTo(0.4, 1e-9));
      expect(stats.bytesReceived, 40960);
      expect(stats.compactLabel, contains('本端↑'));
      expect(stats.compactLabel, contains('12.5 KB'));
      expect(stats.compactLabel, contains('远端↓'));
      expect(stats.compactLabel, contains('40.0 KB'));
    });

    test('缺字段时对应值为 null，标签用问号', () {
      final stats = callAudioStatsFromReports(const []);
      expect(stats.localLevel, isNull);
      expect(stats.bytesSent, isNull);
      expect(stats.compactLabel, contains('?'));
    });
  });

  group('按系统默认设备选（Windows）', () {
    // Windows 上设备没有带 default 的名字，枚举顺序也不是默认设备在前。
    const devices = [
      AudioDeviceOption(
        deviceId: '{0.0.0.00000000}.{AAAA}',
        label: 'DELL U2720Q (NVIDIA High Definition Audio)',
      ),
      AudioDeviceOption(
        deviceId: '{0.0.0.00000000}.{BBBB}',
        label: '扬声器 (Realtek(R) Audio)',
      ),
      AudioDeviceOption(
        deviceId: '{0.0.1.00000000}.{CCCC}',
        label: '麦克风 (USB Audio)',
        kind: 'audioinput',
      ),
      AudioDeviceOption(
        deviceId: '{0.0.1.00000000}.{DDDD}',
        label: '麦克风阵列 (Realtek(R) Audio)',
        kind: 'audioinput',
      ),
    ];

    test('系统默认设备在列表里就选它，不管排第几、大小写是否一致', () {
      expect(
        pickDefaultPlayoutDeviceId(
          devices,
          systemDefaultId: '{0.0.0.00000000}.{bbbb}',
          fallbackToFirst: false,
        ),
        '{0.0.0.00000000}.{BBBB}',
      );
      expect(
        pickDefaultRecordingDeviceId(
          devices,
          systemDefaultId: '{0.0.1.00000000}.{DDDD}',
          fallbackToFirst: false,
        ),
        '{0.0.1.00000000}.{DDDD}',
      );
    });

    test('查不到系统默认设备时不乱选第一个，交给系统', () {
      expect(
        pickDefaultPlayoutDeviceId(devices, fallbackToFirst: false),
        isNull,
      );
      expect(
        pickDefaultPlayoutDeviceId(
          devices,
          systemDefaultId: '{0.0.0.00000000}.{ZZZZ}',
          fallbackToFirst: false,
        ),
        isNull,
      );
      expect(
        pickDefaultRecordingDeviceId(devices, fallbackToFirst: false),
        isNull,
      );
    });

    test('不传参数时行为不变：没有 default 就取第一个', () {
      expect(pickDefaultPlayoutDeviceId(devices), '{0.0.0.00000000}.{AAAA}');
    });
  });

  test('deviceLabelFor 按 id 找设备名', () {
    const devices = [
      AudioDeviceOption(deviceId: 'a', label: '扬声器'),
      AudioDeviceOption(deviceId: 'b', label: ''),
    ];
    expect(deviceLabelFor(devices, 'a'), '扬声器');
    expect(deviceLabelFor(devices, 'b'), 'b');
    expect(deviceLabelFor(devices, 'x'), isNull);
    expect(deviceLabelFor(devices, null), isNull);
  });
}
