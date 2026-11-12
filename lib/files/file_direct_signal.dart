/// 大文件直传的信令：offer/answer、ICE 候选、结束。
///
/// 它是 `ChatContent.fileSignal` 的 body（一段 JSON），和通话信令一样用会话密钥
/// 端到端加密，作为临时消息经中继转发（不暂存；对方不在线时中继回 `dropped`）。
/// 格式见 docs/file-direct.md。
library;

import 'dart:convert';

import '../call/call_signal.dart';
import 'file_offer.dart';

class FileDirectSignal {
  const FileDirectSignal._(
    this.kind,
    this.xferId, {
    this.sdp,
    this.candidate,
    this.reason,
    this.file,
  });

  /// 发起直传，带 SDP offer 和文件描述。
  const FileDirectSignal.offer(String xferId, String sdp, FileOffer file)
    : this._(kindOffer, xferId, sdp: sdp, file: file);

  /// 接受直传，带 SDP answer。
  const FileDirectSignal.answer(String xferId, String sdp)
    : this._(kindAnswer, xferId, sdp: sdp);

  /// 一个 ICE 候选。
  const FileDirectSignal.candidate(String xferId, CallCandidate candidate)
    : this._(kindCandidate, xferId, candidate: candidate);

  /// 结束这次直传。
  const FileDirectSignal.end(String xferId, String reason)
    : this._(kindEnd, xferId, reason: reason);

  static const String kindOffer = 'offer';
  static const String kindAnswer = 'answer';
  static const String kindCandidate = 'candidate';
  static const String kindEnd = 'end';

  static const String reasonCancel = 'cancel';
  static const String reasonReject = 'reject';
  static const String reasonBusy = 'busy';
  static const String reasonFailed = 'failed';
  static const String reasonNoDirect = 'no-direct';

  static const int maxXferIdChars = 64;
  static const int maxSdpChars = CallSignal.maxSdpChars;
  static const int maxCandidateChars = CallSignal.maxCandidateChars;

  final String kind;
  final String xferId;
  final String? sdp;
  final CallCandidate? candidate;
  final String? reason;

  /// 仅 offer。
  final FileOffer? file;

  String encode() => jsonEncode({
    'k': kind,
    'xfer': xferId,
    if (sdp != null) 'sdp': sdp,
    if (candidate != null) 'cand': candidate!.candidate,
    if (candidate?.sdpMid != null) 'mid': candidate!.sdpMid,
    if (candidate?.sdpMLineIndex != null) 'line': candidate!.sdpMLineIndex,
    if (reason != null) 'reason': reason,
    if (file != null) 'file': jsonDecode(file!.encode()),
  });

  /// 解析对方发来的信令。格式不对、种类不认识、字段超长或文件描述不合格时返回 null。
  static FileDirectSignal? decode(String body) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (json is! Map<String, dynamic>) return null;
    final kind = json['k'];
    final xferId = json['xfer'];
    if (xferId is! String || xferId.isEmpty || xferId.length > maxXferIdChars) {
      return null;
    }
    switch (kind) {
      case kindOffer:
        final sdp = json['sdp'];
        if (sdp is! String || sdp.isEmpty || sdp.length > maxSdpChars) {
          return null;
        }
        final raw = json['file'];
        if (raw is! Map) return null;
        final FileOffer file;
        try {
          file = FileOffer.decode(jsonEncode(raw));
        } on FormatException {
          return null;
        }
        if (!file.isDirect) return null;
        return FileDirectSignal._(kindOffer, xferId, sdp: sdp, file: file);
      case kindAnswer:
        final sdp = json['sdp'];
        if (sdp is! String || sdp.isEmpty || sdp.length > maxSdpChars) {
          return null;
        }
        return FileDirectSignal._(kindAnswer, xferId, sdp: sdp);
      case kindCandidate:
        final line = json['cand'];
        final mid = json['mid'];
        final index = json['line'];
        if (line is! String ||
            line.isEmpty ||
            line.length > maxCandidateChars) {
          return null;
        }
        if (mid != null && (mid is! String || mid.length > 64)) return null;
        if (index != null && (index is! int || index < 0 || index > 1024)) {
          return null;
        }
        return FileDirectSignal.candidate(
          xferId,
          CallCandidate(
            line,
            sdpMid: mid as String?,
            sdpMLineIndex: index as int?,
          ),
        );
      case kindEnd:
        final reason = json['reason'];
        if (reason is! String || reason.length > 32) return null;
        return FileDirectSignal.end(xferId, reason);
      default:
        return null;
    }
  }
}
