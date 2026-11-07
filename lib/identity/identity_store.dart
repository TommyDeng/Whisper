import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 身份密钥对：X25519 用于密钥交换，Ed25519 用于签名。
class IdentityKeyPair {
  const IdentityKeyPair({
    required this.x25519PublicKey,
    required this.x25519PrivateKey,
    required this.ed25519PublicKey,
    required this.ed25519PrivateKey,
  });

  final Uint8List x25519PublicKey;
  final Uint8List x25519PrivateKey;
  final Uint8List ed25519PublicKey;
  final Uint8List ed25519PrivateKey;

  /// 以 Base64 编码的公钥，用于信令交换和安全码计算。
  String get x25519PublicKeyBase64 => base64Url.encode(x25519PublicKey);
  String get ed25519PublicKeyBase64 => base64Url.encode(ed25519PublicKey);

  /// 序列化为 JSON（仅公钥，私钥不序列化）。
  Map<String, String> toJson() => {
    'x25519PublicKey': x25519PublicKeyBase64,
    'ed25519PublicKey': ed25519PublicKeyBase64,
  };
}

/// 身份存储：私钥存于系统安全存储（Windows DPAPI / Linux libsecret）。
class IdentityStore {
  IdentityStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _x25519PrivateKeyKey = 'x25519_private_key';
  static const _ed25519PrivateKeyKey = 'ed25519_private_key';

  /// 从安全存储加载身份密钥对，如果不存在则返回 null。
  Future<IdentityKeyPair?> load() async {
    final x25519PrivateB64 = await _storage.read(key: _x25519PrivateKeyKey);
    final ed25519PrivateB64 = await _storage.read(key: _ed25519PrivateKeyKey);
    if (x25519PrivateB64 == null || ed25519PrivateB64 == null) return null;

    final x25519Private = base64Url.decode(x25519PrivateB64);
    final ed25519Private = base64Url.decode(ed25519PrivateB64);

    return IdentityKeyPair(
      x25519PublicKey: await _deriveX25519PublicKey(x25519Private),
      x25519PrivateKey: x25519Private,
      ed25519PublicKey: await _deriveEd25519PublicKey(ed25519Private),
      ed25519PrivateKey: ed25519Private,
    );
  }

  /// 将身份密钥对保存到安全存储。
  Future<void> save(IdentityKeyPair keyPair) async {
    await _storage.write(
      key: _x25519PrivateKeyKey,
      value: base64Url.encode(keyPair.x25519PrivateKey),
    );
    await _storage.write(
      key: _ed25519PrivateKeyKey,
      value: base64Url.encode(keyPair.ed25519PrivateKey),
    );
  }

  /// 清除存储的身份密钥。
  Future<void> clear() async {
    await _storage.delete(key: _x25519PrivateKeyKey);
    await _storage.delete(key: _ed25519PrivateKeyKey);
  }

  /// 从 X25519 私钥推导公钥。
  static Future<Uint8List> _deriveX25519PublicKey(List<int> privateKey) async {
    final x25519 = X25519();
    final keyPair = await x25519.newKeyPairFromSeed(privateKey);
    final publicKey = await keyPair.extractPublicKey();
    return Uint8List.fromList(publicKey.bytes);
  }

  /// 从 Ed25519 私钥推导公钥。
  static Future<Uint8List> _deriveEd25519PublicKey(List<int> privateKey) async {
    final ed25519 = Ed25519();
    final keyPair = await ed25519.newKeyPairFromSeed(privateKey);
    final publicKey = await keyPair.extractPublicKey();
    return Uint8List.fromList(publicKey.bytes);
  }
}

/// 生成新的身份密钥对。
Future<IdentityKeyPair> generateIdentityKeyPair() async {
  final x25519 = X25519();
  final ed25519 = Ed25519();

  final x25519KeyPair = await x25519.newKeyPair();
  final ed25519KeyPair = await ed25519.newKeyPair();

  final x25519Private = Uint8List.fromList(await x25519KeyPair.extractPrivateKeyBytes());
  final ed25519Private = Uint8List.fromList(await ed25519KeyPair.extractPrivateKeyBytes());

  final x25519Public = await x25519KeyPair.extractPublicKey();
  final ed25519Public = await ed25519KeyPair.extractPublicKey();

  return IdentityKeyPair(
    x25519PublicKey: Uint8List.fromList(x25519Public.bytes),
    x25519PrivateKey: x25519Private,
    ed25519PublicKey: Uint8List.fromList(ed25519Public.bytes),
    ed25519PrivateKey: ed25519Private,
  );
}

/// 身份管理器：首次启动生成身份，后续从安全存储加载。
class IdentityManager {
  IdentityManager({required this.store});

  final IdentityStore store;
  IdentityKeyPair? _keyPair;

  /// 获取当前身份，首次调用时生成并保存。
  Future<IdentityKeyPair> get identity async {
    if (_keyPair != null) return _keyPair!;
    final existing = await store.load();
    if (existing != null) {
      _keyPair = existing;
      return existing;
    }
    final generated = await generateIdentityKeyPair();
    await store.save(generated);
    _keyPair = generated;
    return generated;
  }

  /// 清除身份（用于注销/重置）。
  Future<void> reset() async {
    _keyPair = null;
    await store.clear();
  }
}
