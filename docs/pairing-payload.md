# 配对载荷的密码学构造

配对时两个 payload 经中继传递（`docs/relay-protocol.md` 第二、三节）。中继知道邀请 token（它就是邀请 ID），
但不知道邀请人的公钥——公钥只在邀请码里，邀请码由用户在带外传递。实现在 `lib/pairing/pairing_payload.dart`。

记号：`A` 邀请人，`B` 加入者，`E` 加入者为这次请求临时生成的 X25519 密钥对；`token` 是邀请码里的 16 字节；
`b64u(x)` 是 base64url **无填充**；`||` 是字节拼接；JSON 都用 UTF-8。

对称加密统一用 XChaCha20-Poly1305（24 字节随机 nonce，16 字节 MAC），密钥用 HKDF-SHA256 派生 32 字节。
X25519 私钥均指 32 字节种子（`X25519().newKeyPairFromSeed`）。

## pair-request（B → A）

```
shared = X25519(E_priv, A_pub)
key    = HKDF-SHA256(ikm = shared, salt = token,
                     info = utf8("whisper/pair-request/v1") || E_pub || A_pub, 长度 32)
aad    = utf8("whisper/pair-request/v1")
明文   = {"x25519": b64u(B_x25519_pub), "ed25519": b64u(B_ed25519_pub), "name": <字符串>}
payload = b64u(utf8(JSON {"v":1, "epk": b64u(E_pub), "nonce": b64u(nonce), "ct": b64u(密文), "mac": b64u(mac)}))
```

只有持有邀请码的人才构造得出能被 A 解开的请求。请求本身不证明 B 持有所声称的静态私钥；这一点由响应保证。

## pair-response（A → B，仅批准时）

```
shared = X25519(A_priv, B_x25519_pub)          // B 端为 X25519(B_priv, A_pub)
key    = HKDF-SHA256(ikm = shared, salt = token,
                     info = utf8("whisper/pair-response/v1") || A_pub || B_pub, 长度 32)
aad    = utf8("whisper/pair-response/v1")
明文   = {"sessionId": <字符串>, "ed25519": b64u(A_ed25519_pub), "name": <字符串>}
payload = b64u(utf8(JSON {"v":1, "nonce": b64u(nonce), "ct": b64u(密文), "mac": b64u(mac)}))
```

用双方静态密钥派生：B 能解开就说明响应来自邀请码里那个公钥的持有者；冒充 B 公钥的人解不开，拿不到 `sessionId`。
拒绝时 `pair-response` 的 `accepted` 为 false，payload 为空字符串。

## 校验

解开后必须检查，不满足一律按失败处理（`PairingPayloadException`）：

- 外层：是合法 base64url、合法 JSON 对象，`v == 1`，`epk` 32 字节，`nonce` 24 字节，`mac` 16 字节，`ct` 非空。
- 明文：`x25519` / `ed25519` 解码后都是 32 字节；`name` 是字符串且不超过 64 个字符；
  `sessionId` 匹配 `^[A-Za-z0-9_-]{22,64}$`。

配对成功后双方应比对安全码（`lib/identity/safety_code.dart`），这是抵御“邀请码被第三方截获”的最后一道检查。
