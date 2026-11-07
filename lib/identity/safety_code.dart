/// 安全码计算与显示。
///
/// 安全码：双方公钥排序拼接后用 SHA-256 哈希，
/// 显示为 12 组 5 位数字 + 二维码。
///
/// 参考 Signal 的 Safety Number 设计。
/// 架构文档中指定 BLAKE2b/SHA-256，此处使用 SHA-256（crypto 包未直接导出 blake2b）。

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 计算两个公钥的安全码。
///
/// 公钥按字典序排序后拼接，再用 SHA-256 哈希。
/// 输出为 12 组 5 位十进制数字（共 60 位）。
class SafetyCode {
  /// 计算安全码。
  static String compute(String publicKeyA, String publicKeyB) {
    final keys = [publicKeyA, publicKeyB]..sort();
    final material = utf8.encode(keys.join(':'));
    final digest = sha256.convert(material);
    final hex = digest.toString();
    return _formatSafetyCode(hex);
  }

  /// 将十六进制哈希格式化为 12 组 5 位数字。
  static String _formatSafetyCode(String hex) {
    final groups = <String>[];
    for (var i = 0; i < 60; i += 5) {
      final groupHex = hex.substring(i, i + 5);
      final groupInt = int.parse(groupHex, radix: 16) % 100000;
      groups.add(groupInt.toString().padLeft(5, '0'));
    }
    return groups.join(' ');
  }

  /// 将安全码字符串解析为 12 组数字列表。
  static List<int> parse(String code) {
    return code.split(' ').map(int.parse).toList();
  }

  /// 验证安全码格式是否正确（12 组 5 位数字）。
  static bool isValid(String code) {
    final groups = code.split(' ');
    if (groups.length != 12) return false;
    return groups.every((g) => g.length == 5 && int.tryParse(g) != null);
  }

  /// 生成二维码数据（公钥对 + 安全码）。
  static String qrData(String publicKeyA, String publicKeyB, String safetyCode) {
    final data = {
      'v': 1,
      'type': 'safety-code',
      'keyA': publicKeyA,
      'keyB': publicKeyB,
      'safetyCode': safetyCode,
    };
    return jsonEncode(data);
  }
}
