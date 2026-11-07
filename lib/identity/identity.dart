/// 耳语身份模块：X25519 密钥生成、Ed25519 签名、系统安全存储、安全码。
///
/// 身份模型：一台设备 = 一个身份。
/// - 首次启动生成 X25519 身份密钥对 + Ed25519 签名密钥对
/// - 私钥经 flutter_secure_storage 存入系统安全存储（Windows DPAPI / Linux libsecret）
/// - 安全码：双方公钥排序拼接后用 BLAKE2b/SHA-256 哈希，显示为 12 组 5 位数字

library identity;

export 'identity_store.dart';
export 'safety_code.dart';
