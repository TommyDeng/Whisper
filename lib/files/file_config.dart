/// 耳语文件传输配置。
///
/// 按架构文档 Stage 1 §5：
/// - 对方在线且有直连（物理局域网 / ZeroTier / 公网 P2P）：单文件 ≤ 100GB
/// - 对方离线或仅 TURN 中继（R2 中转）：单文件 ≤ 100MB

class FileTransferConfig {
  /// 直连传输单文件上限：100GB
  static const int maxDirectFileBytes = 100 * 1024 * 1024 * 1024;

  /// R2 中转传输单文件上限：100MB
  static const int maxRelayFileBytes = 100 * 1024 * 1024;

  /// DataChannel 分块大小：16 KiB
  static const int chunkSize = 16 * 1024;

  /// DataChannel 发送缓冲高水位：1 MiB
  static const int highWater = 1024 * 1024;

  /// DataChannel 发送缓冲低水位：256 KiB
  static const int lowWater = 256 * 1024;

  /// 判断给定文件大小是否允许直连传输
  static bool canDirectTransfer(int fileSize) {
    return fileSize <= maxDirectFileBytes;
  }

  /// 判断给定文件大小是否允许中转传输
  static bool canRelayTransfer(int fileSize) {
    return fileSize <= maxRelayFileBytes;
  }

  /// 根据文件大小和连接类型判断传输方式
  static String determineTransport(int fileSize, bool hasDirectConnection) {
    if (fileSize > maxDirectFileBytes) {
      return 'rejected'; // 超过直连上限，拒绝
    }
    if (fileSize > maxRelayFileBytes) {
      return hasDirectConnection ? 'direct' : 'rejected'; // 仅直连可发，且无直连则拒绝
    }
    return hasDirectConnection ? 'direct' : 'relay'; // 直连优先，否则中转
  }
}
