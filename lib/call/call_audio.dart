/// 通话音频的纯函数：选默认扬声器、从 getStats 读本端麦克风电平。
/// 不依赖具体设备，方便单测。
library;

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// 一个音频输入或输出设备，用于选择默认扬声器。
class AudioDeviceOption {
  const AudioDeviceOption({
    required this.deviceId,
    required this.label,
    this.kind = 'audiooutput',
  });

  final String deviceId;
  final String label;

  /// 一般为 `audiooutput` 或 `audioinput`。
  final String kind;
}

/// 是否是 PulseAudio / PipeWire 的“监听”源（扬声器回路），不能当麦克风或扬声器默认设备。
bool isMonitorAudioDevice(String deviceId, String label) {
  final text = '${deviceId.toLowerCase()} ${label.toLowerCase()}';
  return text.contains('monitor');
}

/// 从设备列表里选出默认扬声器的 deviceId。跳过 monitor；优先名字里带 default 的，否则取第一个输出设备。
/// 没有可用设备时返回 null。
String? pickDefaultPlayoutDeviceId(Iterable<AudioDeviceOption> devices) {
  final outputs = [
    for (final device in devices)
      if (device.kind == 'audiooutput' &&
          device.deviceId.isNotEmpty &&
          !isMonitorAudioDevice(device.deviceId, device.label))
        device,
  ];
  if (outputs.isEmpty) return null;
  for (final device in outputs) {
    final text = '${device.deviceId} ${device.label}'.toLowerCase();
    if (text.startsWith('default') || text.contains('default:') || text.contains('default ')) {
      return device.deviceId;
    }
  }
  return outputs.first.deviceId;
}

/// 从 [RTCPeerConnection.getStats] 的报告里取出本端麦克风电平（0.0–1.0）。拿不到时返回 null。
///
/// 优先 `media-source`（本端），其次未标记为远端的 `track`，再其次 `outbound-rtp`。
double? localAudioLevelFromStats(Iterable<StatsReport> reports) {
  double? fromMediaSource;
  double? fromLocalTrack;
  double? fromOutbound;
  for (final report in reports) {
    final level = _audioLevelOf(report);
    if (level == null) continue;
    final kind = '${report.values['kind'] ?? ''}';
    if (kind.isNotEmpty && kind != 'audio') continue;
    switch (report.type) {
      case 'media-source':
        fromMediaSource = level;
      case 'track':
        if (report.values['remoteSource'] == false) fromLocalTrack = level;
      case 'outbound-rtp':
        fromOutbound = level;
    }
  }
  return fromMediaSource ?? fromLocalTrack ?? fromOutbound;
}

double? _audioLevelOf(StatsReport report) {
  final value = report.values['audioLevel'];
  if (value is! num) return null;
  final level = value.toDouble();
  if (level.isNaN) return null;
  if (level < 0) return 0;
  if (level > 1) return 1;
  return level;
}
