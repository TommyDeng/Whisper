/// 通话信令的内容：呼叫、应答、ICE 候选、响铃、结束。
///
/// 它是 `ChatContent.call` 的 body（一段 JSON），和聊天消息一样用会话密钥端到端加密，
/// 作为“临时消息”经中继转发（不暂存；对方不在线时中继回 `dropped`）。
/// SDP 里带着 DTLS 指纹，所以中继既看不到也改不了它。格式见 docs/call-signaling.md。
library;

import 'dart:convert';

/// 一个 ICE 候选。
class CallCandidate {
  const CallCandidate(this.candidate, {this.sdpMid, this.sdpMLineIndex});

  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  @override
  bool operator ==(Object other) =>
      other is CallCandidate &&
      other.candidate == candidate &&
      other.sdpMid == sdpMid &&
      other.sdpMLineIndex == sdpMLineIndex;

  @override
  int get hashCode => Object.hash(candidate, sdpMid, sdpMLineIndex);
}

class CallSignal {
  const CallSignal._(this.kind, this.callId, {this.sdp, this.candidate, this.reason});

  /// 发起呼叫，带 SDP offer。
  const CallSignal.offer(String callId, String sdp) : this._(kindOffer, callId, sdp: sdp);

  /// 接听，带 SDP answer。
  const CallSignal.answer(String callId, String sdp) : this._(kindAnswer, callId, sdp: sdp);

  /// 一个 ICE 候选。
  const CallSignal.candidate(String callId, CallCandidate candidate)
      : this._(kindCandidate, callId, candidate: candidate);

  /// 被叫已收到呼叫，正在响铃。
  const CallSignal.ringing(String callId) : this._(kindRinging, callId);

  /// 结束通话。[reason] 是 [reasonHangup]、[reasonReject]、[reasonBusy] 或 [reasonFailed]。
  const CallSignal.end(String callId, String reason) : this._(kindEnd, callId, reason: reason);

  static const String kindOffer = 'offer';
  static const String kindAnswer = 'answer';
  static const String kindCandidate = 'candidate';
  static const String kindRinging = 'ringing';
  static const String kindEnd = 'end';

  /// 挂断（包括主叫在对方接听前取消）。
  static const String reasonHangup = 'hangup';

  /// 被叫拒接。
  static const String reasonReject = 'reject';

  /// 被叫正在另一通通话中。
  static const String reasonBusy = 'busy';

  /// 本端媒体出错（没有麦克风、连接建立失败等）。
  static const String reasonFailed = 'failed';

  static const int maxCallIdChars = 64;
  static const int maxSdpChars = 20000;
  static const int maxCandidateChars = 2000;

  final String kind;

  /// 一通通话的 ID，由主叫生成（用 `MessageCodec.newMessageId()`）。
  final String callId;

  /// 仅 offer / answer。
  final String? sdp;

  /// 仅 candidate。
  final CallCandidate? candidate;

  /// 仅 end。
  final String? reason;

  String encode() => jsonEncode({
        'k': kind,
        'call': callId,
        if (sdp != null) 'sdp': sdp,
        if (candidate != null) 'cand': candidate!.candidate,
        if (candidate?.sdpMid != null) 'mid': candidate!.sdpMid,
        if (candidate?.sdpMLineIndex != null) 'line': candidate!.sdpMLineIndex,
        if (reason != null) 'reason': reason,
      });

  /// 解析对方发来的信令。格式不对、种类不认识、字段超长时返回 null（调用方忽略）。
  static CallSignal? decode(String body) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (json is! Map<String, dynamic>) return null;
    final kind = json['k'];
    final callId = json['call'];
    if (callId is! String || callId.isEmpty || callId.length > maxCallIdChars) return null;
    switch (kind) {
      case kindOffer:
      case kindAnswer:
        final sdp = json['sdp'];
        if (sdp is! String || sdp.isEmpty || sdp.length > maxSdpChars) return null;
        return CallSignal._(kind as String, callId, sdp: sdp);
      case kindCandidate:
        final line = json['cand'];
        final mid = json['mid'];
        final index = json['line'];
        if (line is! String || line.isEmpty || line.length > maxCandidateChars) return null;
        if (mid != null && (mid is! String || mid.length > 64)) return null;
        if (index != null && (index is! int || index < 0 || index > 1024)) return null;
        return CallSignal.candidate(
          callId,
          CallCandidate(line, sdpMid: mid as String?, sdpMLineIndex: index as int?),
        );
      case kindRinging:
        return CallSignal.ringing(callId);
      case kindEnd:
        final reason = json['reason'];
        if (reason is! String || reason.length > 32) return null;
        return CallSignal.end(callId, reason);
      default:
        return null;
    }
  }
}
