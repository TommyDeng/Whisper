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
- 同一块已存在时再上传：`409 chunk-exists`，不覆盖原内容（客户端续传时把 409 当作已完成）。判断和写入是一步完成的，并发上传同一块时只有一个成功。已存在的块如果已经过期，按不存在处理：用新内容替换，返回 `201`。
- 过期：上传时间取 R2 对象自带的 `uploaded`（客户端改不了）；上传超过 7 天的块，`GET` 时按不存在处理（`404 not-found`）并删除。时间判断复用 `worker/src/relay_limits.ts` 的 `isExpired`。
- 校验顺序：先 `fileId`，再 `index`，最后方法。方法与路径不匹配（`/file/<fileId>` 上不是 `DELETE`，`/file/<fileId>/<index>` 上不是 `PUT`/`GET`）：`405 method-not-allowed`。
- `/file/` 下其它形状的路径（如 `/file/`、`/file/a/b/c`）不属于本接口，走入口原有的 `404`。
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
  /// size 为负或超过 maxFileBytes、hash 不是 32 字节：抛 ArgumentError（这两个值来自对方，不可信）。
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
  /// 所有块都写完后再调用也抛 StateError。
  /// 认证失败，或解出的明文长度不对（非末块必须正好 chunkSize，末块必须等于剩余长度）：
  /// 抛 FileCipherException，且不写入、nextIndex 不变（调用方可以重新下载这一块）。
  Future<void> addChunk(int index, Uint8List sealed);

  /// 所有块写完后调用：校验总长度和整文件哈希，通过则把临时文件改名为 target 并返回它。
  /// 不通过则删除临时文件并抛 FileCipherException。块没写完时调用抛 StateError。
  Future<File> finish();

  /// 放弃：关闭并删除临时文件。
  Future<void> abort();

  // finish 或 abort 之后再调用任何方法抛 StateError；
  // 上一个 addChunk / finish 还没完成时并发调用也抛 StateError。
}
```

要求：

- 任何时候内存里最多只有一个块，不把整个文件读进内存（`hashFile` 和 `finish` 的校验也要流式）。
- 测试覆盖：空文件、不足一块、正好一块、多块且末块不满；密文块长度；改动一个字节、调换两块、把非末块当末块（截断）都会失败；续传（写一部分后重新 `open`，`nextIndex` 正确，最后内容一致）；哈希不符时 `finish` 失败并删除临时文件；`FileKeys` 长度校验。测试里的文件放临时目录并清理，多块测试用 2–3 MiB 的文件即可。
- 完成标准：`flutter analyze --no-fatal-infos lib test` 没有新增问题（基线 18 条 info），`flutter test` 全过（现有 245 个测试不能少、不能改）。

`maxFileBytes` 在发送端由调用方检查（`sealChunk` 和 `chunkCount` 不查上限）。

## 任务 3：客户端的上传下载与文件消息

不含界面。涉及 `lib/files/`、`lib/messaging/`、`lib/storage/`，以及把服务接进 `lib/app_services.dart`。

### 文件消息

消息类型 `file`（格式见 `docs/message-format.md`），`body` 是 `FileOffer.encode()` 的结果：

```json
{"v":1,"id":"<fileId>","name":"报告.pdf","size":12345,"key":"<32 字节>","np":"<16 字节>","hash":"<32 字节>"}
```

- `lib/files/file_offer.dart`：`FileOffer`（`fileId`、`name`、`size`、`keys`、`hash`），`encode()` / `FileOffer.decode()`。`decode` 对任何不合格的内容抛 `FormatException`：`v` 不是 1、`id` 不是 43 个 URL 安全字符、`name` 为空或超过 255 个字符、`size` 不在 0 到 `maxFileBytes` 之间、三个二进制字段长度不对。
- `safeName`：存盘用的文件名。对方给的 `name` 不可信：只取最后一段路径，去掉控制字符和 Windows 不允许的字符，结果为空、`.` 或 `..` 时用 `file`。
- 文件消息和文本消息一样落库、去重、回 `delivered` 回执、参与 7 天保留和重新配对后的搬迁。`body` 解不出合格 `FileOffer` 的文件消息直接丢弃（仍向中继确认）。文件消息不支持阅后即焚。
- `MessagingService.sendFile(contact, offer)` 发送；`ChatMessage.file` 是解出的 `FileOffer`（文本消息为 null）。

### 中继接口的客户端

`lib/files/file_relay_api.dart`：

- `FileRelayApi`（接口）：`putChunk` / `getChunk` / `deleteFile`。`HttpFileRelay` 是它的 HTTP 实现，地址从中继地址换协议得到（`wss` → `https`，`ws` → `http`）。
- `putChunk`：`201` 和 `409 chunk-exists` 都算成功。
- `getChunk`：响应体超过 `chunkSize + tagLength` 时中止并报错，不把超长内容读进内存。
- 其它状态码抛 `FileRelayException(status, code)`；连不上、超时抛 `FileRelayException(0, 'network')`。
- 不记录路径、`fileId` 或内容。

### 传输

`lib/files/file_relay_transfer.dart` 的 `FileRelayTransfer`：

- `upload(file)`：超过 `maxFileBytes` 抛 `FileTransferException('too-large')`；上传途中源文件读不了或大小变了抛 `FileTransferException('changed')`。生成随机 `fileId` 和 `FileKeys`，逐块加密上传，返回 `FileOffer`。失败或取消时尽力删除已上传的块。
- `download(offer, target)`：用 `FileReceiver` 写 `<target>.part`，从 `nextIndex` 接着下；全部完成并校验通过后返回目标文件，并尽力删除中继上的块。
- 单块遇到暂时性的错误（连不上、超时、`429`、`5xx`）重试（默认 3 次）；中继以其它状态码拒绝时抛 `FileTransferException('rejected')`，不重试。下载时某块认证失败：重新下载这一块一次，仍失败则放弃。
- 结束方式与临时文件：

| 情况 | 抛出 | 临时文件 |
| --- | --- | --- |
| 取消 | `TransferCancelled` | 保留（可续传） |
| 网络错误重试用尽 | `FileTransferException('network')` | 保留（可续传） |
| 中继拒绝 | `FileTransferException('rejected')` | 保留 |
| 中继上没有这一块（过期或已删） | `FileTransferException('not-found')` | 删除 |
| 认证失败或整文件校验不过 | `FileTransferException('corrupt')` | 删除 |

- 进度回调给出已完成的字节数和总字节数；续传时从已有的字节数开始。
- 任何时候内存里最多一个块。

`FileReceiver` 补两点：

- `close()`：关闭但保留临时文件，之后可以重新 `open` 续传。
- 续传规则改为：已有长度是 `chunkSize` 的整数倍且不超过 `size` 时接着写；长度等于 `size`（且 `size` 大于 0）时所有块都已写完，`nextIndex` 等于 `chunkCount`，直接 `finish`。其它情况删掉从头开始。

### 本地记录

- 新表 `file_transfers(msgId 主键, localPath, updatedAt)`：发出的文件记源文件路径，下载完成的文件记保存路径。消息被删除（保留期、阅后即焚、删除联系人、搬迁时丢弃）时对应的行由触发器一并删除。只删记录，不删用户磁盘上的文件。
- `lib/files/file_share_service.dart` 的 `FileShareService` 把上面几件事串起来，供界面使用：`send(contact, file)`（上传 → 发文件消息 → 记路径；消息没发出去就删掉刚上传的块）、`download(contact, message, target)`、`cancel(id)`、按会话查询进行中和失败的上传、按消息 ID 查询下载状态、按会话查询已记录的本地路径、`updates` 流。传输失败不抛异常，原因记在状态里，由界面展示和清除。删除联系人、清空全部数据时取消相关的传输。

### 完成标准

`flutter analyze --no-fatal-infos lib test` 没有新增问题（基线 18 条 info），`flutter test` 全过（现有 273 个测试不能少）。测试用内存里的假中继和本机回环上的 HTTP 服务，不访问外网。
