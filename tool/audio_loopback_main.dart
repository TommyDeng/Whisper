/// Headless-ish Linux loopback probe: two in-process PeerConnections,
/// getUserMedia mic on the sender, no speaker playback.
/// Writes /tmp/whisper-audio-loopback.log and exits.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  unawaited(_run());
}

final _log = StringBuffer();

void _say(String line) {
  _log.writeln(line);
  // ignore: avoid_print
  print(line);
}

Future<void> _run() async {
  var code = 0;
  try {
    await _probe();
  } catch (error, stack) {
    _say('ERROR $error');
    _say('$stack');
    code = 1;
  }
  try {
    File('/tmp/whisper-audio-loopback.log').writeAsStringSync(_log.toString());
  } catch (_) {}
  exit(code);
}

Future<void> _probe() async {
  _say('pid=$pid');
  final devices = await navigator.mediaDevices.enumerateDevices();
  _say('enumerateDevices: ${devices.length}');
  for (final device in devices) {
    _say('  kind=${device.kind} id=${device.deviceId} label=${device.label}');
  }
  try {
    final outputs = await Helper.audiooutputs;
    _say('Helper.audiooutputs=${outputs.length}');
    for (final device in outputs) {
      _say('  out id=${device.deviceId} label=${device.label}');
    }
  } catch (error) {
    _say('Helper.audiooutputs failed: $error');
  }

  final local = await navigator.mediaDevices.getUserMedia({
    'audio': {
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
    },
    'video': false,
  });
  final tracks = local.getAudioTracks();
  _say('getUserMedia tracks=${tracks.length}');
  for (final track in tracks) {
    _say(
      '  track id=${track.id} enabled=${track.enabled} muted=${track.muted} label=${track.label}',
    );
    try {
      _say('  settings=${await track.getSettings()}');
    } catch (error) {
      _say('  settings error: $error');
    }
  }

  final config = {
    'sdpSemantics': 'unified-plan',
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };
  final sender = await createPeerConnection(config);
  final receiver = await createPeerConnection(config);
  sender.onIceCandidate = (candidate) {
    if (candidate.candidate != null) {
      unawaited(receiver.addCandidate(candidate));
    }
  };
  receiver.onIceCandidate = (candidate) {
    if (candidate.candidate != null) {
      unawaited(sender.addCandidate(candidate));
    }
  };
  var gotTrack = false;
  receiver.onTrack = (event) {
    gotTrack = true;
    _say(
      'onTrack kind=${event.track.kind} enabled=${event.track.enabled} streams=${event.streams.length}',
    );
    // Intentionally do not attach a renderer or enable loud playback.
    event.track.enabled = false;
  };

  for (final track in tracks) {
    await sender.addTrack(track, local);
  }
  final offer = await sender.createOffer({
    'offerToReceiveAudio': false,
    'offerToReceiveVideo': false,
  });
  await sender.setLocalDescription(offer);
  await receiver.setRemoteDescription(offer);
  final answer = await receiver.createAnswer();
  await receiver.setLocalDescription(answer);
  await sender.setRemoteDescription(answer);

  // Sample stats for ~4 seconds without playing audio.
  Map<String, num>? firstSent;
  Map<String, num>? lastSent;
  Map<String, num>? lastRecv;
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    lastSent = await _audioStats(sender, outbound: true);
    lastRecv = await _audioStats(receiver, outbound: false);
    firstSent ??= lastSent;
    _say('t=${(i + 1) * 500}ms sent=$lastSent recv=$lastRecv');
  }
  _say('gotTrack=$gotTrack');
  final sent0 = firstSent?['bytes'] ?? 0;
  final sent1 = lastSent?['bytes'] ?? 0;
  final recv1 = lastRecv?['bytes'] ?? 0;
  final level = lastSent?['level'] ?? 0;
  final energy = lastSent?['energy'] ?? 0;
  _say(
    'deltaBytesSent=${sent1 - sent0} lastLevel=$level lastEnergy=$energy bytesReceived=$recv1',
  );
  if (sent1 - sent0 > 0 || energy > 0 || level > 0) {
    _say('RESULT linux-capture=NONZERO');
  } else {
    _say('RESULT linux-capture=SILENT_OR_ZERO');
  }

  for (final track in tracks) {
    await track.stop();
  }
  await local.dispose();
  await sender.close();
  await receiver.close();
}

Future<Map<String, num>> _audioStats(
  RTCPeerConnection pc, {
  required bool outbound,
}) async {
  final reports = await pc.getStats();
  num? bytes;
  num? level;
  num? energy;
  num? packets;
  for (final report in reports) {
    final kind = '${report.values['kind'] ?? ''}';
    if (kind.isNotEmpty && kind != 'audio') continue;
    final type = report.type;
    final want = outbound
        ? type == 'outbound-rtp' || type == 'media-source'
        : type == 'inbound-rtp' || type == 'track';
    if (!want &&
        type != 'media-source' &&
        type != 'outbound-rtp' &&
        type != 'inbound-rtp')
      continue;
    final b = report.values['bytesSent'] ?? report.values['bytesReceived'];
    if (b is num) bytes = b;
    final l = report.values['audioLevel'];
    if (l is num) level = l;
    final e = report.values['totalAudioEnergy'];
    if (e is num) energy = e;
    final p = report.values['packetsSent'] ?? report.values['packetsReceived'];
    if (p is num) packets = p;
  }
  return {
    if (bytes != null) 'bytes': bytes,
    if (level != null) 'level': level,
    if (energy != null) 'energy': energy,
    if (packets != null) 'packets': packets,
  };
}
