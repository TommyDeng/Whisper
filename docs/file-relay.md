# 文件中转（R2）

对方离线或没有直连时，文件（单文件 ≤ 100MB）加密后分块暂存在 Cloudflare R2，对方下载后删除，最长保留 7 天。服务端只见到密文分块；文件密钥、文件名、大小、哈希只放在端到端加密的消息里。

本文是这一功能的设计约定。直连大文件传输不在本文范围内。

## 分块与加密（客户端）

- 明文按 `chunkSize = 1 MiB`（1048576 字节）切块。块数 `chunkCount = max(1, ceil(size / chunkSize))`；空文件是 1 个空块。上限 `maxFileBytes = 100 * 1024 * 1024`。
- 每个文件随机生成：32 字节密钥 `key`、16 字节 `noncePrefix`。
- 每块独立用 XChaCha20-Poly1305 加密：
  - nonce（24 字节）= `noncePrefix`（16 字节）‖ 块序号（8 字节大端）
  - 附加数据（9 字节）= 块序号（8 字节大端）‖ 末块标志（末块为 `0x01`，其余 `0x00`）
  - 密文块 = 密文 ‖ 16 字节认证标签（nonce 不随块存放）。所以密文块比明文块长 16 字节。
- 整文件哈希：对明文做 BLAKE2b，输出 32 字节。
- 这样能发现：任一块被改动、块被调换顺序、文件被截断（末块标志）、用别的文件的块替换（密钥不同）。

## 服务端接口（Worker）

对象存在 R2 存储桶里，绑定名 `FILES`，对象名 `<fileId>/<index>`。

`fileId` 由发送方随机生成：43 个 URL 安全字符（32 字节随机数的 base64url，无填充）。知道 `fileId` 就能上传、下载、删除——它只通过端到端加密的消息传给对方，起访问凭据的作用。`index` 是十进制块序号，`0`–`127`，不带前导零。

| 方法与路径 | 作用 | 成功 | 失败 |
| --- | --- | --- | --- |
| `PUT /file/<fileId>/<index>` | 上传一个密文块，请求体是原始字节 | `201 {"ok":true}` | 见下 |
| `GET /file/<fileId>/<index>` | 下载一个密文块 | `200`，`content-type: application/octet-stream`，体为原始字节 | `404 {"ok":false,"error":"not-found"}` |
| `DELETE /file/<fileId>` | 删除这个文件的全部块（没有块也算成功） | `200 {"ok":true}` | — |

规则：

- `fileId` 不合格：`400 bad-file-id`。`index` 不合格（非数字、前导零、超过 127）：`400 bad-chunk-index`。这两项对三个方法都适用（`DELETE` 没有 index）。
- 上传的块最大 `1048576 + 16` 字节。超过：`413 chunk-too-large`，且不得把超限内容写入存储。空请求体：`400 empty-chunk`。
- 同一块已存在时再上传：`409 chunk-exists`，不覆盖原内容（客户端续传时把 409 当作已完成）。
- 过期：每块记录上传时间；上传超过 7 天的块，`GET` 时按不存在处理（`404 not-found`）并删除。时间判断复用 `worker/src/relay_limits.ts` 的 `isExpired`。
- `/file/` 下其它方法：`405 method-not-allowed`。
- 所有响应带 `cache-control: no-store`。错误体统一为 `{"ok":false,"error":"<代码>"}`。
- 不记录任何请求信息（路径、`fileId`、大小、IP）。

已知的不足（另行处理，不在本文的两个任务里）：上传没有身份校验和配额，任何人都可以往桶里写；部署前需要加限制，并在 R2 上配 7 天生命周期规则兜底。

## 任务 1：Worker 的文件接口

实现上面的“服务端接口”。

- 新文件 `worker/src/files.ts` 放实现；`worker/src/index.ts` 只加路由；常量放 `worker/src/relay_limits.ts`。
- `worker/wrangler.jsonc` 加 R2 绑定 `FILES`（`bucket_name` 为 `whisper-files`）。**不要部署，不要创建真实的存储桶**；测试用 vitest 的本地模拟。
- 测试放 `worker/test/files.spec.ts`，覆盖上表每一行和每一条规则。过期用可注入的时间或直接写入一个带旧时间的对象来测，不要真的等待。
- `docs/relay-protocol.md` 加一节简述这些接口，指向本文。
- 完成标准：在 `worker/` 下 `npx wrangler types && npm run typecheck && npm test` 全过（现有 47 个测试不能少、不能改）。

## 任务 2：客户端的文件分块加密

实现上面的“分块与加密”，纯 Dart，不涉及网络和界面。新文件 `lib/files/file_cipher.dart`，测试 `test/files/file_cipher_test.dart`。不要改 `lib/files/` 下已有的文件（那是早期验证代码）。

对外接口（名字和签名照此，后续任务要用）：

```dart
class FileKeys {
  FileKeys({required this.key, required this.noncePrefix}); // 长度不对抛 ArgumentError
  factory FileKeys.random();
  final Uint8List key;         // 32 字节
  final Uint8List noncePrefix; // 16 字节
}

class FileCipher {
  static const int chunkSize = 1024 * 1024;
  static const int tagLength = 16;
  static const int maxFileBytes = 100 * 1024 * 1024;

  /// 文件大小对应的块数；size 为负抛 ArgumentError。
  static int chunkCount(int size);

  /// 流式计算文件明文的 BLAKE2b-256。
  static Future<Uint8List> hashFile(File file);

  /// 从文件里读出第 index 块并加密，返回密文块。index 越界抛 RangeError。
  static Future<Uint8List> sealChunk(File file, FileKeys keys, int index);

  /// 解密一个密文块。认证失败（内容、序号或末块标志不对）抛 FileCipherException。
  static Future<Uint8List> openChunk(Uint8List sealed, FileKeys keys, int index, {required bool isFinal});
}

class FileCipherException implements Exception { ... }

/// 接收端：按顺序把密文块解密后写进临时文件，全部写完并校验通过后改名为目标文件。
class FileReceiver {
  /// 临时文件是 `<target>.part`。它已存在时接着写（断点续传）：
  /// 已有长度必须是 chunkSize 的整数倍且小于 size，否则删掉从头开始。
  static Future<FileReceiver> open({
    required File target,
    required FileKeys keys,
    required int size,
    required Uint8List hash,
  });

  /// 下一个要写的块序号（续传时不是 0）。
  int get nextIndex;
  int get chunkCount;

  /// 解密并追加一块。index 必须等于 nextIndex，否则抛 StateError。
  /// 认证失败抛 FileCipherException，且不写入、nextIndex 不变（调用方可以重新下载这一块）。
  Future<void> addChunk(int index, Uint8List sealed);

  /// 所有块写完后调用：校验总长度和整文件哈希，通过则把临时文件改名为 target 并返回它。
  /// 不通过则删除临时文件并抛 FileCipherException。块没写完时调用抛 StateError。
  Future<File> finish();

  /// 放弃：关闭并删除临时文件。
  Future<void> abort();
}
```

要求：

- 任何时候内存里最多只有一个块，不把整个文件读进内存（`hashFile` 和 `finish` 的校验也要流式）。
- 测试覆盖：空文件、不足一块、正好一块、多块且末块不满；密文块长度；改动一个字节、调换两块、把非末块当末块（截断）都会失败；续传（写一部分后重新 `open`，`nextIndex` 正确，最后内容一致）；哈希不符时 `finish` 失败并删除临时文件；`FileKeys` 长度校验。测试里的文件放临时目录并清理，多块测试用 2–3 MiB 的文件即可。
- 完成标准：`flutter analyze --no-fatal-infos lib test` 没有新增问题（基线 18 条 info），`flutter test` 全过（现有 245 个测试不能少、不能改）。
