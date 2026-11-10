# 任务：邀请码的解码改为严格校验，编码前校验字段

## 目标

`lib/pairing/invitation_code.dart` 负责邀请码的生成、编码（Base32）和解析。现在的实现过于宽松，会把畸形输入当成有效邀请码，也会把非法字段编码成一串永远解不开的字符串。需要在**不改变邀请码格式**的前提下收紧。

格式保持不变：`version(1 字节，值为 1) + publicKey(32) + token(16) + expiry(4，大端无符号)`，共 53 字节，用字母表 `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` 做无填充 Base32，得到 85 个字符。现有的合法邀请码必须仍然能解析。

## 现有缺陷（均已由验收测试复现）

1. `decode` 会悄悄丢弃所有字母表以外的字符。例如在合法邀请码中间插入 `0`、`!` 或汉字，仍然解析成功。
2. `decode` 接受末尾多出一个字符的邀请码（86 个字符也能解出 53 字节）。
3. `decode` 接受非规范编码：第 85 个字符的最低位是补位，应为 0，现在为 1 也能解析，导致两个不同的字符串对应同一个邀请码。
4. `encode` 不校验字段长度和范围：公钥不是 32 字节、token 不是 16 字节、expiry 超出 0..0xFFFFFFFF 时照样输出。
5. `create` 不校验公钥长度。

## 具体要求

- `InvitationCode.decode(String)`：
  - 忽略大小写。
  - 只忽略两类分隔符：空白字符（空格、制表符、回车、换行）和连字符 `-`，位置不限。
  - 去掉分隔符后，出现任何字母表以外的字符都返回 `null`，不能丢弃后继续解析。
  - 去掉分隔符后必须恰好 85 个字符，否则返回 `null`。
  - 最后一个字符的补位不为 0 时返回 `null`。
  - 版本号不是 1 时返回 `null`（现有行为，保持）。
  - 任何情况下都不抛异常，无效输入一律返回 `null`。
- `encode()`：`publicKey.length != 32`、`token.length != 16`、`expiry < 0` 或 `expiry > 0xFFFFFFFF` 时抛 `ArgumentError`。
- `InvitationCode.create(publicKey)`：`publicKey.length != 32` 时抛 `ArgumentError`。
- 构造函数保持 `const`，公开 API 的名字和签名不变（`publicKey`、`token`、`expiry`、`encode`、`decode`、`isExpired`、`ttl`、`create`、`requestId`）。
- 顺手把文件头注释里的"Base32 约 88 字符"改成 85 字符。

## 验收

- `flutter test --no-pub test/invitation_code_test.dart` 全部通过（目前 20 个里有 7 个失败）。
- `flutter analyze --no-fatal-infos lib test` 无 error/warning。
- `flutter test --no-pub` 全部通过。

## 不要做

- 不要修改 `test/invitation_code_test.dart` 或其它任何测试。
- 不要修改 allowed_paths 以外的文件，包括调用方 `lib/pairing/pairing_manager.dart` 和 `lib/ui/contacts_list.dart`。
- 不要改变邀请码格式，不要加校验和或新版本号。
- 不要引入新的依赖。
