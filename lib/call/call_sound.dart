/// 通话提示音：来电铃声、呼出/接通中的回铃，接通或结束后停止。
/// 播放器可注入，测试里不必真正出声。
library;

import 'package:audioplayers/audioplayers.dart';

import 'call_service.dart';

/// 提示音资源（相对 `assets/` 的路径，给 [AssetSource] 用）。
const kIncomingRingAsset = 'sounds/incoming_ring.wav';
const kRingbackAsset = 'sounds/ringback.wav';

/// 根据通话阶段决定要循环播放的资源；不需要声音时返回 null。
String? callSoundAssetFor(CallPhase phase) {
  switch (phase) {
    case CallPhase.incoming:
      return kIncomingRingAsset;
    case CallPhase.outgoing:
    case CallPhase.connecting:
      return kRingbackAsset;
    case CallPhase.idle:
    case CallPhase.active:
    case CallPhase.ended:
      return null;
  }
}

/// 循环或单次播放一个 asset，或停止。测试可提供假实现。
abstract class CallSoundPlayer {
  /// 循环播放 [asset]（相对 `assets/` 的路径）。若已在播同一资源则由调用方避免重复进入。
  Future<void> loop(String asset);

  /// 播放一次 [asset]（相对 `assets/` 的路径）。
  Future<void> playOnce(String asset);

  Future<void> stop();

  Future<void> dispose();
}

/// 用 audioplayers 播本地 asset。播放失败时吞掉错误，不影响通话。
class AudioplayersCallSoundPlayer implements CallSoundPlayer {
  AudioplayersCallSoundPlayer({AudioPlayer? player, AudioPlayer? oneshot})
    : _player = player ?? AudioPlayer(),
      _oneshot = oneshot ?? AudioPlayer();

  final AudioPlayer _player;
  final AudioPlayer _oneshot;

  @override
  Future<void> loop(String asset) async {
    try {
      await _player.stop();
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(AssetSource(asset));
    } catch (_) {
      // 本机缺解码器或资源时不打断通话
    }
  }

  @override
  Future<void> playOnce(String asset) async {
    try {
      await _oneshot.stop();
      await _oneshot.setReleaseMode(ReleaseMode.release);
      await _oneshot.play(AssetSource(asset));
    } catch (_) {
      // 本机缺解码器或资源时不打断界面
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    try {
      await _player.dispose();
    } catch (_) {}
    try {
      await _oneshot.dispose();
    } catch (_) {}
  }
}

/// 根据 [CallPhase] 切换提示音。
class CallSound {
  CallSound({CallSoundPlayer? player}) : _player = player ?? AudioplayersCallSoundPlayer();

  final CallSoundPlayer _player;

  String? _current;
  Future<void> _queue = Future<void>.value();

  /// 当前应当循环的资源；没有在响时为 null。测试用。
  String? get currentAsset => _current;

  /// 按新的通话阶段切换铃声。同阶段重复调用不会重头播放。
  Future<void> sync(CallPhase phase) {
    _queue = _queue.then((_) => _apply(phase));
    return _queue;
  }

  Future<void> _apply(CallPhase phase) async {
    final asset = callSoundAssetFor(phase);
    if (asset == _current) return;
    _current = asset;
    if (asset == null) {
      await _player.stop();
    } else {
      await _player.loop(asset);
    }
  }

  Future<void> dispose() async {
    await _queue;
    _current = null;
    await _player.dispose();
  }
}
