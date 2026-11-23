/// 一条通话记录：一通通话在本端的结果。只在本地落库，不经网络发送——
/// 呼叫方和被叫方各按自己的视角记一条。编码进 `ChatContent.callLog` 的 body。
library;

import 'dart:convert';

/// 一通通话的结局。
enum CallOutcome {
  /// 接通并正常结束，带通话时长。
  completed,

  /// 自己呼出后在对方接听前取消。
  canceled,

  /// 来电没接到（对方先挂或响铃超时）。
  missed,

  /// 自己呼出，对方拒接。
  rejected,

  /// 来电，自己拒接。
  declined,

  /// 自己呼出，对方正在通话中。
  busy,

  /// 自己呼出，对方不在线。
  offline,

  /// 自己呼出，对方一直没接（响铃超时）。
  noAnswer,

  /// 音频连接出错。
  failed,
}

class CallRecord {
  const CallRecord({
    required this.outgoing,
    required this.outcome,
    this.duration,
  });

  /// 这通通话是不是自己打出去的。
  final bool outgoing;

  final CallOutcome outcome;

  /// 仅 [CallOutcome.completed]：通话时长。
  final Duration? duration;

  String encode() => jsonEncode({
    'out': outgoing,
    'kind': outcome.name,
    if (duration != null) 'dur': duration!.inSeconds,
  });

  /// 解析 body；格式不对或 outcome 不认识时返回 null。
  static CallRecord? decode(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map) return null;
      final kindName = json['kind'];
      CallOutcome? outcome;
      for (final value in CallOutcome.values) {
        if (value.name == kindName) {
          outcome = value;
          break;
        }
      }
      if (outcome == null) return null;
      final dur = json['dur'];
      return CallRecord(
        outgoing: json['out'] == true,
        outcome: outcome,
        duration: dur is int && dur >= 0 ? Duration(seconds: dur) : null,
      );
    } catch (_) {
      return null;
    }
  }
}
