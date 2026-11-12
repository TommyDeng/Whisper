/// 发送文件时走直传还是中转的决策。界面和 [FileShareService] 共用，便于单测。
library;

import 'file_cipher.dart';

/// 发送一条文件该怎么走。
enum FileSendAction {
  /// 双方在线：先走 WebRTC 数据通道，文件不经服务器。
  direct,

  /// 对方离线，或直连失败（只通了中继）：弹窗确认后再走 R2 中转。
  relayConfirm,

  /// 无法直传，且超过 100 MiB 中转上限，不能发。
  relayUnavailable,

  /// 超过 100 GiB 直传上限。
  tooLarge,
}

/// 一次发送决策。
class FileSendPlan {
  const FileSendPlan(this.action, {this.reason});

  final FileSendAction action;

  /// 需要向用户说明的原因：`offline` 或 `no-direct`。
  /// 在 [FileSendAction.relayConfirm] / [FileSendAction.relayUnavailable] 时有值。
  final String? reason;
}

/// 直传失败后，只有这两种情况才考虑改走中转：
/// 对方不在线，或 ICE 只通了中继（`no-direct`）。
/// 拒接、占线、超时、传到一半断网等不自动改走中转。
bool canFallbackToRelay(String? directFailure) =>
    directFailure == 'offline' || directFailure == 'no-direct';

/// 根据文件大小、对方是否在线、以及（可选的）直传失败原因，决定下一步。
///
/// [directAvailable] 为 false 时视为无法发起直传，效果与对方不在线相同
/// （不超过中转上限则请用户确认后走中转）。
FileSendPlan planFileSend({
  required int size,
  required bool peerOnline,
  bool directAvailable = true,
  String? directFailure,
}) {
  if (size > FileCipher.maxDirectFileBytes) {
    return const FileSendPlan(FileSendAction.tooLarge);
  }

  final failed = directFailure;
  if (failed != null) {
    if (!canFallbackToRelay(failed)) {
      throw ArgumentError.value(failed, 'directFailure', '只能是 offline 或 no-direct');
    }
    if (size <= FileCipher.maxFileBytes) {
      return FileSendPlan(FileSendAction.relayConfirm, reason: failed);
    }
    return FileSendPlan(FileSendAction.relayUnavailable, reason: failed);
  }

  if (peerOnline && directAvailable) {
    return const FileSendPlan(FileSendAction.direct);
  }

  final reason = peerOnline ? 'no-direct' : 'offline';
  if (size <= FileCipher.maxFileBytes) {
    return FileSendPlan(FileSendAction.relayConfirm, reason: reason);
  }
  return FileSendPlan(FileSendAction.relayUnavailable, reason: reason);
}
