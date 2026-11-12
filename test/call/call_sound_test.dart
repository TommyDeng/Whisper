import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/call/call_service.dart';
import 'package:whisper/call/call_sound.dart';

class _FakePlayer implements CallSoundPlayer {
  final List<String> log = [];

  @override
  Future<void> loop(String asset) async {
    log.add('loop:$asset');
  }

  @override
  Future<void> stop() async {
    log.add('stop');
  }

  @override
  Future<void> dispose() async {
    log.add('dispose');
  }
}

void main() {
  test('各阶段对应的提示音资源', () {
    expect(callSoundAssetFor(CallPhase.incoming), kIncomingRingAsset);
    expect(callSoundAssetFor(CallPhase.outgoing), kRingbackAsset);
    expect(callSoundAssetFor(CallPhase.connecting), kRingbackAsset);
    expect(callSoundAssetFor(CallPhase.active), isNull);
    expect(callSoundAssetFor(CallPhase.ended), isNull);
    expect(callSoundAssetFor(CallPhase.idle), isNull);
  });

  test('来电播铃声，呼出和接通中播回铃，接通或结束后停止', () async {
    final player = _FakePlayer();
    final sounds = CallSound(player: player);

    await sounds.sync(CallPhase.incoming);
    expect(sounds.currentAsset, kIncomingRingAsset);
    await sounds.sync(CallPhase.incoming); // 同阶段不重播
    await sounds.sync(CallPhase.connecting);
    expect(sounds.currentAsset, kRingbackAsset);
    await sounds.sync(CallPhase.outgoing); // 仍是回铃，不重播
    await sounds.sync(CallPhase.active);
    expect(sounds.currentAsset, isNull);
    await sounds.sync(CallPhase.ended);
    await sounds.sync(CallPhase.idle);
    await sounds.dispose();

    expect(player.log, [
      'loop:$kIncomingRingAsset',
      'loop:$kRingbackAsset',
      'stop',
      'dispose',
    ]);
  });

  test('从呼出直接结束只停止一次', () async {
    final player = _FakePlayer();
    final sounds = CallSound(player: player);
    await sounds.sync(CallPhase.outgoing);
    await sounds.sync(CallPhase.ended);
    await sounds.dispose();
    expect(player.log, ['loop:$kRingbackAsset', 'stop', 'dispose']);
  });
}
