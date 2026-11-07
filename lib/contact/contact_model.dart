/// 耳语 Whisper - 联系人模型
///
/// 描述已配对的亲友身份，包含公钥、安全码、备注名等。

/// 联系人模型
class Contact {
  const Contact({
    required this.deviceId,
    required this.name,
    required this.x25519PublicKeyBase64,
    required this.ed25519PublicKeyBase64,
    required this.safetyCode,
    required this.isVerified,
    required this.createdAt,
    required this.lastMessageTime,
  });

  /// 设备唯一标识（公钥哈希）
  final String deviceId;

  /// 联系人显示名称
  final String name;

  /// X25519 公钥（Base64）
  final String x25519PublicKeyBase64;

  /// Ed25519 签名公钥（Base64）
  final String ed25519PublicKeyBase64;

  /// 安全码（Base64 编码，用于配对验证）
  final String safetyCode;

  /// 是否已通过安全码验证
  final bool isVerified;

  /// 创建时间戳（Unix 毫秒）
  final int createdAt;

  /// 最后消息时间戳（Unix 毫秒）
  final int lastMessageTime;

  Contact copyWith({
    String? name,
    bool? isVerified,
    int? lastMessageTime,
  }) {
    return Contact(
      deviceId: deviceId,
      name: name ?? this.name,
      x25519PublicKeyBase64: x25519PublicKeyBase64,
      ed25519PublicKeyBase64: ed25519PublicKeyBase64,
      safetyCode: safetyCode,
      isVerified: isVerified ?? this.isVerified,
      createdAt: createdAt,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'deviceId': deviceId,
      'name': name,
      'x25519PublicKeyBase64': x25519PublicKeyBase64,
      'ed25519PublicKeyBase64': ed25519PublicKeyBase64,
      'safetyCode': safetyCode,
      'isVerified': isVerified ? 1 : 0,
      'createdAt': createdAt,
      'lastMessageTime': lastMessageTime,
    };
  }

  static Contact fromMap(Map<String, dynamic> map) {
    return Contact(
      deviceId: map['deviceId'] as String,
      name: map['name'] as String,
      x25519PublicKeyBase64: map['x25519PublicKeyBase64'] as String,
      ed25519PublicKeyBase64: map['ed25519PublicKeyBase64'] as String,
      safetyCode: map['safetyCode'] as String,
      isVerified: (map['isVerified'] as int) == 1,
      createdAt: map['createdAt'] as int,
      lastMessageTime: map['lastMessageTime'] as int,
    );
  }

  @override
  String toString() {
    return 'Contact(deviceId: $deviceId, name: $name, isVerified: $isVerified)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is Contact && runtimeType == other.runtimeType && deviceId == other.deviceId;
  }

  @override
  int get hashCode => deviceId.hashCode;
}
