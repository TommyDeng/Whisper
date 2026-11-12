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
    if (text.startsWith('default') ||
        text.contains('default:') ||
        text.contains('default ')) {
      return device.deviceId;
    }
  }
  return outputs.first.deviceId;
}

/// 从设备列表里选出默认麦克风的 deviceId。跳过 monitor；优先名字里带 default 的，否则取第一个输入设备。
String? pickDefaultRecordingDeviceId(Iterable<AudioDeviceOption> devices) {
  final inputs = [
    for (final device in devices)
      if (device.kind == 'audioinput' &&
          device.deviceId.isNotEmpty &&
          !isMonitorAudioDevice(device.deviceId, device.label))
        device,
  ];
  if (inputs.isEmpty) return null;
  for (final device in inputs) {
    final text = '${device.deviceId} ${device.label}'.toLowerCase();
    if (text.startsWith('default') ||
        text.contains('default:') ||
        text.contains('default ')) {
      return device.deviceId;
    }
  }
  return inputs.first.deviceId;
}

/// 通话中给界面看的收发统计。不含 SDP、候选地址或密钥。
class CallAudioStats {
  const CallAudioStats({
    this.localLevel,
    this.bytesSent,
    this.localEnergy,
    this.remoteLevel,
    this.bytesReceived,
    this.remoteEnergy,
  });

  final double? localLevel;
  final int? bytesSent;
  final double? localEnergy;
  final double? remoteLevel;
  final int? bytesReceived;
  final double? remoteEnergy;

  /// 通话条上的一行短诊断，例如 `本端↑12.3 KB 0.21  远端↓40.0 KB 0.48`。
  String get compactLabel {
    return '本端↑${_fmt(bytesSent)} ${_fmtLevel(localLevel)}  远端↓${_fmt(bytesReceived)} ${_fmtLevel(remoteLevel)}';
  }
}

String _fmt(int? bytes) {
  if (bytes == null) return '?';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _fmtLevel(double? level) =>
    level == null ? '?' : level.toStringAsFixed(2);

/// 从 getStats 报告里取出本端发送与远端接收的电平、字节数。拿不到的字段为 null。
CallAudioStats callAudioStatsFromReports(Iterable<StatsReport> reports) {
  double? localLevel;
  double? localLevelOut;
  int? bytesSent;
  double? localEnergy;
  double? remoteLevel;
  int? bytesReceived;
  double? remoteEnergy;
  for (final report in reports) {
    final kind = '${report.values['kind'] ?? ''}';
    if (kind.isNotEmpty && kind != 'audio') continue;
    switch (report.type) {
      case 'media-source':
        localLevel ??= _audioLevelOf(report);
        localEnergy ??= _energyOf(report);
      case 'track':
        final level = _audioLevelOf(report);
        if (report.values['remoteSource'] == false) {
          localLevel ??= level;
        } else if (report.values['remoteSource'] == true) {
          remoteLevel ??= level;
        }
      case 'outbound-rtp':
        localLevelOut ??= _audioLevelOf(report);
        bytesSent ??= _intOf(report, 'bytesSent');
        localEnergy ??= _energyOf(report);
      case 'inbound-rtp':
        remoteLevel ??= _audioLevelOf(report);
        bytesReceived ??= _intOf(report, 'bytesReceived');
        remoteEnergy ??= _energyOf(report);
    }
  }
  return CallAudioStats(
    localLevel: localLevel ?? localLevelOut,
    bytesSent: bytesSent,
    localEnergy: localEnergy,
    remoteLevel: remoteLevel,
    bytesReceived: bytesReceived,
    remoteEnergy: remoteEnergy,
  );
}

int? _intOf(StatsReport report, String key) {
  final value = report.values[key];
  if (value is int) return value;
  if (value is num) return value.round();
  return null;
}

double? _energyOf(StatsReport report) {
  final value = report.values['totalAudioEnergy'];
  if (value is! num) return null;
  final energy = value.toDouble();
  if (energy.isNaN || energy < 0) return null;
  return energy;
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
