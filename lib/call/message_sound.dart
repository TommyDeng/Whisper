/// 来信提示音：对方发来文本或文件时叮一声。
/// 自己发出的不响；通话进行中不响；窗口在前台且正看着该会话时不响。
library;

import 'call_service.dart';
import 'call_sound.dart';

/// 来信短促提示音（相对 `assets/` 的路径）。
const kMessageChimeAsset = 'sounds/message_chime.wav';

/// 是否应当播放来信提示音。
///
/// - [fromSelf] 为自己发出的消息或文件时不响。
/// - 通话不在 [CallPhase.idle]（来电、呼出、接通中、通话中、刚结束）时不响，以免和铃声或语音叠在一起。
/// - 窗口在前台并且正在看这条消息所属的会话时不响（人已经看着了）。窗口不在前台时，即使开着该会话也响。
bool shouldPlayMessageSound({
  required bool fromSelf,
  required String sessionId,
  required String? visibleSessionId,
  required bool windowFocused,
  required CallPhase callPhase,
}) {
  if (fromSelf) return false;
  if (callPhase != CallPhase.idle) return false;
  if (windowFocused && visibleSessionId == sessionId) return false;
  return true;
}

/// 播放来信提示音。播放器和时钟可注入。
///
/// [minGap] 内的连续来信只响一次：文件到达时会先后来两个事件（直传邀约、传完后的文件消息），
/// 第二次播放会先 stop 掉第一次，Windows 上 stop 会释放还没开始出声的音源，结果一声都听不到。
class MessageSound {
  MessageSound({
    CallSoundPlayer? player,
    DateTime Function()? now,
    this.minGap = const Duration(seconds: 2),
  }) : _player = player ?? AudioplayersCallSoundPlayer(),
       _now = now ?? DateTime.now;

  final CallSoundPlayer _player;
  final DateTime Function() _now;
  final Duration minGap;
  DateTime? _lastChime;
  Future<void> _queue = Future<void>.value();

  Future<void> chime() {
    final now = _now();
    final last = _lastChime;
    if (last != null && now.difference(last) < minGap) return _queue;
    _lastChime = now;
    _queue = _queue.then((_) => _player.playOnce(kMessageChimeAsset));
    return _queue;
  }

  Future<void> dispose() async {
    await _queue;
    await _player.dispose();
  }
}
