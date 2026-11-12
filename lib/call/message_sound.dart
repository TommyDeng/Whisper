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

/// 播放一次来信提示音。播放器可注入。
class MessageSound {
  MessageSound({CallSoundPlayer? player}) : _player = player ?? AudioplayersCallSoundPlayer();

  final CallSoundPlayer _player;
  Future<void> _queue = Future<void>.value();

  Future<void> chime() {
    _queue = _queue.then((_) => _player.playOnce(kMessageChimeAsset));
    return _queue;
  }

  Future<void> dispose() async {
    await _queue;
    await _player.dispose();
  }
}
